#!/usr/bin/env bash
# Shift-left Kubernetes policy gate (used by CI and locally):
#  1. `kyverno test`  — unit tests: policies block bad pods and admit good ones
#  2. `kyverno apply` — our rendered ML workloads (prod values) must pass the same
#                        validate policies the cluster enforces at admission.
# (Signature verification needs the registry; it is enforced in-cluster and in promote-prod.yml.)
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
OUT=$(mktemp -d)
trap 'rm -rf "$OUT"' EXIT

helm template security-policies charts/security-policies \
  -f charts/security-policies/values.yaml -f charts/security-policies/values-prod.yaml \
  --set accountId=123456789012 > "$OUT/all-policies.yaml"
# drop the verifyImages policy (needs network + signed images) and NetworkPolicies
yq 'select(.kind == "ClusterPolicy" and .metadata.name != "verify-ml-image-signatures")' "$OUT/all-policies.yaml" > "$OUT/policies.yaml"

echo "== kyverno test (policy unit tests)"
cp charts/security-policies/tests/* "$OUT/"
kyverno test "$OUT"

echo "== kyverno apply (rendered ML workloads, prod values)"
helm template ml-inference charts/ml-inference -n ml-serving \
  -f charts/ml-inference/values.yaml -f charts/ml-inference/values-prod.yaml \
  --set image.repository=123456789012.dkr.ecr.us-east-1.amazonaws.com/aiml/ml-inference > "$OUT/inference.yaml"
yq 'select(.kind == "Deployment") | .metadata.namespace = "ml-serving"' "$OUT/inference.yaml" > "$OUT/workloads.yaml"
kyverno apply "$OUT/policies.yaml" --resource "$OUT/workloads.yaml" --policy-report --remove-color | tee "$OUT/report.txt"
if grep -Eq "fail: [1-9]|error: [1-9]" "$OUT/report.txt"; then
  echo "::error::rendered workloads violate cluster admission policies"; exit 1
fi
echo "policy gate passed"

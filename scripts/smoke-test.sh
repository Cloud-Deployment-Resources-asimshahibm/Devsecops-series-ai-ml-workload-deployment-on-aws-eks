#!/usr/bin/env bash
# End-to-end verification of an environment. Exit code 0 = healthy.
set -uo pipefail
ENV=${1:-dev}
pass=0; fail=0
ok()   { echo "  [PASS] $*"; pass=$((pass+1)); }
bad()  { echo "  [FAIL] $*"; fail=$((fail+1)); }
check(){ local d="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$d"; else bad "$d"; fi; }

echo "== Cluster"
check "API reachable"                       kubectl get --raw /readyz
check "system nodes Ready"                  bash -c "kubectl get nodes -l workload=system --no-headers | grep -qv NotReady"
check "Karpenter controller running"        kubectl -n kube-system rollout status deploy/karpenter --timeout=10s
check "NodePools cpu + gpu exist"           bash -c "kubectl get nodepools.karpenter.sh cpu gpu"

echo "== GitOps"
unhealthy=$(kubectl -n argocd get applications.argoproj.io -o json | jq -r '.items[] | select(.status.health.status!="Healthy" or .status.sync.status!="Synced") | .metadata.name')
[[ -z "$unhealthy" ]] && ok "all Argo CD apps Synced/Healthy" || bad "apps not ready: $(echo $unhealthy)"

echo "== Data plane"
check "ExternalSecrets ready"               bash -c "! kubectl get externalsecrets -A -o json | jq -e '.items[] | select(.status.conditions[]?.status==\"False\")'"
check "EFS shared PVC bound"                bash -c "kubectl -n jupyterhub get pvc jupyter-shared -o jsonpath='{.status.phase}' | grep -q Bound"
check "Postgres DB init job succeeded"      bash -c "kubectl -n platform-system get job postgres-db-init -o jsonpath='{.status.succeeded}' | grep -q 1"

echo "== ML tooling"
check "JupyterHub hub ready"                kubectl -n jupyterhub rollout status deploy/hub --timeout=10s
check "Argo Workflows controller ready"     kubectl -n argo rollout status deploy/argo-workflows-workflow-controller --timeout=10s
check "WorkflowTemplate present"            kubectl -n ml-training get workflowtemplate ml-training-pipeline
check "RayCluster ready"                    bash -c "kubectl -n ray get raycluster ml-ray -o jsonpath='{.status.state}' | grep -qi ready"

echo "== Observability"
check "Prometheus ready"                    kubectl -n monitoring rollout status sts/prometheus-kube-prometheus-stack-prometheus --timeout=10s
check "Grafana ready"                       kubectl -n monitoring rollout status deploy/kube-prometheus-stack-grafana --timeout=10s
check "Loki ready"                          kubectl -n monitoring rollout status sts/loki --timeout=10s
check "OpenCost exporting cost metrics"     kubectl -n opencost rollout status deploy/opencost --timeout=10s
check "SLO + cost PrometheusRules loaded"   kubectl -n monitoring get prometheusrule slo-error-budgets cost-allocation
check "Elasticsearch green/yellow"          bash -c "kubectl -n logging get elasticsearch logging -o jsonpath='{.status.health}' | grep -Eq 'green|yellow'"

echo "== Inference"
ALB=$(kubectl -n ml-serving get ingress ml-inference -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null)
API_KEY=$(aws secretsmanager get-secret-value --secret-id "aiml-${ENV}/inference/api-keys" --query SecretString --output text 2>/dev/null | jq -r .keys)
if [[ -n "$ALB" ]]; then
  code=$(curl -s -o /dev/null -w '%{http_code}' -m 10 "http://$ALB/v1/predict" -H 'content-type: application/json' -d '{"instances": [[5.1,3.5,1.4,0.2]]}')
  [[ "$code" == "401" ]] && ok "predict without API key rejected (401)" || bad "predict without API key returned $code (expected 401)"
  resp=$(curl -s -m 10 "http://$ALB/v1/predict" -H 'content-type: application/json' -H "x-api-key: ${API_KEY}" -d '{"instances": [[5.1,3.5,1.4,0.2]]}')
  if jq -e '.predictions[0].label=="setosa"' <<<"$resp" >/dev/null 2>&1; then
    ok "predict via ALB -> setosa (model $(jq -r .model_version <<<"$resp"))"
  else
    bad "predict via ALB: $resp  (has the training pipeline promoted a model yet?)"
  fi
else
  bad "ALB not provisioned yet for ml-inference"
fi

echo "== Security"
check "Kyverno admission controller ready"  kubectl -n kyverno rollout status deploy/kyverno-admission-controller --timeout=10s
check "security ClusterPolicies Ready"      bash -c "kubectl get clusterpolicy verify-ml-image-signatures ml-restricted-pod-security -o jsonpath='{.items[*].status.ready}' | grep -qv false"
check "Falco running on every node"         kubectl -n falco rollout status ds/falco --timeout=10s
check "Trivy Operator ready"                kubectl -n trivy-system rollout status deploy/trivy-operator --timeout=10s
check "unsigned/untrusted image rejected"         bash -c "! kubectl -n ml-serving run unsigned-probe --image=public.ecr.aws/docker/library/busybox:1.37 --restart=Never --dry-run=server -- true 2>/dev/null"
check "no critical CVEs in ML namespaces"   bash -c "! kubectl get vulnerabilityreports -n ml-serving -o json | jq -e '[.items[].report.summary.criticalCount] | add > 0'"

echo; echo "passed: $pass  failed: $fail"
[[ $fail -eq 0 ]]

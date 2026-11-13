#!/usr/bin/env bash
# Write security outputs of `terraform apply` (stack) into the GitOps values so
# Argo CD attaches them. Run after deploy-env.sh, then commit the result.
#
#   waf_web_acl_arn  -> ml-inference ingress.wafAclArn + JupyterHub ingress annotation
#
# Usage: scripts/render-security-outputs.sh dev|prod
set -euo pipefail
ENV="${1:?usage: $0 dev|prod}"
cd "$(git rev-parse --show-toplevel)"

pushd terraform/stack >/dev/null
terraform init -input=false -reconfigure -backend-config="../envs/${ENV}/backend.hcl" >/dev/null
WAF_ARN=$(terraform output -raw waf_web_acl_arn)
popd >/dev/null

[[ "$WAF_ARN" == arn:aws:wafv2:* ]] || { echo "unexpected WAF ARN: $WAF_ARN"; exit 1; }
export WAF_ARN

yq -i '.ingress.wafAclArn = strenv(WAF_ARN)' "charts/ml-inference/values-${ENV}.yaml"

JH="platform/jupyterhub/values-${ENV}.yaml"
if yq -e '.ingress.enabled' "$JH" >/dev/null 2>&1; then
  yq -i '.ingress.annotations."alb.ingress.kubernetes.io/wafv2-acl-arn" = strenv(WAF_ARN)' "$JH"
fi

echo "WAF web ACL ${WAF_ARN} written for ${ENV}:"
git --no-pager diff --stat -- "charts/ml-inference/values-${ENV}.yaml" "$JH"
echo "Review, then: git commit -am 'security(${ENV}): attach WAF to ALB ingresses' && git push"

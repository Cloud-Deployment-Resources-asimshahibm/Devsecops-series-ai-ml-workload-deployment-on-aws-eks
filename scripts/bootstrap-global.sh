#!/usr/bin/env bash
# Phase 1: create the shared layer (state bucket, GitHub OIDC roles, ECR) and
# migrate its own state into the bucket it just created.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)/terraform/global"

[[ -f terraform.tfvars ]] || cp terraform.tfvars.example terraform.tfvars

echo ">> terraform apply (local state)"
terraform init -input=false
terraform apply -input=false

BUCKET=$(terraform output -raw state_bucket)
REGION=$(awk -F'"' '/^region/{print $2}' terraform.tfvars)
REGION=${REGION:-us-east-1}

if [[ ! -f backend.tf ]]; then
  echo ">> migrating global state to s3://${BUCKET}/global/terraform.tfstate"
  cat > backend.tf <<EOF
terraform {
  backend "s3" {
    bucket       = "${BUCKET}"
    key          = "global/terraform.tfstate"
    region       = "${REGION}"
    encrypt      = true
    kms_key_id   = "$(terraform output -raw state_kms_key_alias)"
    use_lockfile = true
  }
}
EOF
  terraform init -input=false -migrate-state -force-copy
  rm -f terraform.tfstate terraform.tfstate.backup
fi

echo
echo ">> Add these as GitHub repository *variables* (Settings > Secrets and variables > Actions > Variables):"
terraform output -json gha_role_arns | jq -r 'to_entries[] | "   \(.key) = \(.value)"'
echo
echo "   or: terraform output -json gha_role_arns | jq -r 'to_entries[] | \"\(.key) \(.value)\"' | while read k v; do gh variable set \$k --body \$v; done"

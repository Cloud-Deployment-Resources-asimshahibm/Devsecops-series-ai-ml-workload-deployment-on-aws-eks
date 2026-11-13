#!/usr/bin/env bash
# Phase 3: provision one environment (dev|prod) end-to-end with Terraform.
# Terraform also installs Argo CD and the root app, after which Argo CD
# deploys everything else from Git.
set -euo pipefail
ENV=${1:?usage: deploy-env.sh dev|prod}
ROOT=$(git rev-parse --show-toplevel)
cd "$ROOT/terraform/stack"

if grep -q "__AWS_ACCOUNT_ID__" "../envs/$ENV/backend.hcl"; then
  echo "Placeholders not rendered. Run scripts/configure.sh first."; exit 1
fi

terraform init -input=false -reconfigure -backend-config="../envs/$ENV/backend.hcl"
terraform plan -input=false -var-file="../envs/$ENV/terraform.tfvars" -out="tfplan-$ENV"
read -r -p "Apply this plan to $ENV? [y/N] " ok
[[ "$ok" == "y" ]] || { echo "aborted"; exit 1; }
terraform apply -input=false "tfplan-$ENV"

CLUSTER=$(terraform output -raw cluster_name)
aws eks update-kubeconfig --name "$CLUSTER" --region us-east-1 --alias "$CLUSTER"

echo
echo ">> Waiting for Argo CD to sync the platform (this takes 10-20 min on first run)"
"$ROOT/scripts/wait-for-apps.sh" "$CLUSTER"

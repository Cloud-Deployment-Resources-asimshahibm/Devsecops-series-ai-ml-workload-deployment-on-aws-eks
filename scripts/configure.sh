#!/usr/bin/env bash
# Render account-specific placeholders across the repo, then commit the result.
#
#   __AWS_ACCOUNT_ID__   -> your 12-digit AWS account id
#   __ADMIN_ROLE_ARN__   -> IAM role ARN of the person running this (cluster-admin)
#
# Usage: scripts/configure.sh [--account-id 123456789012] [--admin-role-arn arn:aws:iam::...:role/...]
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

ACCOUNT_ID=""
ADMIN_ROLE_ARN=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --account-id) ACCOUNT_ID="$2"; shift 2 ;;
    --admin-role-arn) ADMIN_ROLE_ARN="$2"; shift 2 ;;
    *) echo "unknown arg $1"; exit 1 ;;
  esac
done

if [[ -z "$ACCOUNT_ID" || -z "$ADMIN_ROLE_ARN" ]]; then
  IDENTITY=$(aws sts get-caller-identity --output json)
  ACCOUNT_ID=${ACCOUNT_ID:-$(jq -r .Account <<<"$IDENTITY")}
  CALLER=$(jq -r .Arn <<<"$IDENTITY")
  if [[ -z "$ADMIN_ROLE_ARN" ]]; then
    if [[ "$CALLER" == *":assumed-role/"* ]]; then
      # arn:aws:sts::ACCT:assumed-role/ROLE_NAME/session -> look up the real role ARN (handles SSO paths)
      ROLE_NAME=$(cut -d/ -f2 <<<"$CALLER")
      ADMIN_ROLE_ARN=$(aws iam get-role --role-name "$ROLE_NAME" --query Role.Arn --output text)
    else
      ADMIN_ROLE_ARN="$CALLER"   # IAM user (not recommended for prod)
    fi
  fi
fi

[[ "$ACCOUNT_ID" =~ ^[0-9]{12}$ ]] || { echo "invalid account id: $ACCOUNT_ID"; exit 1; }

echo "Account ID     : $ACCOUNT_ID"
echo "Admin principal: $ADMIN_ROLE_ARN"

FILES=$(grep -rlE '__AWS_ACCOUNT_ID__|__ADMIN_ROLE_ARN__' \
  --include='*.yaml' --include='*.yml' --include='*.tf' --include='*.tfvars' --include='*.hcl' --include='*.md' \
  --exclude-dir=.git --exclude-dir=docs . || true)

for f in $FILES; do
  sed -i.bak -e "s|__AWS_ACCOUNT_ID__|${ACCOUNT_ID}|g" -e "s|__ADMIN_ROLE_ARN__|${ADMIN_ROLE_ARN}|g" "$f" && rm -f "$f.bak"
  echo "  rendered $f"
done

echo
echo "Done. Review with 'git diff', then commit + push so Argo CD sees the real values:"
echo "  git commit -am 'chore: configure account ${ACCOUNT_ID}' && git push"

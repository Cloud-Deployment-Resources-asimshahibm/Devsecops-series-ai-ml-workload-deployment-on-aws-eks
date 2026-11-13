#!/usr/bin/env bash
# Poll Argo CD Applications until all are Synced + Healthy (or timeout).
set -euo pipefail
CTX=${1:-$(kubectl config current-context)}
TIMEOUT=${TIMEOUT:-2400}
deadline=$(( $(date +%s) + TIMEOUT ))

while true; do
  table=$(kubectl --context "$CTX" -n argocd get applications.argoproj.io \
    -o custom-columns=NAME:.metadata.name,WAVE:.metadata.annotations.argocd\\.argoproj\\.io/sync-wave,SYNC:.status.sync.status,HEALTH:.status.health.status \
    --sort-by=.metadata.name 2>/dev/null || true)
  clear 2>/dev/null || true
  echo "$table"
  total=$(tail -n +2 <<<"$table" | grep -c . || true)
  ready=$(tail -n +2 <<<"$table" | awk '$3=="Synced" && $4=="Healthy"' | grep -c . || true)
  echo; echo "ready: $ready / $total"
  if [[ "$total" -gt 1 && "$ready" -eq "$total" ]]; then echo "All applications Synced & Healthy"; exit 0; fi
  if [[ $(date +%s) -gt $deadline ]]; then echo "Timed out — see docs/TROUBLESHOOTING.md"; exit 1; fi
  sleep 20
done

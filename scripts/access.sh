#!/usr/bin/env bash
# Open local tunnels to every UI and print credentials.
#   scripts/access.sh            -> all UIs
#   scripts/access.sh grafana    -> just one
set -euo pipefail
WHAT=${1:-all}
ENV=${ENV:-dev}

declare -A PF=(
  [argocd]="argocd svc/argocd-server 8080:80"
  [grafana]="monitoring svc/kube-prometheus-stack-grafana 3000:80"
  [prometheus]="monitoring svc/kube-prometheus-stack-prometheus 9090:9090"
  [alertmanager]="monitoring svc/kube-prometheus-stack-alertmanager 9093:9093"
  [argo-workflows]="argo svc/argo-workflows-server 2746:2746"
  [jupyterhub]="jupyterhub svc/proxy-public 8000:80"
  [ray]="ray svc/ml-ray-head-svc 8265:8265"
  [kibana]="logging svc/logging-kb-http 5601:5601"
  [inference]="ml-serving svc/ml-inference 8081:80"
  [opencost]="opencost svc/opencost 9091:9090"
)

creds() {
  echo "---------------------------------------------------------------"
  echo "Argo CD      http://localhost:8080   admin / $(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' 2>/dev/null | base64 -d || echo '<rotated>')"
  echo "Grafana      http://localhost:3000   admin / $(aws secretsmanager get-secret-value --secret-id "aiml-$ENV/grafana/admin" --query SecretString --output text 2>/dev/null | jq -r '."admin-password"' || echo '<see Secrets Manager>')"
  echo "Kibana       http://localhost:5601   elastic / $(kubectl -n logging get secret logging-es-elastic-user -o jsonpath='{.data.elastic}' 2>/dev/null | base64 -d || echo '?')"
  echo "Argo WF      http://localhost:2746"
  echo "JupyterHub   http://localhost:8000   (GitHub login)"
  echo "Ray          http://localhost:8265"
  echo "Prometheus   http://localhost:9090   Alertmanager http://localhost:9093"
  echo "Inference    http://localhost:8081/docs"
  echo "OpenCost     http://localhost:9091   (cost allocation UI)"
  echo "---------------------------------------------------------------"
}

pids=()
trap 'kill "${pids[@]}" 2>/dev/null || true' EXIT
for name in "${!PF[@]}"; do
  [[ "$WHAT" == "all" || "$WHAT" == "$name" ]] || continue
  read -r ns svc ports <<<"${PF[$name]}"
  kubectl -n "$ns" port-forward "$svc" "$ports" >/dev/null 2>&1 &
  pids+=($!)
done
creds
echo "Tunnels open. Ctrl-C to close."
wait

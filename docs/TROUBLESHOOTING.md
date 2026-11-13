# Troubleshooting

## Quick triage

```bash
kubectl -n argocd get applications -o wide           # what isn't Synced/Healthy?
kubectl get pods -A | grep -Ev 'Running|Completed'   # broken pods
kubectl get nodeclaims,nodes -L workload,karpenter.sh/capacity-type
kubectl get events -A --sort-by=.lastTimestamp | tail -30
```

## Terraform

| Error | Cause | Fix |
|---|---|---|
| `Error acquiring the state lock` | concurrent run / crashed run | wait; else `terraform force-unlock <id>` (S3 lockfile) |
| `Kubernetes cluster unreachable` / `dial tcp ... i/o timeout` | API CIDR allow-list | add your IP to `cluster_endpoint_public_access_cidrs` |
| `the server has asked for the client to provide credentials` | your principal has no access entry | ensure your role is in `cluster_admin_principal_arns` (role ARN, not `assumed-role/...`) |
| `Invalid for_each argument` | you added a for_each over an unknown value | use static keys / count |
| destroy hangs on subnets/SGs | ALBs or ENIs created by controllers still exist | run `scripts/teardown.sh`, which removes k8s-owned AWS resources first |
| `InvalidParameterException: ... Karpenter` on node join | node role missing access entry | the karpenter module creates it; re-apply |

## Argo CD

| Symptom | Fix |
|---|---|
| App `Unknown` / `ComparisonError: ... CRD not found` | CRD from an earlier wave not installed yet → wait / sync parent; check that operator app is Healthy |
| `metadata.annotations: Too long` | add `ServerSideApply=true` to the app's `syncOptions` in `argocd/app-of-apps/values.yaml` |
| JupyterHub app always OutOfSync on `Secret/hub` | expected without `ignoreDifferences` (already configured) |
| Manual change reverted | self-heal is on by design — change Git instead |
| Private repo: `authentication required` | `argocd repo add https://github.com/... --username x --password <PAT>` |

## Karpenter / GPU

| Symptom | Fix |
|---|---|
| GPU pod Pending, no NodeClaim | pod lacks toleration `nvidia.com/gpu` or nodeSelector `workload: ml-gpu`; NodePool `limits` reached |
| NodeClaim `Launch failed: InsufficientInstanceCapacity` | widen `gpu.instanceFamilies` (g5, g6, g6e), allow more AZs |
| Node Ready but `nvidia.com/gpu: 0` | GPU operator device-plugin pod on that node: `kubectl -n gpu-operator get pods -o wide`; check `nvidia-operator-validator` logs |
| Spot nodes churn in dev | expected; PDBs + interruption queue drain gracefully. Set `cpu.capacityTypes: [on-demand]` if disruptive |

## Data plane

| Symptom | Fix |
|---|---|
| PVC on `efs-sc` Pending | EFS CSI controller logs (`kubectl -n kube-system logs deploy/efs-csi-controller -c csi-provisioner`); mount targets exist in all private subnets; SG allows 2049 from node SG |
| `postgres-db-init` fails `could not connect` | RDS SG must allow both node SG and cluster primary SG (Terraform does); `kubectl -n platform-system get svc platform-postgres` points at RDS address |
| JupyterHub `sqlalchemy ... password authentication failed` | db-init not yet run after a password change → sync `platform-config` |
| ExternalSecret `SecretSyncedError` | IRSA role `aiml-<env>-external-secrets` annotation on SA; secret name prefix `aiml-<env>/`; KMS decrypt allowed |
| S3 `AccessDenied` from a pod | pod's SA must be one bound in `terraform/modules/workload-identity` (namespace:name exact match) |

## Observability

| Symptom | Fix |
|---|---|
| Target missing in Prometheus | ServiceMonitor namespace/labels; kube-prometheus-stack selects all monitors (`*SelectorNilUsesHelmValues: false`) |
| Loki `no org id` / 401 | `auth_enabled: false` is set; check Alloy push URL `loki-gateway.monitoring` |
| Loki `AccessDenied` on S3 | SA `loki` annotation = `aiml-<env>-loki` role |
| Elasticsearch `yellow` | normal for 1-node dev (replicas 0 via template only for new indices) |
| Kibana empty | create data view `logs-k8s-*`; check Logstash: `kubectl -n logging logs sts/logging-ls` |
| SLO panels "No data" | no traffic / pipeline runs in the window yet (ratio is undefined with 0 events) — generate load; check `slo:sli_error:ratio_rate` in Prometheus |
| Cost dashboard empty | `kubectl -n opencost logs deploy/opencost`; Prometheus target `opencost` UP; `node_total_hourly_cost` present; NodePool panels need KSM `metricLabelsAllowlist` (set in kube-prometheus-stack values) |
| AWS bill panels empty | enable *Receive CloudWatch billing alerts* in Billing preferences; Grafana SA annotated with `aiml-<env>-grafana` role; region must be us-east-1 |
| Budget shows $0 for the env | `Environment` cost allocation tag not activated yet (`activate_cost_allocation_tags`) |
| Grafana ES datasource 401 | `es-grafana-user` ExternalSecret synced? ES file realm user `grafana` exists: `kubectl -n logging get secret es-grafana-user` |

## ML

| Symptom | Fix |
|---|---|
| Inference `/readyz` 503 forever | no `latest.json` yet → run training pipeline; or IRSA/S3 error in logs |
| `train` exit code 2 | quality gate failed — by design; inspect `metrics` artifact |
| RayJob never starts | `kubectl -n ray get rayjobs,pods`; KubeRay operator logs; worker resources fit NodePool instance sizes |
| `ModuleNotFoundError: trainer` in Ray | Ray image tag in `charts/ray-cluster/values-<env>.yaml` must be a built tag, not `bootstrap` |
| Pickle / sklearn version warning | training and inference requirements must pin identical scikit-learn/joblib/numpy |

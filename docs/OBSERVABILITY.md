# Observability: Performance, SLO / Error Budgets, Cost & Billing

This page explains **what is measured, where it is defined, and how to act on it**.

| Concern | Defined in | Viewed in |
|---|---|---|
| Metrics collection | `observability/kube-prometheus-stack`, ServiceMonitors in charts, `observability/extras/servicemonitors.yaml` | Prometheus |
| Logs | `observability/loki`, `observability/alloy`, `charts/elastic-stack` | Grafana › Explore (Loki), Kibana |
| **SLOs / SLIs / error budgets** | `charts/observability-rules/values*.yaml` → `templates/slo-rules.yaml` | Grafana › SRE › **SLO / SLI & Error Budgets** |
| **Cost allocation** | OpenCost (`observability/opencost`) + `charts/observability-rules/templates/cost-rules.yaml` | Grafana › FinOps › **Cost & Billing** |
| **AWS billing guardrails** | `terraform/modules/cost-guardrails` (Budgets), `terraform/global` (Anomaly Detection, cost allocation tags) | AWS Budgets e-mails, Cost Explorer, Grafana CloudWatch panels |
| **Performance** | metrics from app, cAdvisor, kube-state-metrics, DCGM, Ray, Argo, Karpenter, JupyterHub | Grafana › ML Platform › **Performance** |
| Platform health alerts | `observability/extras/platform-alerts.yaml`, `charts/ml-inference/templates/monitoring.yaml` | Alertmanager |

## Dashboards

| Dashboard (uid) | Folder | What it answers |
|---|---|---|
| **ML Platform — Cost & Billing** (`ml-cost-billing`) | FinOps | What do we spend per hour/month? Are we on budget? Which namespace / NodePool / instance type / Spot vs On-Demand drives it? How much is idle? How much GPU are we paying for but not using? Cost per 1k predictions, per training run, per utilised GPU-hour. The actual AWS bill month-to-date by service. |
| **ML Platform — Performance** (`ml-performance`) | ML Platform | Inference RED (throughput, errors, p50/p95/p99, Apdex, latency heatmap, model vs end-to-end latency, batch size) and USE (CPU vs request, throttling, memory vs limit, HPA, restarts, model reloads). GPU util/memory/copy/clock/power/temp. Ray utilisation, task states, object store. Pipeline duration, JupyterHub spawn time. Bin-packing efficiency, nodes per NodePool, Karpenter pod startup latency, pending pods, Argo CD sync time. |
| **ML Platform — SLO / SLI & Error Budgets** (`slo-error-budget`) | SRE | Portfolio table of all SLOs (objective, SLI, budget remaining, burn 1h/6h/3d). Per SLO (repeated row): budget gauge, "bad minutes" left, burn rate by window against 1x / 6x / 14.4x lines, budget trend, daily consumption, firing SLO alerts. |
| ML Inference — API & Model (`ml-inference`) | ML Platform | Quick operational view + logs |
| ML Platform — GPU, Karpenter, Pipelines, Ray, JupyterHub (`ml-platform-compute`) | ML Platform | Capacity overview |

## SLOs

| SLO | SLI (good / valid events) | Objective | Period (dev / prod) | Pages? |
|---|---|---|---|---|
| `ml-inference-availability` | `/v1/predict` responses that are not 5xx | 99.5 % | 7 d / 30 d | yes |
| `ml-inference-latency` | `/v1/predict` requests served in ≤ 500 ms | 99 % | 7 d / 30 d | yes |
| `ml-model-freshness` | replica-minutes with a model loaded | 99 % | 7 d / 30 d | ticket |
| `ml-training-pipeline-success` | pipeline runs ending `Succeeded` | 95 % | 7 d / 30 d | ticket |
| `jupyterhub-spawn-success` | notebook server spawns that succeed | 98 % | 7 d / 30 d | ticket |

**Error budget** = `1 − objective`. Example: 99.5 % over 30 d ⇒ 0.5 % of requests may fail ⇒ at 100 % failure that is 216 minutes.

### Recorded series

| Series | Meaning |
|---|---|
| `slo:sli_error:ratio_rate{slo, window}` | bad / valid over `5m, 30m, 1h, 2h, 6h, 1d, 3d, period` |
| `slo:burn_rate{slo, window}` | error ratio ÷ error budget (1 = consuming the budget exactly over the period) |
| `slo:sli:ratio{slo}` | achieved SLI over the period |
| `slo:error_budget_remaining:ratio{slo}` | 1 − consumed fraction (negative = SLO breached) |
| `slo:objective:ratio`, `slo:error_budget:ratio`, `slo:period_days` | metadata for dashboards |

### Alerting — multi-window, multi-burn-rate

| Alert (`burn` label) | Long / short window | Burn factor | Budget spent when it fires | Severity |
|---|---|---|---|---|
| `pageFast` | 1h / 5m | 14.4× | 2 % in 1 h | critical (page) |
| `pageSlow` | 6h / 30m | 6× | 5 % in 6 h | critical (page) |
| `ticketFast` | 1d / 2h | 3× | 10 % in 1 d | warning |
| `ticketSlow` | 3d / 6h | 1× | 10 % in 3 d | warning |
| `SLOErrorBudgetLow` | — | < 25 % left | — | info |
| `SLOErrorBudgetExhausted` | — | ≤ 0 left | — | warning |

Both windows must exceed the factor: the long window proves it is significant, the short window proves it is still happening (fast reset after recovery). SLOs with `page: false` only get the ticket alerts.

### Add or change an SLO

Edit `charts/observability-rules/values.yaml` → `slos:` (use `__WINDOW__` in the PromQL), open a PR. CI renders + validates the chart; Argo CD syncs; the dashboard picks the new SLO up automatically from `label_values(slo:objective:ratio, slo)`.

```yaml
- name: my-api-availability
  service: my-api
  team: ml-platform
  objective: 0.999
  description: "Requests answered without 5xx"
  page: true
  sli:
    errors: sum(rate(http_requests_total{job="my-api",code=~"5.."}[__WINDOW__]))
    total:  sum(rate(http_requests_total{job="my-api"}[__WINDOW__]))
```

### <a id="error-budget-policy"></a>Error budget policy

| Budget remaining (period) | Policy |
|---|---|
| > 50 % | Normal velocity. Experiments, model rollouts and platform upgrades proceed. |
| 25 – 50 % | Prefer low-risk changes; every prod promotion PR links the SLO dashboard. |
| < 25 % (`SLOErrorBudgetLow`) | Only fixes and reliability work for the affected service; model promotions need two approvers. |
| ≤ 0 (`SLOErrorBudgetExhausted`) | **Feature/model freeze** for that service until the budget recovers or a postmortem with action items is merged. Rollback-first on any page. |
| Page (`pageFast` / `pageSlow`) | Follow the alert playbook in RUNBOOK.md; roll back the latest model (`trainer.promote --rollback`) or image (`git revert`) first, investigate second. |

## Cost & billing

### Three layers

1. **Allocation (real-time, in-cluster)** — OpenCost prices every node from the AWS price list and allocates cost to containers by `max(request, usage)` for CPU / RAM / GPU, plus PV storage. Recording rules roll this up to namespace, NodePool, capacity type, instance type, idle, and unit economics.
2. **Billing (actual AWS bill)** — Grafana CloudWatch datasource reads `AWS/Billing EstimatedCharges` (month-to-date, total and by service). AWS Budgets (per environment, on the `Environment` tag) e-mail at 80 % / 100 % actual and 100 % forecast; Cost Anomaly Detection e-mails on unusual spend per service.
3. **Attribution (tags)** — every AWS resource carries `Project` + `Environment`: Terraform `default_tags`, Karpenter EC2NodeClass `costTags` (+ `nodepool`), EBS CSI `tagSpecification_*` on the `gp3` StorageClass, AWS LB Controller `defaultTags` for ALBs.

### Recorded cost series (USD)

| Series | Meaning |
|---|---|
| `cluster:cost_hourly:usd` | nodes + PVs + EKS control plane |
| `cluster:cost_monthly_projection:usd` | hourly × 730 |
| `cluster:cost_budget_utilisation:ratio` | projection ÷ `cost.monthlyBudgetUSD` |
| `cluster:cost_allocated_hourly:usd`, `cluster:cost_idle_hourly:usd`, `cluster:cost_idle:ratio` | requested vs idle node spend |
| `namespace:cost_{cpu,ram,gpu,pv}_hourly:usd`, `namespace:cost_hourly:usd` | per namespace |
| `nodepool:cost_hourly:usd`, `capacity_type:cost_hourly:usd`, `instance_type:cost_hourly:usd` | per infrastructure dimension |
| `cluster:cost_gpu_hourly:usd`, `cluster:cost_gpu_unallocated_hourly:usd` | GPU spend and GPU spend no pod requested |
| `ml:inference_cost_per_1k_predictions:usd` | ml-serving cost ÷ predictions |
| `ml:training_cost_per_run:usd` | (ml-training + ray) daily cost ÷ pipeline runs |
| `ml:gpu_cost_per_utilised_gpu_hour:usd` | GPU spend ÷ busy GPU-hours |

### Cost alerts

| Alert | Fires when |
|---|---|
| `CostMonthlyProjectionOverBudget` | run-rate projection > budget for 6 h |
| `CostHourlySpike` | hourly cost > 1.5× its 7-day average for 1 h |
| `CostIdleCapacityHigh` | > 50 % of node spend idle for 6 h |
| `CostUnallocatedGPU` | GPU capacity nobody requested costs > $X/h for 30 m |
| `CostNamespaceOverCap` | a namespace exceeds its hourly cap (`cost.namespaceHourlyUSD`) for 2 h |
| `OpenCostMetricsMissing` | OpenCost is down (cost views blind) |
| AWS Budgets e-mail | 80 % / 100 % actual or 100 % forecast of the monthly budget |
| AWS Cost Anomaly e-mail | anomaly impact ≥ `anomaly_threshold_usd` |

### Accuracy notes

- OpenCost uses **on-demand list prices**; Spot nodes therefore show an upper bound. Configure the Spot data feed (OpenCost `cloudIntegrationSecret`) if you need exact Spot pricing.
- Savings Plans / RIs / credits are only visible in the AWS bill (CloudWatch panels, Budgets, Cost Explorer).
- NAT gateway data processing, VPC endpoints, RDS, EFS and S3 are not allocated to namespaces — they appear in the AWS bill panels and the tag-filtered budget.

### One-time billing setup

1. AWS Billing console › **Billing preferences** › enable *Receive CloudWatch billing alerts* (needed for `AWS/Billing` metrics).
2. `terraform/envs/<env>/terraform.tfvars` › `budgets.alert_emails`, and `terraform/global/terraform.tfvars` › `billing_alert_emails`.
3. ~24 h after the first environment exists: set `activate_cost_allocation_tags = true` in `terraform/global/terraform.tfvars` and apply (tags must exist in billing data before activation).
4. Keep `charts/observability-rules/values-<env>.yaml › cost.monthlyBudgetUSD` equal to the Terraform budget so in-cluster and AWS alerts agree.

# Runbook — Deploying the AI/ML Platform (step by step)

> Audience: platform / DevOps engineer. Every step lists **what to run**, **what
> you should see**, and **what to do if you don't**. Run commands from the repo
> root unless stated otherwise. `ENV` is `dev` until Phase 11.

**Contents**

- [Phase 0 — Prerequisites](#phase-0--prerequisites)
- [Phase 1 — Configure the repository](#phase-1--configure-the-repository)
- [Phase 2 — Global layer: state, OIDC, ECR](#phase-2--global-layer-state-oidc-ecr)
- [Phase 3 — GitHub configuration + first image build](#phase-3--github-configuration--first-image-build)
- [Phase 4 — Provision the dev environment](#phase-4--provision-the-dev-environment)
- [Phase 5 — GitOps platform sync (what Argo CD installs, in order)](#phase-5--gitops-platform-sync)
- [Phase 6 — Secrets that need a human (JupyterHub OAuth)](#phase-6--secrets-that-need-a-human)
- [Phase 7 — Run the ML training pipeline](#phase-7--run-the-ml-training-pipeline)
- [Phase 8 — Validate inference + autoscaling](#phase-8--validate-inference--autoscaling)
- [Phase 9 — Validate observability](#phase-9--validate-observability)
- [Phase 10 — Model development in JupyterHub (CPU, GPU, Ray)](#phase-10--model-development-in-jupyterhub)
- [Phase 11 — Production rollout](#phase-11--production-rollout)
- [Phase 12 — Day-2 operations](#phase-12--day-2-operations)
- [Phase 13 — Teardown](#phase-13--teardown)
- [Operational playbooks (alerts)](#operational-playbooks)

---

## Phase 0 — Prerequisites

### 0.1 Workstation tools

| Tool | Version | Check |
|---|---|---|
| Terraform | ≥ 1.10 (S3-native locking) | `terraform version` |
| AWS CLI | v2 | `aws --version` |
| kubectl | 1.32–1.34 | `kubectl version --client` |
| Helm | ≥ 3.16 | `helm version` |
| jq, yq (mikefarah v4) | latest | `jq --version; yq --version` |
| GitHub CLI | ≥ 2.50 | `gh --version` |
| Argo Workflows CLI | v3.6.x | `argo version` |
| Python | 3.12 (local tests) | `python3 --version` |

macOS: `brew install terraform awscli kubectl helm jq yq gh argo`.

### 0.2 AWS account

1. Use an account dedicated to this platform (or a sandbox). Sign in with an **admin IAM role** (SSO recommended):
   ```bash
   aws sso login --profile aiml-admin && export AWS_PROFILE=aiml-admin
   aws sts get-caller-identity          # note Account and Arn
   ```
2. **Service quotas** (Service Quotas console › EC2), in `us-east-1`:
   - *Running On-Demand G and VT instances* ≥ **8 vCPU** (dev) / 32+ (prod) — g5.xlarge = 4 vCPU.
   - *All Standard (A, C, D, H, I, M, R, T, Z) Spot Instance Requests* ≥ 32 vCPU (dev uses Spot).
   ```bash
   aws service-quotas get-service-quota --service-code ec2 --quota-code L-DB2E81BA \
     --query 'Quota.Value'   # G and VT on-demand vCPU
   ```
   Request increases now — approval can take a day.
3. One-time service-linked role for Spot (harmless if it exists):
   ```bash
   aws iam create-service-linked-role --aws-service-name spot.amazonaws.com || true
   ```

### 0.3 GitHub

- Repository: `Cloud-Deployment-Resources-asimshahibm/DevOps-Series-AI-ML-Workload-deployment-on-AWS-EKS`.
- Argo CD pulls this repo over HTTPS. If you make it **private**, add a read-only deploy key or token in Argo CD (`argocd repo add ...`) after Phase 4.

✅ **Exit criteria:** tools installed, `aws sts get-caller-identity` works, quota requests submitted.

---

## Phase 1 — Configure the repository

```bash
git clone https://github.com/Cloud-Deployment-Resources-asimshahibm/DevOps-Series-AI-ML-Workload-deployment-on-AWS-EKS.git
cd DevOps-Series-AI-ML-Workload-deployment-on-AWS-EKS
make configure            # = scripts/configure.sh
```

`configure.sh` replaces two placeholders everywhere:

| Placeholder | Replaced with | Used in |
|---|---|---|
| `__AWS_ACCOUNT_ID__` | your 12-digit account id | ECR image repos, bucket names, IRSA role ARNs, backend.hcl |
| `__ADMIN_ROLE_ARN__` | the IAM role you are signed in with | `cluster_admin_principal_arns` (EKS cluster-admin) |

Review and push — **Argo CD reads values from Git, so they must be committed before Phase 4**:

```bash
git diff --stat
git commit -am "chore: configure AWS account"
git push origin main
```

Optional edits before pushing:

- `terraform/envs/*/terraform.tfvars` — region, CIDRs, instance types, `cluster_endpoint_public_access_cidrs` (lock to your IP: `curl -s https://checkip.amazonaws.com`).
- `platform/jupyterhub/values.yaml` — `allowed_organizations`, `admin_users`.

✅ **Exit criteria:** `grep -r __AWS_ACCOUNT_ID__ --exclude-dir=docs .` returns nothing; changes pushed.

---

## Phase 2 — Global layer: state, OIDC, ECR

```bash
make global               # = scripts/bootstrap-global.sh
```

What happens:

1. `terraform apply` in `terraform/global` with local state creates:
   - S3 bucket `aiml-tfstate-<acct>` (versioned, KMS, TLS-only, public access blocked)
   - GitHub OIDC provider + roles `aiml-gha-tf-plan`, `aiml-gha-tf-apply`, `aiml-gha-ci`
   - ECR repos `aiml/ml-inference`, `aiml/ml-training`, `aiml/ml-ray` (immutable tags, scan on push)
2. The script writes `terraform/global/backend.tf` and migrates the state into the bucket.
3. It prints the three role ARNs.

Verify:

```bash
aws s3 ls | grep aiml-tfstate
aws ecr describe-repositories --query 'repositories[].repositoryName'
aws iam list-roles --query "Roles[?starts_with(RoleName,'aiml-gha')].RoleName"
```

Commit the generated backend file so teammates/CI use remote state:

```bash
git add terraform/global/backend.tf && git commit -m "chore: global remote state" && git push
```

❗ If `apply` fails with *EntityAlreadyExists* for the OIDC provider, the account already has one: import it
`terraform import module.github_oidc.aws_iam_openid_connect_provider.github arn:aws:iam::<acct>:oidc-provider/token.actions.githubusercontent.com`.

✅ **Exit criteria:** three roles + three ECR repos exist; state is in S3.

---

## Phase 3 — GitHub configuration + first image build

### 3.1 Repository variables (not secrets — they are just ARNs)

```bash
cd terraform/global
terraform output -json gha_role_arns | jq -r 'to_entries[] | "\(.key) \(.value)"' \
  | while read -r k v; do gh variable set "$k" --body "$v"; done
cd -
gh variable list     # AWS_ROLE_TF_PLAN, AWS_ROLE_TF_APPLY, AWS_ROLE_CI
```

### 3.2 GitHub Environments

Settings › Environments:

| Environment | Protection |
|---|---|
| `dev` | none (or restrict to `main`) |
| `prod` | **Required reviewers** (you + 1), deployment branches: `main` only |

```bash
gh api -X PUT repos/{owner}/{repo}/environments/dev
gh api -X PUT repos/{owner}/{repo}/environments/prod
# then add reviewers for prod in the UI
```

### 3.3 Branch protection on `main`

Require PRs + status checks `Python lint + tests`, `Terraform fmt + validate + tflint`, `Helm lint + render + kubeconform`.

### 3.4 Build images **before** the cluster exists

The Helm values ship with tag `bootstrap`. Building first means Argo CD deploys real images on its very first sync:

```bash
gh workflow run build-and-deploy.yml
gh run watch
```

Expected: 3 images pushed to ECR (`<sha12>` tag), Trivy passes, and a bot commit
`deploy(dev): ml images <sha12>` updates `charts/*/values-dev.yaml`.

```bash
git pull
aws ecr list-images --repository-name aiml/ml-inference
```

❗ *Trivy fails on CRITICAL*: bump the base image / pinned package in `ml/*/requirements.txt` and push again.

✅ **Exit criteria:** images in ECR, `values-dev.yaml` tags ≠ `bootstrap`.

---

## Phase 4 — Provision the dev environment

First apply is done from your workstation (you watch it; later applies go through `terraform.yml`).

```bash
make deploy ENV=dev       # = scripts/deploy-env.sh dev
```

Under the hood:

```bash
cd terraform/stack
terraform init -backend-config=../envs/dev/backend.hcl
terraform plan -var-file=../envs/dev/terraform.tfvars -out=tfplan-dev
terraform apply tfplan-dev
```

Resources created (≈ 150; 25–35 min, EKS + RDS dominate):

| Order | Resource |
|---|---|
| 1 | KMS key `alias/aiml-dev-platform` |
| 2 | VPC, 12 subnets (public/private/intra/database × 3 AZ), NAT, flow logs, VPC endpoints (S3, ECR api/dkr, STS, Logs, Secrets Manager) |
| 3 | EKS `aiml-dev` + add-ons (VPC CNI w/ prefix delegation, CoreDNS, kube-proxy, Pod Identity agent, EBS CSI, EFS CSI) + `system` node group |
| 4 | Karpenter IAM (controller via Pod Identity, node role `aiml-dev-karpenter-node`), SQS interruption queue + EventBridge rules |
| 5 | S3 `ml-data`, `wf-artifacts`, `loki`; EFS + mount targets |
| 6 | RDS PostgreSQL 16 + secrets `aiml-dev/rds/{master,jupyterhub,argo_workflows}` |
| 7 | IRSA roles: ml-training, ml-inference, jupyter-user, argo-workflows, loki, external-secrets |
| 8 | Secrets `aiml-dev/grafana/admin`, `aiml-dev/jupyterhub/github-oauth`, `aiml-dev/elasticsearch/grafana` |
| 9 | In-cluster (Helm/K8s providers): `gp3` default + `efs-sc` StorageClasses, `platform-postgres` ExternalName service, AWS LB Controller, metrics-server, Karpenter, Argo CD, **root Application `root-dev`** |

Verify:

```bash
aws eks update-kubeconfig --name aiml-dev --region us-east-1 --alias aiml-dev
kubectl get nodes -L workload               # 2 × system Ready
kubectl -n kube-system get deploy karpenter aws-load-balancer-controller
kubectl -n argocd get applications          # root-dev + children appearing
```

❗ Common first-apply issues:

| Symptom | Fix |
|---|---|
| `Kubernetes cluster unreachable` during helm releases | Your IP not in `cluster_endpoint_public_access_cidrs` → fix tfvars, re-apply |
| `AccessDenied` creating access entry for `__ADMIN_ROLE_ARN__` | Phase 1 not run / not committed |
| Karpenter helm `401` pulling `oci://public.ecr.aws` | `helm registry logout public.ecr.aws` locally, re-apply |
| Apply interrupted | just re-run `make deploy ENV=dev`; Terraform is idempotent |

✅ **Exit criteria:** `terraform apply` complete; `root-dev` exists in Argo CD.

---

## Phase 5 — GitOps platform sync

```bash
make wait                 # live table of Applications until all Synced/Healthy (15–25 min)
make access               # port-forwards + prints credentials
```

Argo CD UI → http://localhost:8080 (user `admin`, password printed by `make access`).

Sync order (sync-waves) and what to check in each:

| Wave | Application | Namespace | Check |
|---|---|---|---|
| -30 | `karpenter-nodepools` | kube-system | `kubectl get nodepools,ec2nodeclasses` → `cpu`, `gpu` Ready |
| -30 | `external-secrets` | external-secrets | pods Running |
| -25 | `platform-config` | platform-system (+ others) | `kubectl get externalsecrets -A` all `SecretSynced`; Job `postgres-db-init` Completed |
| -20 | `kube-prometheus-stack` | monitoring | Prometheus, Alertmanager, Grafana Running (Karpenter launches the first `ml-cpu` node here) |
| -15 | `loki`, `eck-operator`, `gpu-operator`, `kuberay-operator` | … | operators Running |
| -10 | `alloy`, `observability-extras`, `elastic-stack`, `argo-workflows` | … | ES `green`/`yellow`, Kibana up, Argo WF server up |
| -5 | `jupyterhub` | jupyterhub | `hub` + `proxy` Running (hub may CrashLoop until Phase 6) |
| 0 | `ray-cluster`, `ml-pipelines`, `ml-inference` | ray, ml-training, ml-serving | RayCluster `ready`; WorkflowTemplate exists; inference pods **not Ready yet** (no model) — expected |

Watch Karpenter provision capacity:

```bash
kubectl get nodeclaims -w
kubectl -n kube-system logs deploy/karpenter -f | jq -r 'select(.level!="DEBUG") | .message'
```

Validate the database bootstrap:

```bash
kubectl -n platform-system logs job/postgres-db-init
# ensuring role/database jupyterhub ... ensuring role/database argo_workflows ... done
```

❗ If an app is stuck: Argo CD UI › app › *Sync status* / *Events*, or see [TROUBLESHOOTING.md](TROUBLESHOOTING.md).

✅ **Exit criteria:** all apps Synced/Healthy except `ml-inference` (Progressing until Phase 7) and possibly `jupyterhub` (until Phase 6).

---

## Phase 6 — Secrets that need a human

### 6.1 JupyterHub GitHub OAuth app

1. GitHub › Org settings › Developer settings › **OAuth Apps › New**.
   - Homepage: `http://localhost:8000` (dev) / `https://jupyter.<your-domain>` (prod)
   - Callback: `http://localhost:8000/hub/oauth_callback` (dev) — must match `platform/jupyterhub/values-dev.yaml`
2. Store credentials in Secrets Manager (never in Git):
   ```bash
   aws secretsmanager put-secret-value --secret-id aiml-dev/jupyterhub/github-oauth \
     --secret-string '{"client_id":"<id>","client_secret":"<secret>"}'
   ```
3. Force External Secrets to refresh and restart the hub:
   ```bash
   kubectl -n jupyterhub annotate externalsecret jupyterhub-github-oauth force-sync=$(date +%s) --overwrite
   kubectl -n jupyterhub rollout restart deploy/hub
   ```

### 6.2 Alertmanager receiver (recommended)

Add a Slack/PagerDuty receiver in `observability/kube-prometheus-stack/values.yaml` (`alertmanager.config.receivers`) — keep the webhook URL in Secrets Manager and mount it via an ExternalSecret. Commit → Argo CD syncs.

✅ **Exit criteria:** `jupyterhub` app Healthy; login page shows *Sign in with GitHub*.

---

## Phase 7 — Run the ML training pipeline

Option A — GitHub Actions (recommended, auditable):

```bash
gh workflow run run-training-pipeline.yml -f environment=dev -f use_ray=true -f auto_promote=true
gh run watch
```

Option B — CLI:

```bash
argo submit -n ml-training --from workflowtemplate/ml-training-pipeline \
  -p use-ray=true -p auto-promote=true --watch
```

Pipeline DAG:

```
validate-data ──► hyperparameter-tuning (RayJob on ml-ray, 16 trials) ──► train ──► [approval] ──► promote
```

Watch it:

| Where | How |
|---|---|
| Argo Workflows UI | `make access` → http://localhost:2746 › ml-training |
| Ray dashboard | http://localhost:8265 — jobs, trials, worker autoscaling (Karpenter adds `ml-cpu` nodes) |
| Logs | Grafana › Explore › Loki: `{namespace="ml-training"} \| json` |

Verify the registry:

```bash
BUCKET=aiml-dev-ml-data-<acct>
aws s3 cp s3://$BUCKET/models/iris-classifier/latest.json -     # {"version": "...", "previous": null}
aws s3 ls s3://$BUCKET/models/iris-classifier/ --recursive | tail
```

Within `MODEL_REFRESH_SECONDS` (30 s in dev) the inference pods load the model and become Ready:

```bash
kubectl -n ml-serving get pods -w
kubectl -n ml-serving logs deploy/ml-inference | grep '"model loaded"'
```

❗ `train` exits 2 → quality gate failed (accuracy < `min-accuracy`). Look at the `metrics` artifact; nothing was promoted, serving is untouched.
❗ `hyperparameter-tuning` stuck *Pending* → RayJob waiting for workers: `kubectl -n ray get pods`, `kubectl get nodeclaims` (quota? Spot capacity?).

✅ **Exit criteria:** workflow Succeeded; `latest.json` exists; `ml-inference` Healthy.

---

## Phase 8 — Validate inference + autoscaling

```bash
ALB=$(kubectl -n ml-serving get ingress ml-inference -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
curl -s http://$ALB/v1/models | jq '.version, .metadata.metrics'
curl -s http://$ALB/v1/predict -H 'content-type: application/json' \
  -d '{"instances": [[5.1,3.5,1.4,0.2],[6.7,3.0,5.2,2.3]]}' | jq
# -> setosa, virginica
```

Swagger UI: `http://$ALB/docs`.

Load test → HPA → Karpenter:

```bash
kubectl run load --rm -it --image=williamyeh/hey --restart=Never -- \
  -z 5m -c 50 -m POST -T application/json \
  -d '{"instances": [[5.1,3.5,1.4,0.2]]}' http://ml-inference.ml-serving/v1/predict
# second terminal
kubectl -n ml-serving get hpa -w
kubectl get nodeclaims -w
```

Expected: HPA scales replicas up; if pods don't fit, Karpenter launches a node within ~60 s; after the test, replicas scale down after 5 min and Karpenter consolidates the node.

Run the full smoke test:

```bash
make smoke ENV=dev
```

✅ **Exit criteria:** predictions correct; HPA + Karpenter react; smoke test passes.

---

## Phase 9 — Validate observability

1. **Grafana** (http://localhost:3000): folder *ML Platform* →
   - *ML Inference — API & Model*: RPS, error ratio, p95, served version, confidence, logs panel.
   - *ML Platform — GPU, Karpenter, Pipelines, Ray, JupyterHub*.
   - Built-in *Kubernetes / Compute Resources* dashboards.
2. **Prometheus** (http://localhost:9090 › Status › Targets): `ml-inference`, `karpenter`, `argocd`, `argo-workflows`, `ml-ray`, `dcgm-exporter` (when a GPU node exists), `loki`, `alloy` all **UP**.
3. **Alerts**: Prometheus › Alerts shows `ml-inference.slo`, `gpu`, `karpenter`, `pipelines`, `gitops`, `secrets` groups. Fire a test:
   ```bash
   kubectl -n ml-serving scale deploy/ml-inference --replicas=0   # HPA restores it; or:
   kubectl -n monitoring exec sts/alertmanager-kube-prometheus-stack-alertmanager -- \
     amtool alert add test severity=warning --annotation=summary="runbook test" --alertmanager.url=http://localhost:9093
   ```
4. **Loki**: Grafana › Explore › Loki:
   ```logql
   {namespace="ml-serving"} | json | status >= 400
   sum by (level) (count_over_time({namespace=~"ml-.*"} | json [5m]))
   ```
5. **SLO / error budgets**: Grafana › SRE › *ML Platform — SLO / SLI & Error Budgets*. All 5 SLOs listed with objective and budget. They read "No data" until there is traffic/runs — generate some with the Phase 8 load test and Phase 7 pipeline. Check the rules are loaded:
   ```bash
   kubectl -n monitoring get prometheusrule slo-error-budgets cost-allocation
   # Prometheus UI: query  slo:error_budget_remaining:ratio  and  slo:burn_rate{window="1h"}
   ```
   Fire a burn-rate alert on purpose (dev): break the model store access for 10 min, e.g. pin a missing version
   `model.version: does-not-exist` in `charts/ml-inference/values-dev.yaml` → push → `SLOErrorBudgetBurn{slo="ml-model-freshness"}` goes pending. Revert afterwards.
6. **Performance**: Grafana › ML Platform › *ML Platform — Performance* — during the Phase 8 load test watch p95/p99, Apdex, CPU vs request (HPA target 65 %), throttling, HPA replicas, Karpenter pod startup time and bin-packing.
7. **Cost & billing**:
   - OpenCost: `kubectl -n opencost port-forward svc/opencost 9091:9090` → http://localhost:9091 (allocation UI); metrics after ~10 min: query `node_total_hourly_cost`.
   - Grafana › FinOps › *ML Platform — Cost & Billing*: run-rate, projection vs budget, namespace table, NodePool, Spot vs On-Demand, GPU unallocated, cost per 1k predictions.
   - AWS bill panels need **Billing preferences › Receive CloudWatch billing alerts** enabled once per account (data appears within ~6 h).
   - Budgets: `aws budgets describe-budgets --account-id <acct> --query 'Budgets[].BudgetName'` → `aiml-dev-monthly-total`, `aiml-dev-monthly-ec2-compute`. Add recipients in `terraform/envs/dev/terraform.tfvars › budgets.alert_emails`.
   - ~24 h after the first env apply: set `activate_cost_allocation_tags = true` (+ `billing_alert_emails`) in `terraform/global/terraform.tfvars` and re-run `make global` so tag-filtered budgets and Cost Explorer "group by Environment / nodepool" work.
8. **ELK**: Kibana (http://localhost:5601, user `elastic`, password from `make access`) › Stack Management › Data Views › create `logs-k8s-*` (time field `@timestamp`) › Discover:
   `k8s.namespace : "ml-serving" and app.msg : "model loaded"`.
   ILM: Stack Management › Index Lifecycle Policies › `logs-k8s` (7 d in dev).

✅ **Exit criteria:** dashboards populated (Inference, Platform, Performance, SLO, Cost & Billing), all targets UP incl. `opencost`, test alert visible in Alertmanager, logs searchable in both Loki and Kibana, budgets exist.

---

## Phase 10 — Model development in JupyterHub

1. `make access` → http://localhost:8000 → *Sign in with GitHub* (must be in the allowed org).
2. Choose a profile:
   - **CPU — small / large**: lands on `ml-cpu` Karpenter nodes.
   - **GPU — 1× A10G**: Karpenter launches a `g5`/`g6` node (3–5 min cold start), GPU operator advertises `nvidia.com/gpu`.
3. In a notebook:
   ```python
   # GPU check (GPU profile)
   import torch; torch.cuda.is_available(), torch.cuda.get_device_name(0)

   # S3 through IRSA — no keys
   import boto3; boto3.client("s3").list_objects_v2(Bucket="aiml-dev-ml-data-<acct>", Prefix="models/")["KeyCount"]

   # Distributed compute on the shared Ray cluster (RAY_ADDRESS is preset)
   import ray; ray.init()
   @ray.remote
   def square(x): return x * x
   ray.get([square.remote(i) for i in range(100)])[:5]
   ```
   Your client Python/Ray versions should match the cluster image (Ray 2.40, Python 3.12) for Ray Client; for heavy jobs prefer submitting a RayJob or an Argo Workflow.
4. Storage: `~/` is your EFS-backed home (survives restarts); `~/shared` is the team volume.
5. Idle servers are culled after 1 h (dev) → nodes consolidate → cost back to baseline.

✅ **Exit criteria:** CPU and GPU servers start; S3 and Ray calls succeed.

---

## Phase 11 — Production rollout

1. **Harden `terraform/envs/prod/terraform.tfvars`**:
   - `cluster_endpoint_public_access_cidrs` → your VPN/office CIDRs.
   - review instance sizes and RDS class.
2. **Pin the Karpenter AMI** in `charts/karpenter-nodepools/values-prod.yaml` (`amiAlias: al2023@vYYYYMMDD`).
3. **DNS/TLS**: request ACM certs; set `ingress.host` + `certificateArn` in `charts/ml-inference/values-prod.yaml` and `platform/jupyterhub/values-prod.yaml`; create Route 53 aliases to the ALB.
4. Open a PR with these changes → `terraform.yml` posts the **prod plan** → review → merge.
5. Apply prod (environment approval required):
   ```bash
   gh workflow run terraform.yml -f environment=prod
   ```
   Approve in the Actions UI. The first prod apply takes ~35 min.
6. Add a kube context and wait for GitOps:
   ```bash
   aws eks update-kubeconfig --name aiml-prod --region us-east-1 --alias aiml-prod
   scripts/wait-for-apps.sh aiml-prod
   ```
7. Repeat Phase 6 for prod secrets (`aiml-prod/jupyterhub/github-oauth`).
8. **Promote images** dev → prod:
   ```bash
   gh workflow run promote-prod.yml           # opens PR "deploy(prod): ml images <tag>"
   ```
   Complete the checklist in the PR, get approval, merge → Argo CD in prod syncs.
9. Train in prod: nightly CronWorkflow runs at 03:00 UTC with `auto-promote=false`; approve promotion:
   ```bash
   argo -n ml-training list
   argo -n ml-training resume <workflow-name>     # after reviewing metrics
   ```
   or trigger now: `gh workflow run run-training-pipeline.yml -f environment=prod -f auto_promote=false`.
10. `kubectl config use-context aiml-prod && make smoke ENV=prod`.

✅ **Exit criteria:** prod smoke test green; promotion PR merged; model served in prod.

---

## Phase 12 — Day-2 operations

| Task | Procedure |
|---|---|
| **Deploy new model code** | PR to `ml/` → merge → dev auto-deploys → `promote-prod.yml` PR |
| **Retrain** | `run-training-pipeline.yml` or wait for nightly CronWorkflow |
| **Roll back a model** (seconds, no deploy) | `kubectl -n ml-training run rollback --rm -it --restart=Never --overrides='{"spec":{"serviceAccountName":"ml-training"}}' --image=<acct>.dkr.ecr.us-east-1.amazonaws.com/aiml/ml-training:<tag> -- trainer.promote --model-store s3://aiml-<env>-ml-data-<acct>/models --rollback` |
| **Pin a model version** | set `model.version: <version>` in `charts/ml-inference/values-<env>.yaml` → PR |
| **Roll back app/chart** | `git revert <deploy commit>` → Argo CD syncs |
| **Upgrade a platform component** | bump `chart.version` in `argocd/app-of-apps/values.yaml` → PR → dev → prod |
| **Upgrade EKS** | bump `kubernetes_version` (one minor at a time) → PR → apply dev → verify → prod. Karpenter replaces nodes via drift. |
| **Node patching** | Karpenter `expireAfter: 720h` recycles nodes monthly; prod: bump pinned `amiAlias` |
| **Scale limits** | `charts/karpenter-nodepools/values-<env>.yaml` → `limits` |
| **Rotate RDS app passwords** | `terraform apply -replace='module.database.random_password.app["jupyterhub"]'` → ESO syncs → re-sync `platform-config` (db-init re-applies) → restart hub |
| **Grafana admin password** | `aws secretsmanager get-secret-value --secret-id aiml-<env>/grafana/admin` |
| **Backups** | RDS automated backups (3 d dev / 14 d prod) + final snapshot; EFS AWS Backup policy on; S3 versioning; Git is the backup for everything else |
| **Restore RDS** | restore snapshot to new instance → change `postgres_address` input (ExternalName) via Terraform → restart hub/argo-server |
| **Cost review (weekly)** | Grafana *Cost & Billing*: top namespaces, idle ratio, unallocated GPU, Spot share, cost per 1k predictions trend; AWS Cost Explorer grouped by tag `Environment` / `nodepool`; adjust `cost.monthlyBudgetUSD` + Terraform `budgets` together |
| **SLO review (weekly)** | Grafana *SLO / Error Budgets*: budget remaining per SLO; apply the [error budget policy](OBSERVABILITY.md#error-budget-policy); tune objectives in `charts/observability-rules/values.yaml` via PR |

---

## Phase 13 — Teardown

```bash
make destroy ENV=dev        # = scripts/teardown.sh dev
```

Order: delete root app (cascade) → delete Ingresses/LoadBalancer Services (ALBs) → delete NodePools (Karpenter terminates nodes) → `terraform destroy`.

Leftovers by design: EFS access-point data (`reclaimPolicy: Retain`), prod RDS final snapshot, ECR images, tfstate bucket (`prevent_destroy`). Remove the global layer last, only if you are done with every env:

```bash
cd terraform/global && terraform destroy     # remove prevent_destroy first if you really mean it
```

---

## Operational playbooks

### <a id="ops-high-error-rate"></a>MLInferenceHighErrorRate (critical)

1. Grafana › *ML Inference*: which status codes, since when, which version (`Served model version` panel)?
2. Recent changes: `kubectl -n argocd get application ml-inference -o jsonpath='{.status.history[-1]}'`; `aws s3 cp s3://<bucket>/models/<name>/latest.json -`.
3. Logs: Loki `{namespace="ml-serving"} | json | level="error"`.
4. If a new model caused it → **model rollback** (Phase 12). If a new image → `git revert` the deploy commit.

### MLInferenceModelNotLoaded (critical)

1. `kubectl -n ml-serving logs deploy/ml-inference | grep "model load failed"`.
2. `AccessDenied` → IRSA: SA annotation matches `irsa_role_arns.ml-inference` output? Pod has `AWS_ROLE_ARN` env?
3. `NoSuchKey latest.json` → no model promoted yet → run Phase 7.

### KarpenterNodeClaimLaunchFailures / PodsPendingTooLong

1. `kubectl describe nodeclaim <name>` / `kubectl -n kube-system logs deploy/karpenter | grep -i error`.
2. `InsufficientInstanceCapacity` → add families/sizes to the NodePool; `VcpuLimitExceeded` → quota increase; NodePool `limits` reached → raise limits.

### SLOErrorBudgetBurn (critical = page, warning = ticket)

1. Open the SLO dashboard (`dashboard` annotation) for the `slo` label; check which windows are burning.
2. Correlate with *Performance* (latency, errors, saturation) and recent changes (Argo CD history, `latest.json`).
3. Mitigate first: model rollback / `git revert` / scale out (`autoscaling.maxReplicas`). Then root-cause.
4. If the budget is exhausted, apply the [error budget policy](OBSERVABILITY.md#error-budget-policy) (freeze promotions for that service).

### CostMonthlyProjectionOverBudget / CostHourlySpike / CostUnallocatedGPU

1. Grafana *Cost & Billing* → which namespace / NodePool / instance type moved?
2. GPU: `kubectl get nodeclaims -l karpenter.sh/nodepool=gpu`; idle notebook servers (`kubectl -n jupyterhub get pods`), finished RayJobs still holding workers (`kubectl -n ray get pods`).
3. Idle ratio high: compare requests vs usage on *Performance* (CPU vs request) and right-size requests.
4. Legit growth → raise `cost.monthlyBudgetUSD` and Terraform `budgets` in the same PR.

### GPUXidErrors

Cordon and drain the node, then delete its NodeClaim — Karpenter replaces it:
`kubectl cordon <node> && kubectl drain <node> --ignore-daemonsets --delete-emptydir-data && kubectl delete nodeclaim <claim>`.

### ExternalSecretSyncFailing

`kubectl describe externalsecret -n <ns> <name>` → `AccessDenied` (IRSA role / KMS) or `ResourceNotFound` (secret name/prefix). Fix in Terraform/Git; force refresh with the `force-sync` annotation.

### ArgoCDAppDegraded / OutOfSync

Argo CD UI › app › diff + events. A failing hook (e.g. `postgres-db-init`) shows under *Sync status* — `kubectl logs job/<hook>`. Never `kubectl edit` live resources; fix in Git (self-heal will revert manual changes).

# DevSecOps — security at every stage of the pipeline

This is the **DevSecOps edition** of the AI/ML platform. It is the same EKS platform as the
DevOps edition, plus a security control (a gate, a check or a guardrail) at each stage,
from the developer's commit to the running pod:

```
 PLAN ──► CODE ──► BUILD ──► TEST ──► RELEASE ──► DEPLOY ──► OPERATE ──► MONITOR
 threat   secrets  hadolint  unit +   SBOM        Kyverno    Falco       Security
 model    SAST     Trivy     model-   cosign      admission  Trivy-Op    Posture
 OPA on   SCA      Grype     sec      SLSA        PSA        GuardDuty   dashboard
 TF plan  IaC      (fail =   tests    provenance  NetPol     Inspector   + alerts
          GHA lint  no push) DAST     verify      WAF        Config      → playbooks
```

![DevSecOps pipeline](devsecops-pipeline.png)

Principles:

1. **Fail early, fail closed.** Every stage has a *blocking* gate. A finding fails the job.
   It is not just reported.
2. **Same policy in CI and in the cluster.** The Kyverno policies that admit pods in EKS
   also run in CI against the rendered Helm charts (`scripts/policy-check.sh`). A PR cannot
   merge something the cluster would reject.
3. **Trust digests, not tags.** Only signed images, pinned by `sha256` digest, built by
   `build-and-deploy.yml` on `main`, run in ML namespaces. Prod gets the *same digests*
   that passed dev.
4. **Models are code.** A model artifact is hashed, scanned for unsafe pickle operators and
   verified again before it is loaded. Every link in the chain checks the one before it.
5. **Exceptions are explicit.** Every suppression lives in a reviewed file with a reason
   (`.checkov.yaml`, `.trivyignore`, inline `checkov:skip=…: reason`, `zizmor.yml`).

---

## 1. Stage-by-stage controls

**Block** = fails the pipeline or rejects the request. **Warn** = reported (SARIF in the
GitHub Security tab, PolicyReport, alert) without blocking.

### Stage 0 — PLAN (Terraform)

| Control | Tool | Where | Mode |
|---|---|---|---|
| Plan-time policy: S3 public-access block + SSE-KMS, RDS private + encrypted, EFS encrypted, KMS rotation, EKS secrets envelope encryption, no 0.0.0.0/0 except 80/443, **prod EKS API not public** | Conftest / OPA (`policy/terraform/*.rego`, 11 unit tests) | `terraform.yml` on the plan JSON | Block |
| Plan-time misconfiguration scan | Checkov `--framework terraform_plan` | `terraform.yml` | Block |
| Least-privilege CI roles (plan = read-only, apply = gated by the `prod` Environment) | GitHub OIDC → IAM | `terraform/modules/github-oidc` | Enforced |
| Encrypted, versioned, TLS-only state with a customer-managed KMS key; S3-native locking | Terraform | `terraform/global` | Enforced |

### Stage 1 — CODE (every PR and push, `ci.yml`)

| Control | Tool | Mode |
|---|---|---|
| Secrets in the code and the **full git history** | gitleaks (`.gitleaks.toml`) | Block |
| SAST: OWASP Top 10, Python, Dockerfile, K8s, Terraform and Actions rulesets, plus **custom ML rules** (`.semgrep/ml-security.yml`): unverified `pickle`/`joblib`/`torch.load`, `yaml.load`, `requests` without timeout, `shell=True` | Semgrep | Block (ERROR) |
| Python security linter | Bandit (`ml/bandit.yaml`) | Block (medium+) |
| Semantic code analysis | CodeQL (`codeql.yml`, weekly + PR) | Block via branch-protection code-scanning rule |
| Vulnerable dependencies | pip-audit (`--strict`) + OSV-Scanner | Block |
| New dependencies in a PR: vulnerabilities ≥ high, copyleft licences (AGPL/SSPL) | dependency-review-action | Block |
| IaC: Terraform, Dockerfiles, GitHub Actions, **rendered** Helm charts | Checkov (`.checkov.yaml`) + Trivy config (`trivy.yaml`) | Block (HIGH/CRITICAL) |
| Kubernetes admission policies applied to rendered charts (shift-left) | Kyverno CLI `test` (14 cases) + `apply` | Block |
| Workflow security: template injection, excessive `permissions`, `pull_request_target`/`workflow_run` misuse, credential persistence | zizmor (`zizmor.yml`) + actionlint | Block |
| Repo hygiene | OpenSSF Scorecard (`scorecard.yml`), Dependabot (pip, Docker, Actions, Terraform), CODEOWNERS on security paths | Warn / review |

### Stage 2 — BUILD (`build-and-deploy.yml`)

| Control | Tool | Mode |
|---|---|---|
| Dockerfile best practice (pinned versions, non-root `USER`, no `ADD` from URLs) | hadolint (`.hadolint.yaml`) | Block |
| Hardened runners (egress audit, tamper detection) | step-security/harden-runner | Audit → move to `block` with an allow-list once baselined |
| Minimal, non-root images: `python:3.12-slim-bookworm`, `USER 1000`, read-only root filesystem at runtime | Dockerfiles + chart `securityContext` | Enforced |
| **Images are built locally and scanned *before* they are pushed.** Nothing unscanned reaches ECR | `docker/build-push-action` with `load: true` | — |
| Vulnerabilities + embedded secrets + misconfiguration in the image | Trivy image (fixable HIGH/CRITICAL) | Block |
| Second opinion from a different vulnerability database | Grype (fixable CRITICAL) | Block |

### Stage 3 — TEST

| Control | Tool | Mode |
|---|---|---|
| Unit tests incl. **model-security tests**: tampered artifact rejected, malicious pickle detected by the real ModelScan, API key enforced, security headers present | pytest (`ml/tests/test_security.py`) | Block |
| Model scan inside the training pipeline: SHA-256 check, then ModelScan for unsafe pickle operators. Writes `security.json` next to the model | `scan_model.py` (Argo step `model-security-scan`) | Block (exit 4/5/6) |
| Promotion refuses a model without a passing `security.json` whose digest matches | `promote.py --require-scan` | Block |
| **DAST**: OWASP ZAP API scan of the deployed dev inference API (authenticated with `DAST_API_KEY`) | `dast.yml` (after every deploy + nightly) | Block on FAIL rules (`.zap/rules.tsv`), report uploaded as an artifact |

### Stage 4 — RELEASE (supply chain, SLSA Build L3-style)

| Control | Tool | Mode |
|---|---|---|
| SBOM (SPDX JSON) for every image | Syft (`anchore/sbom-action`) | Always |
| **Keyless signature** bound to `build-and-deploy.yml@refs/heads/main`, logged in Rekor | cosign + Sigstore Fulcio | Always |
| SBOM attestation | `cosign attest --type spdxjson` | Always |
| SLSA build provenance, pushed to ECR | `actions/attest-build-provenance` | Always |
| Signature + attestation verified before CD gets the digest | `cosign verify` / `verify-attestation` | Block |
| Prod promotion (`promote-prod.yml`): verify signature + provenance for each digest, **fresh** Trivy scan, last DAST green, then a PR with CODEOWNERS review | cosign, `gh attestation verify`, Trivy | Block |

### Stage 5 — DEPLOY (Argo CD + admission control)

| Control | Tool | Where | Mode |
|---|---|---|---|
| **Image signature verification** at admission (keyless, our workflow identity) + digest mutation | Kyverno `verify-ml-image-signatures` | `charts/security-policies` | Enforce |
| Only our ECR (+ the Argo executor) in ML namespaces | Kyverno `restrict-image-registries` | ″ | Enforce |
| No `:latest` / tag-less images | Kyverno `disallow-latest-tag` | ″ | Enforce |
| Restricted pod security: non-root, no privilege escalation, drop ALL capabilities, RuntimeDefault seccomp | Kyverno `ml-restricted-pod-security` + Pod Security Admission labels (`restricted` on `ml-serving`) | ″ + `platform-config` | Enforce |
| CPU/memory requests + memory limit | Kyverno `ml-require-requests-limits` | ″ | Enforce (prod) / Audit (dev) |
| No hostPath / hostNetwork / hostPID outside system namespaces | Kyverno `disallow-host-access` | ″ | Enforce |
| Default-deny ingress + explicit allows (Prometheus scrape, Ray, ALB → inference from the VPC CIDR) | NetworkPolicy | `security-policies`, `ml-inference` | Enforce |
| Argo CD project isolation: ML apps (`ml-workloads` project) can only deploy to ML namespaces, cannot create cluster-scoped resources | AppProject | `argocd/app-of-apps` | Enforce |
| Prod change window (no syncs 22:00–06:00 UTC; manual sync allowed for hotfixes) | Argo CD `syncWindows` | `values-prod.yaml` | Enforce |
| Secrets come only from AWS Secrets Manager (KMS-encrypted) via IRSA. Nothing secret lives in Git | External Secrets | `charts/*/templates` | Enforce |
| Edge protection for the ALB: AWS managed rules (CRS, KnownBadInputs incl. Log4Shell, IP reputation, anonymous IPs), body-size cap, per-IP rate limit, logs with `x-api-key` redacted | AWS WAFv2 (`terraform/modules/waf`) → `scripts/render-security-outputs.sh` | Terraform + ingress annotation | Block |
| API authentication (constant-time compare), security headers, Swagger docs off in prod, no service-account token mounted | FastAPI app + chart | `ml/inference`, `charts/ml-inference` | Enforce |

### Stage 6 — OPERATE (runtime)

| Control | Tool | Mode |
|---|---|---|
| Syscall-level threat detection, with custom ML rules: *shell in model-serving container*, *cryptominer in ML namespace*, *SA token read by unexpected process*, *package manager in running container* | Falco (modern eBPF) → Falcosidekick → Alertmanager + Loki | Detect + alert |
| Continuous vulnerability, exposed-secret, config-audit and RBAC scanning of what is *running* | Trivy Operator | Detect + alert |
| Policy results UI and metrics | Policy Reporter | Report |
| Model integrity re-checked at every load. A tampered artifact is refused and counted (`mlserve_model_integrity_failures_total`) | `ModelManager.verify()` | Block |
| AWS threat detection incl. **EKS Runtime Monitoring** and S3/RDS protection | GuardDuty | Detect |
| Posture: AWS FSBP + CIS AWS 3.0 standards | Security Hub (aggregates GuardDuty, Inspector, Config, Macie, Access Analyzer) | Detect |
| ECR **enhanced scanning** (continuous, re-scans on new CVEs) + EC2 | Inspector v2 | Detect |
| Config rules (encrypted volumes, no public S3, CloudTrail on, root MFA …) | AWS Config | Detect |
| Audit trail: multi-region CloudTrail with S3 **data events** on the model/data buckets, log-file validation, KMS-encrypted | CloudTrail | Record |
| External/unused access findings | IAM Access Analyzer | Detect |
| Sensitive data discovery in the ML data bucket (prod) | Macie classification job | Detect |

### Stage 7 — MONITOR & RESPOND

* Grafana **Security Posture** dashboard (`observability/extras/dashboards/security-posture.json`,
  folder *Security*): admission denials, signature failures, policy failures by namespace,
  critical/high CVEs in running images, exposed secrets, Falco events by rule and priority,
  model-integrity and auth failures.
* Prometheus alerts in `charts/observability-rules/templates/security-rules.yaml`.
  Each one has a playbook [below](#playbooks).
* The `ml-inference-authorized-traffic` SLO tracks the share of requests that pass
  authentication, so abuse eats into a visible error budget.
* Remediation SLAs (also in `SECURITY.md`): **critical 7 days**, **high 30 days**. The
  `CriticalVulnerabilityInRunningImage` alert pages in prod.

---

## 2. ML-specific threat model

| Threat | Example | Controls |
|---|---|---|
| **Malicious model artifact** (arbitrary code via pickle) | Attacker uploads a `model.pkl` whose `__reduce__` runs `os.system` | ModelScan in the pipeline · SHA-256 pinned in metadata · `promote.py --require-scan` · `ModelManager.verify()` before `load` · S3 bucket policy + KMS · CloudTrail data events · Semgrep rule `unverified-model-deserialization` |
| **Model / data tampering at rest** | Swap the artifact in S3 after promotion | Digest re-check at every load · bucket versioning · IRSA: inference role is read-only · `ModelArtifactIntegrityFailure` alert |
| **Poisoned dependency** | Typosquatted or compromised PyPI package | Pinned requirements · pip-audit + OSV · dependency review · Dependabot · Trivy/Grype in the image |
| **Compromised CI / image swap** | Push of an image built outside the pipeline | OIDC-only AWS access (no long-lived keys) · cosign keyless + Kyverno verifyImages · digest pinning · SLSA provenance verification before prod |
| **Workflow injection** | PR title with `$(curl …)` in a `run:` step | zizmor + actionlint · inputs passed through `env:` and validated · minimal `permissions:` per job · `persist-credentials: false` |
| **Inference API abuse** | Credential stuffing, scraping the model, oversized payloads | API keys in Secrets Manager · WAF rate limit + body cap + managed rules · `InferenceAuthFailureSpike` · ZAP DAST |
| **Container escape / lateral movement** | RCE in the API spawns a shell, reads the SA token | Non-root, read-only root FS, drop ALL, seccomp · no SA token mounted · NetworkPolicies · Falco ML rules · GuardDuty Runtime Monitoring |
| **GPU / compute hijacking** | Cryptominer on a GPU node | Falco cryptominer rule · Karpenter limits · cost anomaly alerts (`CostHourlySpike`) |
| **Sensitive training data exposure** | PII in the data bucket, a public bucket | Macie · S3 public-access block (OPA-enforced) · KMS · Access Analyzer |
| **Notebook as an entry point** | Secrets hard-coded in a JupyterHub notebook | GitHub OAuth for JupyterHub · per-user IRSA scope · gitleaks on anything committed · WAF in front of the hub |

---

## 3. Compliance mapping (indicative)

| Framework | How this repo maps |
|---|---|
| **SLSA v1.0 Build track** | L2: hosted build + signed provenance (`attest-build-provenance`). Toward L3: isolated, ephemeral GitHub-hosted runners, provenance verified before prod (`promote-prod.yml`) |
| **NIST SSDF (SP 800-218)** | PO.3 (toolchain: pinned scanners) · PS.1–PS.3 (protect code, signed releases, SBOM) · PW.4/PW.7/PW.8 (dependency review, SAST, DAST) · RV.1–RV.3 (Trivy Operator, Inspector, SLA alerts, SECURITY.md) |
| **CIS Amazon EKS Benchmark** | Private endpoint / restricted CIDRs (OPA-enforced for prod) · secrets envelope encryption · audit logs · PSA + Kyverno restricted profile · NetworkPolicies · IRSA |
| **CIS AWS Foundations 3.0** | Security Hub standard enabled · CloudTrail + Config · KMS rotation · S3 public access block |
| **OWASP ML Security Top 10** | ML06 (AI supply chain) → ModelScan, signing, digests · ML10 (model poisoning) → integrity checks, data-bucket controls · ML05 (model theft) → auth, WAF, rate limits |
| **OWASP Top 10 for LLM Apps** (if you serve LLMs later) | LLM03 supply chain → same controls · LLM10 unbounded consumption → WAF rate limit, HPA max, cost alerts |

---

## 4. Running the gates locally

```bash
# secrets, SAST, deps
gitleaks dir . --config .gitleaks.toml --redact
semgrep scan --config p/owasp-top-ten --config .semgrep/ml-security.yml --error .
bandit -r ml -c ml/bandit.yaml -ll -ii
pip-audit -r ml/inference/requirements.txt -r ml/training/requirements.txt

# IaC + policies
checkov --config-file .checkov.yaml
trivy config --config trivy.yaml .
conftest verify -p policy/terraform
scripts/policy-check.sh                      # Kyverno test + apply on rendered charts

# workflows + Dockerfiles
zizmor --config zizmor.yml .github/workflows && actionlint
hadolint --config .hadolint.yaml ml/*/Dockerfile*

# model security
cd ml && pytest -q tests/test_security.py
```

Verify a running image yourself:

```bash
IMG=$(yq '.image.repository + "@" + .image.digest' charts/ml-inference/values-dev.yaml)
cosign verify "$IMG" \
  --certificate-identity "https://github.com/<org>/<repo>/.github/workflows/build-and-deploy.yml@refs/heads/main" \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com
gh attestation verify "oci://$IMG" --repo <org>/<repo>
cosign download attestation --predicate-type https://spdx.dev/Document "$IMG" | jq -r .payload | base64 -d | jq '.predicate.packages | length'
```

## 5. Exceptions process

1. Prefer a fix: upgrade the package, change the code, harden the resource.
2. If you can't fix it yet, add a **time-boxed** exception with a reason and an owner:
   * vulnerability → `.trivyignore` (`CVE-… exp:YYYY-MM-DD # reason, owner`)
   * IaC check → inline `#checkov:skip=CKV_…: reason`, or `.checkov.yaml` for repo-wide cases
   * Kyverno → a `PolicyException` in the workload's namespace (reviewed by `@security` via CODEOWNERS)
3. Security-relevant paths (`.github/`, `policy/`, `charts/security-policies/`, scanner
   configs, `terraform/modules/security-baseline`) need a CODEOWNERS approval.

---

## Playbooks

### <a id="sec-image-signature"></a>KyvernoImageSignatureVerificationFailed (critical)
Something tried to run an image in an ML namespace that our workflow did not sign.
1. `kubectl get events -A --field-selector reason=PolicyViolation | grep verify-ml-image` shows the image and who applied it.
2. Was it a legitimate, unsigned build, e.g. a manual `docker push`? Revert it. Only `build-and-deploy.yml` may publish.
3. Otherwise treat it as a **supply-chain incident**. Check CloudTrail `PutImage` events for the repository, rotate the CI role trust if needed, and look for other pushes.

### <a id="sec-model-integrity"></a>ModelArtifactIntegrityFailure (critical)
The inference service refused a model whose SHA-256 does not match its metadata, or that has no passing scan (log: `model rejected by integrity check`).
1. The service keeps serving the previous verified model. Confirm with `/readyz` and the `model_version` in `/predict`.
2. `aws s3api list-object-versions --bucket <models-bucket> --prefix <model>/<version>/` shows who changed what (CloudTrail data events).
3. Restore the last good object version, or re-run the pipeline. **Do not** turn off `REQUIRE_MODEL_SCAN`.

### <a id="sec-critical-cve"></a>CriticalVulnerabilityInRunningImage / SecretExposedInImage
1. `kubectl get vulnerabilityreports -n <ns> -o wide`, or the Security Posture dashboard.
2. Fix it in `ml/*/requirements.txt` or the base image. Merge, and `build-and-deploy.yml` ships a new signed digest. Promote it with `promote-prod.yml`.
3. For an exposed secret: **rotate it first** (Secrets Manager), then rebuild.

### <a id="sec-policy"></a>KyvernoPolicyViolations / KyvernoAdmissionDenials / CriticalMisconfigurationDetected
1. Policy Reporter UI: `kubectl -n kyverno port-forward svc/policy-reporter-ui 8082:8080`.
2. Fix the chart values. CI's `k8s-policy` job reproduces the result locally with `scripts/policy-check.sh`.

### <a id="sec-kyverno-down"></a>KyvernoWebhookDown (critical)
Admission control is degraded. Kyverno's webhooks fail closed for the ML namespaces, so deploys there will fail.
`kubectl -n kyverno get pods`, check the logs. Never delete the webhook configurations to "unblock" a deploy.

### <a id="sec-falco"></a>FalcoCriticalEvent / FalcoWarningEventsSpike
1. Grafana › Explore › Loki `{priority="Critical"} | json` (Falcosidekick labels) gives the pod, container, command and user.
2. A shell or package manager in a serving pod, or a cryptominer: **isolate first**. Label the pod `quarantine=true` and apply a deny-all NetworkPolicy, or cordon the node. Keep the pod for forensics, then delete it.
3. Check GuardDuty (EKS Runtime Monitoring) findings for the same node and time.

### <a id="sec-auth"></a>InferenceAuthFailureSpike
1. WAF logs (`aws-waf-logs-<env>`): find the top client IPs.
2. Credential stuffing: add a WAF IP-set block rule, or lower `rate_limit_per_5min`.
3. A leaked key: rotate the `inference/api-keys` secret. External Secrets refreshes it within 15 min; restart the pods to pick it up at once.

### <a id="playbooks"></a>General incident flow
Detect (alert) → triage (dashboard, Loki, Security Hub) → contain (quarantine, WAF block, revoke the role) → eradicate (fix, rebuild, re-sign) → recover (promote verified digests) → post-mortem (add a test or policy so it can't recur).

"""Pictorial DevSecOps pipeline: the security control at every stage, with tool icons.

Icons: AWS architecture icons, CNCF / project logos, Simple Icons and Lucide symbols in ./icons.

Regenerate:
    pip install playwright && playwright install chromium   # once
    python docs/diagrams/devsecops_pipeline.py
Writes docs/diagrams/devsecops-pipeline.html and docs/devsecops-pipeline.png
"""

from __future__ import annotations

import asyncio
import base64
import html
from pathlib import Path

HERE = Path(__file__).resolve().parent
ICONS = HERE / "icons"
HTML_OUT = HERE / "devsecops-pipeline.html"
PNG_OUT = HERE.parent / "devsecops-pipeline.png"
W = 1920

TITLE = "DevSecOps-Series — AI/ML Workload Deployment on AWS EKS: security at every stage"
SUBTITLE = (
    "Shift-left gates in GitHub Actions · signed, digest-pinned supply chain · the same policy in CI and at admission · "
    "runtime detection · AWS security services · one Security Posture view"
)

# mode -> (label, colour)
MODES = {
    "block": ("BLOCK", "#dc2626"),
    "enforce": ("ENFORCE", "#7c3aed"),
    "attest": ("ATTEST", "#2563eb"),
    "detect": ("DETECT", "#d97706"),
    "warn": ("REPORT", "#64748b"),
}

# (stage, colour, [(icon, title, detail, mode)])
STAGES = [
    ("PLAN", "#0f766e", [
        ("opa.png", "OPA / Conftest", "11 policies on the Terraform plan", "block"),
        ("checkov.png", "Checkov (plan)", "misconfig in resolved plan", "block"),
        ("key-management-service.png", "KMS-encrypted state", "CMK · TLS-only · S3 locking", "enforce"),
        ("identity-and-access-management-iam-role.png", "GitHub OIDC roles", "no long-lived keys", "enforce"),
    ]),
    ("CODE", "#1d4ed8", [
        ("lu-key-round.svg", "gitleaks", "secrets in full git history", "block"),
        ("lu-search-code.svg", "Semgrep + ML rules", "OWASP · unsafe pickle load", "block"),
        ("si-python.svg", "Bandit · CodeQL", "Python SAST", "block"),
        ("lu-package-check.svg", "pip-audit · OSV", "+ dependency & licence review", "block"),
        ("trivy.png", "Checkov · Trivy config", "Terraform · Docker · K8s · GHA", "block"),
        ("kyverno.png", "Kyverno CLI", "cluster policies on rendered charts", "block"),
        ("si-githubactions.svg", "zizmor · actionlint", "workflow injection, permissions", "block"),
        ("si-dependabot.svg", "Dependabot · Scorecard", "CODEOWNERS on security paths", "warn"),
    ]),
    ("BUILD", "#0369a1", [
        ("si-docker.svg", "hadolint", "non-root, pinned Dockerfiles", "block"),
        ("trivy.png", "Trivy image", "CVEs · secrets · misconfig", "block"),
        ("lu-bug.svg", "Grype", "second vulnerability DB", "block"),
        ("lu-lock-keyhole.svg", "harden-runner", "egress audit on runners", "warn"),
    ]),
    ("TEST", "#9333ea", [
        ("lu-shield-check.svg", "Model-security tests", "tamper · malicious pickle · auth", "block"),
        ("lu-brain-circuit.svg", "ModelScan + SHA-256", "Argo step before promotion", "block"),
        ("lu-stamp.svg", "Promotion gate", "needs passing security.json", "block"),
        ("zap.png", "OWASP ZAP DAST", "authenticated API scan of dev", "block"),
    ]),
    ("RELEASE", "#2563eb", [
        ("lu-scroll-text.svg", "Syft SBOM", "SPDX, attested to the image", "attest"),
        ("lu-file-signature.svg", "cosign keyless", "Sigstore · Fulcio · Rekor", "attest"),
        ("lu-fingerprint.svg", "SLSA provenance", "GitHub artifact attestations", "attest"),
        ("ec2-container-registry.png", "ECR by digest", "immutable · KMS · scanned", "enforce"),
        ("lu-gavel.svg", "promote-prod gates", "re-verify sig · provenance · CVEs · DAST", "block"),
    ]),
    ("DEPLOY", "#7c3aed", [
        ("kyverno.png", "Kyverno admission", "verify signature · pin digest", "enforce"),
        ("elastic-kubernetes-service.png", "Pod Security", "PSA restricted + Kyverno", "enforce"),
        ("lu-workflow.svg", "NetworkPolicies", "default-deny ingress", "enforce"),
        ("argocd.png", "Argo CD projects", "isolation · prod sync window", "enforce"),
        ("waf.png", "AWS WAF", "managed rules · rate limit", "enforce"),
        ("external-secrets.png", "External Secrets", "Secrets Manager · API keys", "enforce"),
    ]),
    ("OPERATE", "#d97706", [
        ("falco.png", "Falco", "eBPF · custom ML rules", "detect"),
        ("trivy.png", "Trivy Operator", "running-image CVEs, secrets", "detect"),
        ("guardduty.png", "GuardDuty", "EKS Runtime Monitoring", "detect"),
        ("inspector.png", "Inspector v2", "ECR enhanced scanning", "detect"),
        ("cloudtrail.png", "CloudTrail · Config", "S3 data events · rules", "detect"),
        ("macie.png", "Macie · Access Analyzer", "PII in data · external access", "detect"),
    ]),
    ("MONITOR", "#be123c", [
        ("grafana.png", "Security Posture", "Grafana dashboard", "warn"),
        ("prometheus.png", "Security alerts", "signatures · CVEs · Falco · auth", "detect"),
        ("security-hub.png", "Security Hub", "FSBP + CIS AWS 3.0", "detect"),
        ("lu-siren.svg", "Playbooks + SLAs", "critical 7 d · high 30 d", "warn"),
    ]),
]

# (icon, label) chains; "»" items are gate badges between steps
IMAGE_PATH = [
    ("users.png", "Developer\nPR"),
    ("github-actions.png", "DevSecOps CI\n11 gates"),
    ("trivy.png", "Build + scan\nbefore push"),
    ("lu-file-signature.svg", "Sign + SBOM\n+ provenance"),
    ("ec2-container-registry.png", "ECR\n@sha256 digest"),
    ("github.png", "Git pins\ndigest (GitOps)"),
    ("argocd.png", "Argo CD\nsync"),
    ("kyverno.png", "Kyverno\nverifies signature"),
    ("elastic-kubernetes-service.png", "EKS pod\nrestricted"),
]
MODEL_PATH = [
    ("argo-workflows.png", "Argo Workflows\ntrain"),
    ("lu-fingerprint.svg", "SHA-256\nin metadata"),
    ("lu-brain-circuit.svg", "ModelScan\nunsafe ops?"),
    ("simple-storage-service-s3.png", "S3 registry\nsecurity.json"),
    ("lu-stamp.svg", "Promote\nonly if passed"),
    ("fastapi.png", "Inference\nre-verify on load"),
    ("waf.png", "WAF + API key\nto clients"),
]


def data_uri(name: str) -> str:
    path = ICONS / name
    mime = "image/svg+xml" if path.suffix == ".svg" else "image/png"
    return f"data:{mime};base64,{base64.b64encode(path.read_bytes()).decode()}"


def esc(text: str) -> str:
    return html.escape(text)


def chain(items: list[tuple[str, str]], color: str) -> str:
    out = []
    for i, (icon, label) in enumerate(items):
        if i:
            out.append(f'<div class="arrow" style="color:{color}">&#10140;</div>')
        lines = "<br>".join(esc(x) for x in label.split("\n"))
        out.append(f'<div class="step"><img src="{data_uri(icon)}"><div>{lines}</div></div>')
    return "".join(out)


def render_html() -> str:
    cols = []
    for i, (stage, color, tools) in enumerate(STAGES):
        cards = []
        for icon, title, detail, mode in tools:
            mlabel, mcolor = MODES[mode]
            cards.append(
                f'<div class="card"><img src="{data_uri(icon)}">'
                f'<div class="txt"><b>{esc(title)}</b><span>{esc(detail)}</span></div>'
                f'<i style="background:{mcolor}">{mlabel}</i></div>'
            )
        cols.append(
            f'<div class="col"><div class="chev" style="background:{color}"><small>{i}</small>{stage}</div>'
            f'<div class="cards" style="border-color:{color}55">{"".join(cards)}</div></div>'
        )
    legend = "".join(f'<span><i style="background:{c}">{lbl}</i></span>' for lbl, c in MODES.values())
    legend_txt = (
        "BLOCK fails the pipeline or the promotion · ENFORCE rejects at admission or at the edge · "
        "ATTEST produces signed evidence · DETECT raises findings + alerts · REPORT is visibility only"
    )

    return f"""<!doctype html><html><head><meta charset="utf-8"><title>DevSecOps pipeline</title>
<style>
  body {{ margin:0; background:#fff; font-family: Inter, "Segoe UI", Helvetica, Arial, sans-serif; color:#0f172a; }}
  #c {{ width:{W}px; box-sizing:border-box; padding:18px 22px 22px; background:#fff; }}
  h1 {{ margin:0; font-size:27px; letter-spacing:-.3px; }}
  .sub {{ margin:6px 0 14px; font-size:13.5px; color:#475569; }}
  .cols {{ display:flex; gap:10px; align-items:stretch; }}
  .col {{ flex:1; display:flex; flex-direction:column; min-width:0; }}
  .chev {{ position:relative; color:#fff; font-weight:800; font-size:17px; letter-spacing:1px; padding:11px 0 11px 28px;
          clip-path: polygon(0 0, calc(100% - 16px) 0, 100% 50%, calc(100% - 16px) 100%, 0 100%, 12px 50%); }}
  .col:first-child .chev {{ clip-path: polygon(0 0, calc(100% - 16px) 0, 100% 50%, calc(100% - 16px) 100%, 0 100%); padding-left:16px; }}
  .chev small {{ font-size:11px; opacity:.8; margin-right:7px; }}
  .cards {{ flex:1; margin-top:8px; border:2px solid; border-radius:12px; padding:8px; background:#f8fafc; }}
  .card {{ position:relative; display:flex; align-items:center; gap:9px; background:#fff; border:1px solid #e2e8f0;
           border-radius:10px; padding:8px 8px 8px 7px; margin-bottom:7px; box-shadow:0 1px 2px rgba(15,23,42,.07); }}
  .card img {{ width:36px; height:36px; object-fit:contain; flex:none; }}
  .txt {{ min-width:0; padding-right:4px; }}
  .txt b {{ display:block; font-size:12.5px; line-height:1.2; }}
  .txt span {{ display:block; font-size:10.8px; color:#475569; line-height:1.25; margin-top:2px; }}
  i {{ font-style:normal; color:#fff; font-size:8.5px; font-weight:800; letter-spacing:.6px; padding:2px 5px; border-radius:4px; }}
  .card i {{ position:absolute; right:6px; top:-6px; }}
  .band {{ margin-top:16px; border:2px solid; border-radius:14px; padding:10px 14px 12px; }}
  .band h2 {{ margin:0 0 8px; font-size:15px; }}
  .band h2 em {{ font-style:normal; font-weight:500; color:#475569; font-size:12.5px; margin-left:8px; }}
  .flow {{ display:flex; align-items:center; justify-content:space-between; }}
  .step {{ text-align:center; font-size:11.5px; line-height:1.25; width:150px; }}
  .step img {{ width:44px; height:44px; object-fit:contain; display:block; margin:0 auto 4px; background:#fff; border-radius:10px;
              padding:4px; box-shadow:0 1px 3px rgba(15,23,42,.2); }}
  .step div::first-line {{ font-weight:700; }}
  .arrow {{ font-size:24px; font-weight:700; }}
  .bottom {{ display:flex; gap:16px; }}
  .bottom .band {{ flex:1; }}
  .loop {{ font-size:12.5px; line-height:1.55; }}
  .loop b {{ color:#be123c; }}
  .legend {{ font-size:12px; color:#334155; }}
  .legend span {{ display:inline-block; margin:0 6px 6px 0; }}
  .legend i {{ font-size:10px; padding:3px 7px; }}
</style></head><body><div id="c">
<h1>{esc(TITLE)}</h1><div class="sub">{esc(SUBTITLE)}</div>
<div class="cols">{"".join(cols)}</div>
<div class="band" style="border-color:#2563eb;background:#eff6ff">
  <h2 style="color:#1d4ed8">Trusted image path<em>nothing unscanned leaves the runner · only images signed by build-and-deploy.yml@main are admitted · prod receives the same digests</em></h2>
  <div class="flow">{chain(IMAGE_PATH, "#2563eb")}</div>
</div>
<div class="band" style="border-color:#9333ea;background:#faf5ff">
  <h2 style="color:#7e22ce">Model supply chain<em>models are untrusted code until proven otherwise (pickle executes on load)</em></h2>
  <div class="flow">{chain(MODEL_PATH, "#9333ea")}</div>
</div>
<div class="bottom">
  <div class="band loop" style="border-color:#be123c;background:#fff1f2">
    <h2 style="color:#be123c">Feedback loop</h2>
    <b>Detect</b> Falco · Trivy Operator · GuardDuty · Inspector · Kyverno reports &#10140;
    <b>Triage</b> Grafana <i style="background:#64748b">SECURITY POSTURE</i> · Loki · Security Hub &#10140;
    <b>Contain</b> quarantine pod · WAF block · rotate secret &#10140;
    <b>Fix as a PR</b> &#10140; back through every gate above &#10140; <b>Learn</b> add a test / policy
  </div>
  <div class="band legend" style="border-color:#cbd5e1;background:#fff">
    <h2>Legend</h2>{legend}<div>{esc(legend_txt)}</div>
    <div style="margin-top:6px">Compliance mapping: SLSA · NIST SSDF · CIS EKS · CIS AWS 3.0 · OWASP ML Top 10 — see docs/DEVSECOPS.md</div>
  </div>
</div>
</div></body></html>"""


async def screenshot(html_path: Path, png_path: Path) -> None:
    from playwright.async_api import async_playwright

    async with async_playwright() as p:
        browser = await p.chromium.launch()
        page = await browser.new_page(viewport={"width": W, "height": 1200}, device_scale_factor=2)
        await page.goto(html_path.as_uri())
        await page.locator("#c").screenshot(path=str(png_path))
        await browser.close()


if __name__ == "__main__":
    HTML_OUT.write_text(render_html(), encoding="utf-8")
    asyncio.run(screenshot(HTML_OUT, PNG_OUT))
    print(f"wrote {HTML_OUT.relative_to(HERE.parent.parent)} and {PNG_OUT.relative_to(HERE.parent.parent)}")

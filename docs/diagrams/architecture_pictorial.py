"""Pictorial (icon-based) architecture diagram for the README.

Hand-placed layout (no auto-layout) so the picture stays readable. Uses the
official AWS architecture icons and project logos stored in ./icons.

Regenerate:
    pip install playwright && playwright install chromium   # once
    python docs/diagrams/architecture_pictorial.py
Writes docs/diagrams/architecture-pictorial.html and docs/architecture-pictorial.png
"""

from __future__ import annotations

import asyncio
import base64
from pathlib import Path

HERE = Path(__file__).resolve().parent
ICONS = HERE / "icons"
HTML_OUT = HERE / "architecture-pictorial.html"
PNG_OUT = HERE.parent / "architecture-pictorial.png"

W, H = 1920, 1400
ICON = 54

TITLE = "DevOps-Series (AI/ML Workload Deployment on Kubernetes — AWS-EKS and Azure-AKS Platforms)"
SUBTITLE = "AWS-EKS reference implementation · Terraform · GitHub Actions · Argo CD + Helm · Karpenter CPU/GPU · JupyterHub · Argo Workflows · KubeRay · Prometheus · Grafana · Loki · ELK · OpenCost · SLOs"

# ----------------------------------------------------------------------------- groups
# (x, y, w, h, title, border, fill, title_color)
GROUPS = [
    (20, 92, 232, 480, "GitHub · source of truth & CI", "#334155", "#f1f5f9", "#0f172a"),
    (20, 600, 232, 170, "Consumers", "#334155", "#f8fafc", "#0f172a"),
    (282, 92, 1618, 1140, "AWS Cloud · us-east-1", "#f59e0b", "#fffbeb", "#9a3412"),
    (298, 118, 680, 122, "Shared services", "#be123c", "#fff1f2", "#9f1239"),
    (1360, 118, 520, 122, "Billing & cost guardrails", "#a16207", "#fefce8", "#854d0e"),
    (300, 250, 1584, 968, "VPC · 3 AZs · public / private / intra / database subnets · flow logs", "#0891b2", "#ecfeff", "#155e75"),
    (320, 392, 1340, 806, "Amazon EKS 1.33 · KMS-encrypted secrets · access entries · IMDSv2", "#4f46e5", "#eef2ff", "#3730a3"),
    (340, 430, 280, 362, "System node group · Day-0 (Terraform)", "#6366f1", "#ffffff", "#3730a3"),
    (640, 430, 480, 362, "Karpenter NodePool · CPU (Spot + On-Demand)", "#16a34a", "#f0fdf4", "#166534"),
    (1140, 430, 500, 362, "Karpenter NodePool · GPU (g5/g6, scale-to-zero)", "#7c3aed", "#f5f3ff", "#5b21b6"),
    (340, 812, 1300, 372, "Observability · SLO / error budgets · FinOps (delivered by Argo CD)", "#ea580c", "#fff7ed", "#9a3412"),
    (1090, 846, 530, 128, "ELK on ECK (search / audit logs)", "#0ea5e9", "#f0f9ff", "#075985"),
    (1690, 392, 178, 520, "Data layer", "#475569", "#f8fafc", "#0f172a"),
]

# ----------------------------------------------------------------------------- nodes
# id: (cx, cy, icon file, label)
NODES = {
    "repo": (136, 150, "github.png", "Git monorepo\nIaC · charts · GitOps · ML"),
    "gha": (136, 262, "github-actions.png", "GitHub Actions\nCI · build · promote · train"),
    "trivy": (136, 374, "trivy.png", "Trivy · Checkov\nimage + IaC scans"),
    "tf": (136, 486, "terraform.png", "Terraform\nplan on PR · gated apply"),
    "users": (136, 670, "users.png", "ML engineers\n& API clients"),
    # shared services
    "ecr": (380, 168, "ec2-container-registry.png", "Amazon ECR\nimmutable · scan on push"),
    "iam": (520, 168, "identity-and-access-management-iam-role.png", "IAM · OIDC · IRSA\nPod Identity"),
    "kms": (650, 168, "key-management-service.png", "AWS KMS\nCMK per env"),
    "sm": (775, 168, "secrets-manager.png", "Secrets Manager\nRDS · OAuth · Grafana"),
    "sqs": (905, 168, "simple-queue-service-sqs.png", "SQS\nSpot interruptions"),
    # billing
    "cw": (1450, 168, "cloudwatch.png", "CloudWatch\nAWS/Billing"),
    "budgets": (1600, 168, "budgets.png", "AWS Budgets\n80% · 100% · forecast"),
    "ce": (1760, 168, "cost-explorer.png", "Cost Anomaly Detection\ncost allocation tags"),
    # vpc edge
    "alb": (420, 318, "elb-application-load-balancer.png", "Application LB\nACM TLS · WAF"),
    "nat": (1300, 318, "nat-gateway.png", "NAT gateway"),
    "vpce": (1450, 318, "endpoint.png", "VPC endpoints\nS3 · ECR · STS · SM"),
    # system
    "argocd": (415, 505, "argocd.png", "Argo CD\napp-of-apps"),
    "helm": (545, 505, "helm.png", "Helm charts\n(sync-waves)"),
    "karpenter": (545, 640, "karpenter.png", "Karpenter\nnode provisioning"),
    "eso": (415, 640, "external-secrets.png", "External Secrets\nOperator"),
    "eks": (480, 742, "elastic-kubernetes-service.png", "EKS control plane"),
    # cpu pool
    "cpu": (705, 515, "ec2-instances.png", "CPU nodes\nc/m/r gen>5"),
    "api": (845, 515, "fastapi.png", "ml-inference\nFastAPI · HPA · PDB"),
    "hub": (1010, 515, "jupyterhub.png", "JupyterHub\nCPU notebooks"),
    "wf": (770, 680, "argo-workflows.png", "Argo Workflows\nvalidate→tune→train→gate→promote"),
    "ray": (965, 680, "ray.png", "Ray cluster (KubeRay)\nRay Tune · RayJobs"),
    # gpu pool
    "gpu": (1220, 515, "ec2-instances.png", "GPU nodes\nNVIDIA A10G / L4"),
    "raygpu": (1385, 515, "ray.png", "Ray GPU workers\ndistributed training"),
    "hubgpu": (1555, 515, "jupyterhub.png", "GPU notebooks\nPyTorch · CUDA 12"),
    # observability
    "opencost": (420, 900, "opencost.png", "OpenCost\ncost allocation"),
    "prom": (590, 900, "prometheus.png", "Prometheus + Alertmanager\nSLO burn-rate · cost rules"),
    "grafana": (780, 900, "grafana.png", "Grafana\nPerformance · SLO · Cost"),
    "loki": (965, 900, "loki.png", "Loki + Alloy\nlogs → S3"),
    "beats": (1160, 900, "beats.png", "Filebeat"),
    "logstash": (1280, 900, "logstash.png", "Logstash"),
    "es": (1410, 900, "elasticsearch.png", "Elasticsearch\nILM"),
    "kibana": (1545, 900, "kibana.png", "Kibana"),
    # data
    "s3": (1779, 470, "simple-storage-service-s3.png", "Amazon S3 (KMS)\ndatasets · model registry\nartifacts · Loki chunks"),
    "efs": (1779, 640, "elastic-file-system-efs.png", "Amazon EFS (RWX)\nhomes · shared · scratch"),
    "rds": (1779, 800, "rds-postgresql-instance.png", "RDS PostgreSQL 16\nJupyterHub · Argo WF"),
}

# ----------------------------------------------------------------------------- edges
# (points, style, label, label_pos(x,y) or None)
STYLES = {
    "ci": ("#2563eb", "", 2.4),
    "gitops": ("#16a34a", "8 5", 2.6),
    "req": ("#0f172a", "", 2.2),
    "data": ("#475569", "", 1.8),
    "cap": ("#7c3aed", "", 2.2),
    "tel": ("#ea580c", "3 4", 2.4),
    "cost": ("#a16207", "6 4", 2.0),
}
EDGES = [
    ([(136, 211), (136, 233)], "ci", None, None),
    ([(136, 323), (136, 345)], "ci", None, None),
    ([(108, 262), (52, 262), (52, 486), (105, 486)], "ci", None, None),
    # images -> ECR
    ([(166, 374), (258, 374), (258, 244), (380, 244), (380, 230)], "ci", "② push images", (264, 300)),
    # Git -> Argo CD (pull)
    ([(166, 150), (270, 150), (270, 505), (386, 505)], "gitops", "③ Argo CD pulls Git", (276, 462)),
    # Terraform -> EKS
    ([(166, 486), (290, 486), (290, 742), (451, 742)], "ci", "① terraform apply", (176, 500)),
    # Argo CD -> Helm -> workloads / observability
    ([(444, 505), (516, 505)], "gitops", None, None),
    ([(574, 505), (638, 505)], "gitops", "sync", (584, 495)),
    ([(545, 566), (545, 580), (630, 580), (630, 810)], "gitops", None, None),
    # Karpenter -> nodes
    ([(574, 640), (656, 640), (656, 515), (676, 515)], "cap", "provisions", (586, 630)),
    ([(545, 703), (545, 780), (1132, 780), (1132, 540), (1191, 540)], "cap", "provisions GPU nodes (from 0)", (860, 772)),
    # ESO -> Secrets Manager
    ([(386, 640), (356, 640), (356, 384), (775, 384), (775, 232)], "data", "ExternalSecrets", (630, 377)),
    # Users -> ALB -> api / hub
    ([(166, 670), (304, 670), (304, 318), (391, 318)], "req", "④ HTTPS", (180, 660)),
    ([(449, 312), (845, 312), (845, 486)], "req", "/v1/predict", (700, 304)),
    ([(449, 330), (1010, 330), (1010, 486)], "req", "/hub (GitHub SSO)", (880, 346)),
    # training
    ([(799, 680), (935, 680)], "data", "⑤ RayJob", (830, 670)),
    ([(994, 680), (1300, 680), (1300, 515), (1356, 515)], "data", None, None),
    ([(1039, 515), (1125, 515), (1125, 470), (1555, 470), (1555, 486)], "data", None, None),
    # models to/from S3
    ([(770, 652), (770, 605), (930, 605), (930, 410), (1700, 410), (1700, 455), (1750, 455)], "data", "⑥ register / promote model", (1200, 402)),
    ([(874, 515), (900, 515), (900, 422), (1712, 422), (1712, 480), (1750, 480)], "data", "⑦ hot-reload latest.json", (1200, 436)),
    # EKS -> EFS / RDS
    ([(1640, 640), (1750, 640)], "data", "RWX", (1655, 630)),
    ([(1640, 800), (1750, 800)], "data", "state", (1655, 790)),
    # telemetry
    ([(1390, 792), (1390, 850), (590, 850), (590, 870)], "tel", None, None),
    ([(880, 792), (880, 850)], "tel", "⑧ metrics · DCGM GPU metrics · logs", (640, 858)),
    ([(449, 900), (556, 900)], "cost", None, None),
    ([(624, 900), (750, 900)], "tel", None, None),
    ([(936, 900), (810, 900)], "tel", None, None),
    ([(1189, 900), (1251, 900)], "data", None, None),
    ([(1309, 900), (1381, 900)], "data", None, None),
    ([(1439, 900), (1516, 900)], "data", None, None),
    # Grafana -> CloudWatch billing
    ([(780, 962), (780, 1172), (1676, 1172), (1676, 244), (1450, 244), (1450, 230)], "cost", "⑨ AWS bill (CloudWatch datasource)", (1180, 1166)),
]

# observability dashboard / SLO chips (inside obs group)
CHIPS = [
    ("Dashboards", "#9a3412", ["ML Inference", "Performance (RED/USE, GPU, Ray)", "SLO / Error Budgets", "Cost & Billing", "Platform capacity"]),
    ("SLOs", "#1d4ed8", ["Inference availability 99.5%", "Latency ≤500ms 99%", "Model freshness 99%", "Pipeline success 95%", "Notebook spawn 98%"]),
    ("Alerts", "#b91c1c", ["Burn rate 14.4× / 6× page", "3× / 1× ticket", "Budget over projection", "Unallocated GPU", "Idle capacity"]),
]

LEGEND = [
    ("ci", "CI / IaC (GitHub Actions, Terraform)"),
    ("gitops", "GitOps sync (Argo CD pull)"),
    ("req", "User / API traffic"),
    ("data", "Data & control flow"),
    ("cap", "Capacity (Karpenter)"),
    ("tel", "Telemetry"),
    ("cost", "Cost & billing"),
]


def data_uri(name: str) -> str:
    return "data:image/png;base64," + base64.b64encode((ICONS / name).read_bytes()).decode()


def esc(s: str) -> str:
    return s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


def render_html() -> str:
    parts: list[str] = []
    svg: list[str] = []

    for x, y, w, h, title, border, fill, tc in GROUPS:
        parts.append(
            f'<div class="grp" style="left:{x}px;top:{y}px;width:{w}px;height:{h}px;border-color:{border};background:{fill}">'
            f'<span style="color:{tc}">{esc(title)}</span></div>'
        )

    for name, (color, dash, width) in STYLES.items():
        svg.append(
            f'<marker id="m-{name}" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="6" markerHeight="6" orient="auto-start-reverse">'
            f'<path d="M0,0 L10,5 L0,10 z" fill="{color}"/></marker>'
        )
    for pts, style, label, lpos in EDGES:
        color, dash, width = STYLES[style]
        d = "M" + " L".join(f"{x},{y}" for x, y in pts)
        da = f' stroke-dasharray="{dash}"' if dash else ""
        svg.append(f'<path d="{d}" fill="none" stroke="{color}" stroke-width="{width}"{da} stroke-linejoin="round" marker-end="url(#m-{style})"/>')
        if label and lpos:
            parts.append(f'<div class="elbl" style="left:{lpos[0]}px;top:{lpos[1] - 9}px;color:{color}">{esc(label)}</div>')

    for _id, (cx, cy, icon, label) in NODES.items():
        lines = "<br>".join(esc(line) for line in label.split("\n"))
        parts.append(
            f'<div class="node" style="left:{cx - 80}px;top:{cy - ICON // 2}px">'
            f'<img src="{data_uri(icon)}" width="{ICON}" height="{ICON}"><div class="lbl">{lines}</div></div>'
        )

    # chips
    y0 = 1000
    for i, (title, color, items) in enumerate(CHIPS):
        x0 = 360 + i * 432
        chips = "".join(f'<span class="chip" style="border-color:{color}33;color:{color}">{esc(it)}</span>' for it in items)
        parts.append(f'<div class="chips" style="left:{x0}px;top:{y0}px"><b style="color:{color}">{title}</b>{chips}</div>')

    # legend + steps (left column)
    leg = "".join(
        f'<div class="lg"><svg width="44" height="10"><line x1="2" y1="5" x2="42" y2="5" stroke="{STYLES[s][0]}" '
        f'stroke-width="{STYLES[s][2]}" stroke-dasharray="{STYLES[s][1]}"/></svg>{esc(t)}</div>'
        for s, t in LEGEND
    )
    parts.append(f'<div class="legend" style="left:20px;top:790px"><b>Legend</b>{leg}</div>')
    steps = [
        "① Terraform builds VPC, EKS, Karpenter, S3/EFS/RDS, Argo CD",
        "② CI builds, scans and pushes images; bumps tags in Git",
        "③ Argo CD syncs every component from Git (Helm)",
        "④ Users reach the model API and JupyterHub via the ALB",
        "⑤ Argo Workflows runs Ray Tune on KubeRay (CPU/GPU)",
        "⑥ Gated model registered + promoted in S3",
        "⑦ Inference pods hot-reload the promoted model",
        "⑧ Metrics/logs → Prometheus, Loki, ELK; SLO + cost rules",
        "⑨ Grafana adds the AWS bill; Budgets + anomaly alerts",
    ]
    parts.append('<div class="steps" style="left:20px;top:1000px"><b>Flow</b>' + "".join(f"<div>{esc(s)}</div>" for s in steps) + "</div>")

    return f"""<!doctype html><html><head><meta charset="utf-8"><title>Pictorial architecture</title>
<style>
  body {{ margin:0; background:#ffffff; font-family: Inter, "Segoe UI", Helvetica, Arial, sans-serif; }}
  #c {{ position:relative; width:{W}px; height:{H}px; background:#ffffff; }}
  h1 {{ position:absolute; left:20px; top:10px; margin:0; font-size:27px; color:#0f172a; letter-spacing:-0.3px; }}
  .sub {{ position:absolute; left:22px; top:50px; font-size:13.5px; color:#475569; }}
  .grp {{ position:absolute; box-sizing:border-box; border:2px solid; border-radius:14px; }}
  .grp span {{ position:absolute; left:12px; top:6px; font-size:13.5px; font-weight:700; white-space:nowrap; }}
  svg.ov {{ position:absolute; left:0; top:0; z-index:2; }}
  .node {{ position:absolute; width:160px; text-align:center; z-index:3; }}
  .node img {{ display:block; margin:0 auto; background:#ffffff; border-radius:10px; padding:3px; box-shadow:0 1px 3px rgba(15,23,42,.18); }}
  .lbl {{ margin-top:4px; font-size:11.5px; line-height:1.25; color:#0f172a; text-shadow:0 0 3px #fff,0 0 3px #fff,0 0 3px #fff; }}
  .lbl::first-line {{ font-weight:700; }}
  .elbl {{ position:absolute; z-index:4; font-size:11px; font-weight:700; background:rgba(255,255,255,.88); padding:0 3px; border-radius:3px; white-space:nowrap; }}
  .chips {{ position:absolute; width:415px; z-index:3; font-size:12px; }}
  .chips b {{ display:block; margin-bottom:6px; font-size:13px; }}
  .chip {{ display:inline-block; margin:0 6px 6px 0; padding:4px 9px; border:1.5px solid; border-radius:999px; background:#fff; font-weight:600; }}
  .legend, .steps {{ position:absolute; width:232px; box-sizing:border-box; padding:10px 12px; border:2px solid #cbd5e1; border-radius:14px; background:#fff; font-size:11.5px; color:#0f172a; z-index:3; }}
  .legend b, .steps b {{ display:block; font-size:13px; margin-bottom:6px; }}
  .lg {{ display:flex; align-items:center; gap:6px; margin:3px 0; }}
  .steps div {{ margin:4px 0; line-height:1.3; }}
</style></head><body><div id="c">
<h1>{esc(TITLE)}</h1><div class="sub">{esc(SUBTITLE)}</div>
<svg class="ov" width="{W}" height="{H}" viewBox="0 0 {W} {H}"><defs>{''.join(svg[:len(STYLES)])}</defs>{''.join(svg[len(STYLES):])}</svg>
{''.join(parts)}
</div></body></html>"""


async def screenshot(html_path: Path, png_path: Path) -> None:
    from playwright.async_api import async_playwright

    async with async_playwright() as p:
        browser = await p.chromium.launch()
        page = await browser.new_page(viewport={"width": W, "height": H}, device_scale_factor=2)
        await page.goto(html_path.as_uri())
        await page.screenshot(path=str(png_path), clip={"x": 0, "y": 0, "width": W, "height": H})
        await browser.close()


if __name__ == "__main__":
    HTML_OUT.write_text(render_html(), encoding="utf-8")
    asyncio.run(screenshot(HTML_OUT, PNG_OUT))
    print(f"wrote {HTML_OUT.relative_to(HERE.parent.parent)} and {PNG_OUT.relative_to(HERE.parent.parent)}")

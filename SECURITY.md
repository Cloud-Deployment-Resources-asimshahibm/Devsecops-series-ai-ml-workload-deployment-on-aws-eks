# Security Policy

## Reporting a vulnerability

Please **do not open a public issue**. Use GitHub's private vulnerability reporting
(**Security → Report a vulnerability**) on this repository. You will get an
acknowledgement within 3 business days and a remediation plan within 10.

## Supported versions

Only `main` is supported. Production runs the digests recorded in
`charts/*/values-prod.yaml`.

## Remediation SLAs (internal)

| Severity | Fix in running images / infrastructure |
|---|---|
| Critical | 7 days (or mitigated within 24 h) |
| High | 30 days |
| Medium | 90 days |

How the platform enforces security at every stage is described in
[docs/DEVSECOPS.md](docs/DEVSECOPS.md).

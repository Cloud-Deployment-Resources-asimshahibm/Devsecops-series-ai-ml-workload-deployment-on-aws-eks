"""Pipeline step: model supply-chain security gate (runs between train and promote).

1. Download the candidate artifact and verify its SHA-256 against metadata.json
   (detects tampering between the train and promote steps).
2. Scan it with ModelScan (protectai) for unsafe deserialization operators
   (pickle/joblib can execute code on load: os.system, exec, eval, subprocess, ...).
3. Write <model>/<version>/security.json; promote.py refuses versions without
   a passing record, and inference re-verifies the digest before loading.

Exit codes: 0 pass, 4 digest mismatch, 5 unsafe operators found, 6 scanner error.
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import sys
import tempfile
from collections.abc import Callable
from datetime import UTC, datetime
from pathlib import Path
from typing import Any

from mlstore import ModelStore, sha256_file
from trainer.logutil import get_logger, log_event

log = get_logger("scan-model")

Scanner = Callable[[Path], dict[str, Any]]


def _modelscan_exe() -> str:
    return shutil.which("modelscan") or str(Path(sys.executable).with_name("modelscan"))


def modelscan_cli(path: Path) -> dict[str, Any]:
    """Run the ModelScan CLI and return {"issues": [...], "errors": [...], "scanned": int}."""
    with tempfile.TemporaryDirectory() as tmp:
        report = Path(tmp) / "report.json"
        proc = subprocess.run(  # noqa: S603 - fixed argv, no shell
            [_modelscan_exe(), "-p", str(path), "-r", "json", "-o", str(report)],
            capture_output=True,
            text=True,
            check=False,
        )
        data = json.loads(report.read_text()) if report.exists() else {}
    summary = data.get("summary", {})
    return {
        "issues": data.get("issues", []),
        "errors": data.get("errors", []),
        "scanned": summary.get("scanned", {}).get("total_scanned", 0),
        "exit_code": proc.returncode,  # 0 clean, 1 issues, 2 error, 3 nothing supported
    }


def run(store: ModelStore, model: str, version: str, scanner: Scanner = modelscan_cli) -> tuple[int, dict]:
    meta = store.get_json(model, version, "metadata.json")
    expected = meta.get("artifact_sha256")
    with tempfile.TemporaryDirectory() as tmp:
        path = store.get_file(Path(tmp) / "model.pkl", model, version, "model.pkl")
        actual = sha256_file(path)
        record: dict[str, Any] = {
            "version": version,
            "sha256": actual,
            "scanned_at": datetime.now(UTC).isoformat(),
            "scanner": "modelscan",
            "workflow": os.getenv("ARGO_WORKFLOW_NAME", ""),
        }
        if not expected or actual != expected:
            record.update(passed=False, reason="sha256 mismatch", expected=expected)
            code = 4
        else:
            result = scanner(path)
            record.update(issues=result.get("issues", []), errors=result.get("errors", []))
            if result.get("issues"):
                record.update(passed=False, reason="unsafe operators found")
                code = 5
            elif result.get("errors") or result.get("exit_code") not in (0, None):
                record.update(passed=False, reason=f"scanner error (exit {result.get('exit_code')})")
                code = 6
            else:
                record.update(passed=True)
                code = 0
    store.put_json(record, model, version, "security.json")
    return code, record


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--model-store", default=os.getenv("MODEL_STORE_URI", "./artifacts/models"))
    p.add_argument("--model-name", default=os.getenv("MODEL_NAME", "iris-classifier"))
    p.add_argument("--version", required=True)
    args = p.parse_args(argv)

    code, record = run(ModelStore(args.model_store), args.model_name, args.version)
    log_event(log, "model security scan " + ("passed" if code == 0 else "FAILED"), **record)
    return code


if __name__ == "__main__":
    sys.exit(main())

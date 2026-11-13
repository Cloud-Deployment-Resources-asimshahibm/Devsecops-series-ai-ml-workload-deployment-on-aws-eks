"""Pipeline step 4: move <model>/latest.json to a gated version, or roll back.

python -m trainer.promote --version 20261110093000-abc1234
python -m trainer.promote --rollback
"""

from __future__ import annotations

import argparse
import os
import sys

from mlstore import ModelStore
from trainer.logutil import get_logger, log_event

log = get_logger("promote")


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--model-store", default=os.getenv("MODEL_STORE_URI", "./artifacts/models"))
    p.add_argument("--model-name", default=os.getenv("MODEL_NAME", "iris-classifier"))
    group = p.add_mutually_exclusive_group(required=True)
    group.add_argument("--version")
    group.add_argument("--rollback", action="store_true")
    p.add_argument("--force", action="store_true", help="promote even if the quality gate failed")
    p.add_argument(
        "--require-scan",
        action=argparse.BooleanOptionalAction,
        default=os.getenv("REQUIRE_MODEL_SCAN", "true").lower() == "true",
        help="require a passing security.json (ModelScan) whose sha256 matches the artifact (default: on)",
    )
    args = p.parse_args(argv)

    store = ModelStore(args.model_store)

    if args.rollback:
        current = store.get_json(args.model_name, "latest.json")
        previous = current.get("previous")
        if not previous:
            log_event(log, "nothing to roll back to", current=current)
            return 1
        pointer = store.promote(args.model_name, previous)
        log_event(log, "rolled back", **pointer)
        return 0

    meta = store.get_json(args.model_name, args.version, "metadata.json")
    if not meta.get("gate_passed") and not args.force:
        log_event(log, "refusing to promote: quality gate failed", version=args.version, metrics=meta.get("metrics"))
        return 2
    if args.require_scan:
        if not store.exists(args.model_name, args.version, "security.json"):
            log_event(log, "refusing to promote: model has not been security-scanned", version=args.version)
            return 3
        sec = store.get_json(args.model_name, args.version, "security.json")
        if not sec.get("passed") or sec.get("sha256") != meta.get("artifact_sha256"):
            log_event(log, "refusing to promote: security scan failed or digest mismatch", version=args.version, scan=sec)
            return 3
    pointer = store.promote(args.model_name, args.version)
    log_event(log, "model promoted", **pointer, metrics=meta.get("metrics"))
    return 0


if __name__ == "__main__":
    sys.exit(main())

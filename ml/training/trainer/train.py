"""Pipeline step 3: train, evaluate against a quality gate, register a
candidate version in the model store. Promotion is a separate step."""

from __future__ import annotations

import argparse
import json
import os
import sys
import tempfile
import uuid
from datetime import UTC, datetime
from pathlib import Path
from typing import Any

import joblib
import sklearn
from sklearn.ensemble import RandomForestClassifier
from sklearn.metrics import accuracy_score, f1_score
from sklearn.model_selection import train_test_split
from sklearn.pipeline import Pipeline
from sklearn.preprocessing import StandardScaler

from mlstore import ModelStore, read_json_uri
from trainer.data import Dataset, load_dataset
from trainer.logutil import get_logger, log_event

log = get_logger("train")


def build_pipeline(params: dict[str, Any], seed: int) -> Pipeline:
    return Pipeline(
        [
            ("scaler", StandardScaler()),
            (
                "clf",
                RandomForestClassifier(
                    n_estimators=int(params.get("n_estimators", 200)),
                    max_depth=None if params.get("max_depth") in (None, 0) else int(params["max_depth"]),
                    random_state=seed,
                    n_jobs=-1,
                ),
            ),
        ]
    )


def train_and_evaluate(ds: Dataset, params: dict[str, Any], seed: int = 42) -> tuple[Pipeline, dict[str, float]]:
    X_tr, X_te, y_tr, y_te = train_test_split(ds.X, ds.y, test_size=0.25, random_state=seed, stratify=ds.y)
    pipe = build_pipeline(params, seed)
    pipe.fit(X_tr, y_tr)
    pred = pipe.predict(X_te)
    metrics = {
        "accuracy": float(accuracy_score(y_te, pred)),
        "f1_macro": float(f1_score(y_te, pred, average="macro")),
        "train_rows": len(y_tr),
        "test_rows": len(y_te),
    }
    return pipe, metrics


def make_version() -> str:
    sha = (os.getenv("GIT_SHA") or "local")[:7]
    return f"{datetime.now(UTC):%Y%m%d%H%M%S}-{sha}-{uuid.uuid4().hex[:4]}"


def parse_args(argv: list[str] | None) -> argparse.Namespace:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--model-store", default=os.getenv("MODEL_STORE_URI", "./artifacts/models"))
    p.add_argument("--model-name", default=os.getenv("MODEL_NAME", "iris-classifier"))
    p.add_argument("--dataset-uri", default=os.getenv("DATASET_URI") or None)
    p.add_argument("--n-estimators", type=int, default=200)
    p.add_argument("--max-depth", type=int, default=0, help="0 = unlimited")
    p.add_argument("--params-uri", default=None, help="JSON with tuned params (output of the Ray Tune step)")
    p.add_argument("--min-accuracy", type=float, default=float(os.getenv("MIN_ACCURACY", "0.85")))
    p.add_argument("--seed", type=int, default=42)
    p.add_argument("--promote", action="store_true", help="also move latest.json (skip the separate promote step)")
    p.add_argument("--version-file", default=None, help="write the new version here (Argo output parameter)")
    p.add_argument("--metrics-file", default=None)
    return p.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    params: dict[str, Any] = {"n_estimators": args.n_estimators, "max_depth": args.max_depth}
    if args.params_uri:
        try:
            tuned = read_json_uri(args.params_uri)
            params.update(tuned.get("best_params", tuned))
            log_event(log, "using tuned hyper-parameters", params=params, source=args.params_uri)
        except Exception as exc:  # tuning is optional; fall back to defaults
            log_event(log, "tuned params unavailable, using defaults", error=str(exc))

    ds = load_dataset(args.dataset_uri)
    model, metrics = train_and_evaluate(ds, params, args.seed)
    gate_passed = metrics["accuracy"] >= args.min_accuracy
    version = make_version()

    metadata = {
        "model_name": args.model_name,
        "version": version,
        "created_at": datetime.now(UTC).isoformat(),
        "git_sha": os.getenv("GIT_SHA", "local"),
        "workflow": os.getenv("ARGO_WORKFLOW_NAME", ""),
        "sklearn_version": sklearn.__version__,
        "params": params,
        "metrics": metrics,
        "min_accuracy": args.min_accuracy,
        "gate_passed": gate_passed,
        "feature_names": ds.feature_names,
        "class_names": ds.class_names,
    }

    store = ModelStore(args.model_store)
    with tempfile.TemporaryDirectory() as tmp:
        model_path = Path(tmp) / "model.joblib"
        joblib.dump(model, model_path)
        uri = store.put_file(model_path, args.model_name, version, "model.joblib")
    store.put_json(metadata, args.model_name, version, "metadata.json")

    if args.version_file:
        Path(args.version_file).write_text(version)
    if args.metrics_file:
        Path(args.metrics_file).write_text(json.dumps(metrics))

    log_event(log, "model registered", version=version, uri=uri, gate_passed=gate_passed, **metrics)

    if not gate_passed:
        log_event(log, "quality gate FAILED", accuracy=metrics["accuracy"], min_accuracy=args.min_accuracy)
        return 2
    if args.promote:
        pointer = store.promote(args.model_name, version)
        log_event(log, "model promoted", **pointer)
    return 0


if __name__ == "__main__":
    sys.exit(main())

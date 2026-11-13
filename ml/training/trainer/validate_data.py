"""Pipeline step 1: data quality gate. Fails the workflow before any compute
is spent on training if the dataset is malformed."""

from __future__ import annotations

import argparse
import json
import os
import sys

import numpy as np

from trainer.data import load_dataset
from trainer.logutil import get_logger, log_event

log = get_logger("validate-data")


def validate(dataset, min_rows: int, min_class_fraction: float) -> list[str]:
    errors: list[str] = []
    n = len(dataset.y)
    if n < min_rows:
        errors.append(f"only {n} rows (< {min_rows})")
    if dataset.X.shape[1] != len(dataset.feature_names):
        errors.append("feature count does not match schema")
    if np.isnan(dataset.X).any():
        errors.append("dataset contains NaN values")
    counts = np.bincount(dataset.y, minlength=len(dataset.class_names))
    fractions = counts / max(n, 1)
    if fractions.min() < min_class_fraction:
        errors.append(f"class imbalance: min class fraction {fractions.min():.2f} < {min_class_fraction}")
    return errors


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--dataset-uri", default=os.getenv("DATASET_URI") or None)
    p.add_argument("--min-rows", type=int, default=100)
    p.add_argument("--min-class-fraction", type=float, default=0.2)
    p.add_argument("--report-file", default=None)
    args = p.parse_args(argv)

    ds = load_dataset(args.dataset_uri)
    errors = validate(ds, args.min_rows, args.min_class_fraction)
    report = {"rows": len(ds.y), "features": ds.feature_names, "classes": ds.class_names, "errors": errors}
    if args.report_file:
        with open(args.report_file, "w") as fh:
            json.dump(report, fh)

    if errors:
        log_event(log, "data validation failed", **report)
        return 1
    log_event(log, "data validation passed", **report)
    return 0


if __name__ == "__main__":
    sys.exit(main())

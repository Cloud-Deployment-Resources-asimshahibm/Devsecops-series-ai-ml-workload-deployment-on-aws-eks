"""Pipeline step 2 (optional): distributed hyper-parameter search with Ray Tune.

Submitted as a RayJob onto the shared KubeRay cluster; trials fan out across
the CPU worker group (Karpenter adds nodes as needed). The best parameters are
written to --output-uri where the train step picks them up via --params-uri.
"""

from __future__ import annotations

import argparse
import os
import sys

from mlstore import write_json_uri
from trainer.logutil import get_logger, log_event

log = get_logger("ray-tune")


def objective(config: dict) -> dict:
    # Imported inside the trial so it runs on the Ray worker
    from sklearn.model_selection import cross_val_score

    from trainer.data import load_dataset
    from trainer.train import build_pipeline

    ds = load_dataset(config.get("dataset_uri"))
    pipe = build_pipeline(config, seed=42)
    scores = cross_val_score(pipe, ds.X, ds.y, cv=5, scoring="accuracy")
    return {"accuracy": float(scores.mean())}


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--output-uri", required=True)
    p.add_argument("--dataset-uri", default=os.getenv("DATASET_URI") or None)
    p.add_argument("--num-samples", type=int, default=1, help="repeats of the grid")
    args = p.parse_args(argv)

    import ray
    from ray import tune

    ray.init(address=os.getenv("RAY_ADDRESS", "auto"), ignore_reinit_error=True)
    log_event(log, "connected to ray", resources=ray.cluster_resources())

    param_space = {
        "n_estimators": tune.grid_search([50, 100, 200, 400]),
        "max_depth": tune.grid_search([0, 3, 5, 8]),
        "dataset_uri": args.dataset_uri,
    }
    tuner = tune.Tuner(
        tune.with_resources(objective, {"cpu": 1}),
        param_space=param_space,
        tune_config=tune.TuneConfig(metric="accuracy", mode="max", num_samples=args.num_samples),
    )
    results = tuner.fit()
    best = results.get_best_result()
    best_params = {k: v for k, v in best.config.items() if k != "dataset_uri"}

    write_json_uri(args.output_uri, {"best_params": best_params, "accuracy": best.metrics["accuracy"]})
    log_event(log, "tuning complete", best_params=best_params, accuracy=best.metrics["accuracy"], trials=len(results))
    return 0


if __name__ == "__main__":
    sys.exit(main())

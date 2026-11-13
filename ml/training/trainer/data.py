"""Dataset loading. Uses the bundled Iris dataset by default; point
--dataset-uri at a CSV (local or s3://) with the same columns to train on
your own data."""

from __future__ import annotations

import io
from dataclasses import dataclass

import numpy as np
import pandas as pd
from sklearn.datasets import load_iris

FEATURES = ["sepal_length", "sepal_width", "petal_length", "petal_width"]
TARGET = "species"


@dataclass
class Dataset:
    X: np.ndarray
    y: np.ndarray
    feature_names: list[str]
    class_names: list[str]


def load_dataset(uri: str | None = None) -> Dataset:
    if not uri:
        iris = load_iris()
        return Dataset(iris.data, iris.target, FEATURES, [str(n) for n in iris.target_names])

    if uri.startswith("s3://"):
        from urllib.parse import urlparse

        import boto3

        p = urlparse(uri)
        body = boto3.client("s3").get_object(Bucket=p.netloc, Key=p.path.lstrip("/"))["Body"].read()
        df = pd.read_csv(io.BytesIO(body))
    else:
        df = pd.read_csv(uri)

    classes = sorted(df[TARGET].astype(str).unique())
    y = df[TARGET].astype(str).map({c: i for i, c in enumerate(classes)}).to_numpy()
    return Dataset(df[FEATURES].to_numpy(dtype=float), y, FEATURES, classes)

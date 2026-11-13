"""Online inference API (FastAPI).

Endpoints
  POST /v1/predict    {"instances": [[5.1, 3.5, 1.4, 0.2], ...]}
  GET  /v1/models     currently served model + metadata
  GET  /healthz       liveness
  GET  /readyz        readiness (503 until a model is loaded)
  GET  /metrics       Prometheus metrics
"""

from __future__ import annotations

import asyncio
import json
import logging
import os
import sys
import time
import uuid
from contextlib import asynccontextmanager
from datetime import UTC, datetime

import numpy as np
from fastapi import FastAPI, HTTPException, Request
from prometheus_client import Counter, Gauge, Histogram, make_asgi_app
from pydantic import BaseModel, Field, field_validator

from app.model import ModelManager

# ----------------------------------------------------------------- settings
MODEL_NAME = os.getenv("MODEL_NAME", "iris-classifier")
MAX_BATCH = int(os.getenv("MAX_BATCH_SIZE", "256"))


def settings() -> dict:
    """Read at startup (lifespan) so the module can be imported once and configured per process."""
    return {
        "store": os.getenv("MODEL_STORE_URI", "./artifacts/models"),
        "version": os.getenv("MODEL_VERSION", "latest"),
        "refresh": int(os.getenv("MODEL_REFRESH_SECONDS", "60")),
    }


# ----------------------------------------------------------------- logging
class JsonFormatter(logging.Formatter):
    def format(self, record: logging.LogRecord) -> str:
        payload = {
            "ts": datetime.now(UTC).isoformat(),
            "level": record.levelname.lower(),
            "logger": record.name,
            "msg": record.getMessage(),
            "service": "ml-inference",
        }
        payload.update(getattr(record, "extra_fields", {}) or {})
        if record.exc_info:
            payload["exc"] = self.formatException(record.exc_info)
        return json.dumps(payload, default=str)


_handler = logging.StreamHandler(sys.stdout)
_handler.setFormatter(JsonFormatter())
log = logging.getLogger("ml-inference")
log.handlers = [_handler]
log.setLevel(os.getenv("LOG_LEVEL", "INFO"))
log.propagate = False


def event(msg: str, level: int = logging.INFO, **fields) -> None:
    log.log(level, msg, extra={"extra_fields": fields})


# ----------------------------------------------------------------- metrics
HTTP_REQUESTS = Counter("mlserve_http_requests_total", "HTTP requests", ["method", "route", "status"])
HTTP_LATENCY = Histogram(
    "mlserve_http_request_duration_seconds",
    "HTTP request latency",
    ["route"],
    buckets=(0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5),
)
PREDICTIONS = Counter("mlserve_predictions_total", "Predictions served", ["model", "version", "label"])
INFERENCE_LATENCY = Histogram("mlserve_inference_duration_seconds", "Model predict() latency", ["model"])
BATCH_SIZE = Histogram("mlserve_batch_size", "Instances per request", buckets=(1, 2, 4, 8, 16, 32, 64, 128, 256))
CONFIDENCE = Histogram(
    "mlserve_prediction_confidence", "Top-class probability", ["model"], buckets=(0.5, 0.6, 0.7, 0.8, 0.9, 0.95, 0.99, 1.0)
)
MODEL_INFO = Gauge("mlserve_model_info", "Currently served model (value=1)", ["model", "version"])
MODEL_LOADED = Gauge("mlserve_model_loaded", "1 if a model is loaded")
MODEL_RELOADS = Counter("mlserve_model_reloads_total", "Successful model (re)loads", ["model"])
MODEL_LOAD_FAILURES = Counter("mlserve_model_load_failures_total", "Failed model load attempts", ["model"])

manager: ModelManager = ModelManager("./artifacts/models", MODEL_NAME)  # replaced in lifespan


def _try_refresh() -> None:
    previous = manager.current.version if manager.current else None
    try:
        if manager.refresh():
            current = manager.current
            if previous:
                MODEL_INFO.remove(MODEL_NAME, previous)
            MODEL_INFO.labels(MODEL_NAME, current.version).set(1)
            MODEL_LOADED.set(1)
            MODEL_RELOADS.labels(MODEL_NAME).inc()
            event(
                "model loaded",
                model=MODEL_NAME,
                version=current.version,
                previous=previous,
                metrics=current.metadata.get("metrics"),
            )
    except Exception as exc:
        MODEL_LOAD_FAILURES.labels(MODEL_NAME).inc()
        event("model load failed", logging.WARNING, model=MODEL_NAME, error=str(exc), store=manager.store.uri)


async def _refresher(refresh_seconds: int) -> None:
    while True:
        # retry fast until the first model lands, then poll at the normal cadence
        await asyncio.sleep(refresh_seconds if manager.current else 10)
        await asyncio.to_thread(_try_refresh)


@asynccontextmanager
async def lifespan(_: FastAPI):
    global manager
    cfg = settings()
    manager = ModelManager(cfg["store"], MODEL_NAME, cfg["version"])
    MODEL_LOADED.set(0)
    event("starting", model=MODEL_NAME, store=cfg["store"], pinned_version=cfg["version"])
    await asyncio.to_thread(_try_refresh)
    task = asyncio.create_task(_refresher(cfg["refresh"]))
    yield
    task.cancel()


app = FastAPI(title="ml-inference", version="1.0.0", lifespan=lifespan)
app.mount("/metrics", make_asgi_app())


@app.middleware("http")
async def observe(request: Request, call_next):
    request_id = request.headers.get("x-request-id") or uuid.uuid4().hex
    route = request.url.path
    start = time.perf_counter()
    status = 500
    try:
        response = await call_next(request)
        status = response.status_code
        response.headers["x-request-id"] = request_id
        return response
    finally:
        elapsed = time.perf_counter() - start
        if not route.startswith("/metrics"):
            HTTP_REQUESTS.labels(request.method, route, str(status)).inc()
            HTTP_LATENCY.labels(route).observe(elapsed)
            if route not in ("/healthz", "/readyz"):
                event(
                    "request",
                    method=request.method,
                    path=route,
                    status=status,
                    latency_ms=round(elapsed * 1000, 2),
                    request_id=request_id,
                )


# ----------------------------------------------------------------- schemas
class PredictRequest(BaseModel):
    instances: list[list[float]] = Field(..., min_length=1, examples=[[[5.1, 3.5, 1.4, 0.2]]])

    @field_validator("instances")
    @classmethod
    def check_batch(cls, v: list[list[float]]) -> list[list[float]]:
        if len(v) > MAX_BATCH:
            raise ValueError(f"batch too large (max {MAX_BATCH})")
        widths = {len(row) for row in v}
        if len(widths) != 1:
            raise ValueError("all instances must have the same number of features")
        return v


class Prediction(BaseModel):
    label: str
    class_id: int
    confidence: float
    probabilities: dict[str, float]


class PredictResponse(BaseModel):
    model: str
    model_version: str
    predictions: list[Prediction]


# ----------------------------------------------------------------- routes
@app.get("/healthz")
def healthz() -> dict:
    return {"status": "ok"}


@app.get("/readyz")
def readyz() -> dict:
    if manager.current is None:
        raise HTTPException(status_code=503, detail="model not loaded")
    return {"status": "ready", "model_version": manager.current.version}


@app.get("/v1/models")
def models() -> dict:
    current = manager.current
    if current is None:
        raise HTTPException(status_code=503, detail="model not loaded")
    return {"name": current.name, "version": current.version, "metadata": current.metadata}


@app.post("/v1/predict", response_model=PredictResponse)
def predict(req: PredictRequest) -> PredictResponse:
    current = manager.current
    if current is None:
        raise HTTPException(status_code=503, detail="model not loaded")

    expected = len(current.metadata.get("feature_names", [])) or None
    X = np.asarray(req.instances, dtype=float)
    if expected and X.shape[1] != expected:
        raise HTTPException(status_code=422, detail=f"expected {expected} features, got {X.shape[1]}")

    BATCH_SIZE.observe(len(X))
    with INFERENCE_LATENCY.labels(current.name).time():
        proba = current.pipeline.predict_proba(X)

    names = current.class_names
    out: list[Prediction] = []
    for row in proba:
        idx = int(np.argmax(row))
        label = names[idx] if idx < len(names) else str(idx)
        PREDICTIONS.labels(current.name, current.version, label).inc()
        CONFIDENCE.labels(current.name).observe(float(row[idx]))
        out.append(
            Prediction(
                label=label,
                class_id=idx,
                confidence=round(float(row[idx]), 4),
                probabilities={names[i] if i < len(names) else str(i): round(float(p), 4) for i, p in enumerate(row)},
            )
        )
    return PredictResponse(model=current.name, model_version=current.version, predictions=out)

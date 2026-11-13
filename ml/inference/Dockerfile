# syntax=docker/dockerfile:1.7
# Build context: ./ml   (docker build -f ml/inference/Dockerfile ml)

# ---------- build stage: compile wheels once ----------
FROM python:3.12-slim AS builder
ENV PIP_NO_CACHE_DIR=1
COPY inference/requirements.txt /tmp/requirements.txt
RUN pip install --upgrade pip && pip wheel --wheel-dir /wheels -r /tmp/requirements.txt

# ---------- runtime stage ----------
FROM python:3.12-slim
ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PYTHONPATH=/app

WORKDIR /app
COPY --from=builder /wheels /wheels
RUN pip install --no-cache-dir --no-index --find-links=/wheels /wheels/* && rm -rf /wheels

COPY common/mlstore.py /app/mlstore.py
COPY inference/app /app/app

RUN useradd --uid 1000 --no-create-home --shell /usr/sbin/nologin app
USER 1000

ARG GIT_SHA=local
ENV GIT_SHA=${GIT_SHA}
LABEL org.opencontainers.image.source="https://github.com/Cloud-Deployment-Resources-asimshahibm/DevOps-Series-AI-ML-Workload-deployment-on-AWS-EKS" \
      org.opencontainers.image.revision="${GIT_SHA}"

EXPOSE 8080
CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8080", "--workers", "2", "--no-access-log"]

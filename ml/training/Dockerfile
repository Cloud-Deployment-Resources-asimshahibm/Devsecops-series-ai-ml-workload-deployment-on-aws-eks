# syntax=docker/dockerfile:1.7
# Build context: ./ml   (docker build -f ml/training/Dockerfile ml)
FROM python:3.12-slim-bookworm AS base

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    PYTHONPATH=/app

WORKDIR /app

COPY training/requirements.txt /tmp/requirements.txt
RUN pip install "pip==24.3.1" && pip install -r /tmp/requirements.txt

COPY common/mlstore.py /app/mlstore.py
COPY training/trainer /app/trainer

RUN useradd --uid 1000 --create-home --shell /usr/sbin/nologin trainer
USER 1000

ARG GIT_SHA=local
ENV GIT_SHA=${GIT_SHA}
LABEL org.opencontainers.image.source="https://github.com/Cloud-Deployment-Resources-asimshahibm/DevSecOps-Series-AI-ML-Workload-deployment-on-AWS-EKS" \
      org.opencontainers.image.revision="${GIT_SHA}"

ENTRYPOINT ["python", "-m"]
CMD ["trainer.train", "--help"]

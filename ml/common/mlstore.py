"""Minimal model registry on S3 (or a local directory for dev/tests).

Layout under the store root (e.g. s3://aiml-dev-ml-data-<acct>/models):

    <model>/<version>/model.pkl      serialized sklearn pipeline
    <model>/<version>/metadata.json     metrics, params, gate result, git sha, artifact_sha256
    <model>/<version>/security.json     ModelScan result (written by the scan step, required to promote)
    <model>/latest.json                 {"version": ..., "previous": ...}  <- written ONLY by promotion

Inference servers follow latest.json, so promotion / rollback is a single,
atomic pointer write and never requires a redeploy.
"""

from __future__ import annotations

import hashlib
import json
import shutil
from pathlib import Path
from typing import Any
from urllib.parse import urlparse


def sha256_file(path: Path | str, chunk: int = 1 << 20) -> str:
    """SHA-256 of a file, used to pin model artifacts (supply-chain integrity)."""
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for block in iter(lambda: fh.read(chunk), b""):
            h.update(block)
    return h.hexdigest()


class IntegrityError(RuntimeError):
    """Model artifact does not match its recorded digest or has not passed the security scan."""


def _split_s3(uri: str) -> tuple[str, str]:
    parsed = urlparse(uri)
    return parsed.netloc, parsed.path.lstrip("/")


def read_json_uri(uri: str) -> dict[str, Any]:
    """Read a JSON document from s3://bucket/key or a local path."""
    if uri.startswith("s3://"):
        import boto3

        bucket, key = _split_s3(uri)
        body = boto3.client("s3").get_object(Bucket=bucket, Key=key)["Body"].read()
        return json.loads(body)
    return json.loads(Path(uri).read_text())


def write_json_uri(uri: str, obj: dict[str, Any]) -> None:
    data = json.dumps(obj, indent=2, sort_keys=True).encode()
    if uri.startswith("s3://"):
        import boto3

        bucket, key = _split_s3(uri)
        boto3.client("s3").put_object(Bucket=bucket, Key=key, Body=data, ContentType="application/json")
        return
    path = Path(uri)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(data)


class ModelStore:
    def __init__(self, uri: str) -> None:
        self.uri = uri.rstrip("/")
        self.is_s3 = self.uri.startswith("s3://")
        if self.is_s3:
            import boto3

            self.bucket, self.prefix = _split_s3(self.uri)
            self._s3 = boto3.client("s3")
        else:
            self.root = Path(self.uri)

    # ------------------------------------------------------------------ paths
    def _key(self, *parts: str) -> str:
        return "/".join(p.strip("/") for p in (self.prefix, *parts) if p)

    def _path(self, *parts: str) -> Path:
        return self.root.joinpath(*parts)

    # ------------------------------------------------------------------ files
    def put_file(self, local: Path, *parts: str) -> str:
        if self.is_s3:
            key = self._key(*parts)
            self._s3.upload_file(str(local), self.bucket, key)
            return f"s3://{self.bucket}/{key}"
        dest = self._path(*parts)
        dest.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(local, dest)
        return str(dest)

    def get_file(self, local: Path, *parts: str) -> Path:
        local.parent.mkdir(parents=True, exist_ok=True)
        if self.is_s3:
            self._s3.download_file(self.bucket, self._key(*parts), str(local))
        else:
            shutil.copyfile(self._path(*parts), local)
        return local

    def put_json(self, obj: dict[str, Any], *parts: str) -> None:
        if self.is_s3:
            write_json_uri(f"s3://{self.bucket}/{self._key(*parts)}", obj)
        else:
            write_json_uri(str(self._path(*parts)), obj)

    def get_json(self, *parts: str) -> dict[str, Any]:
        if self.is_s3:
            return read_json_uri(f"s3://{self.bucket}/{self._key(*parts)}")
        return read_json_uri(str(self._path(*parts)))

    def exists(self, *parts: str) -> bool:
        if self.is_s3:
            from botocore.exceptions import ClientError

            try:
                self._s3.head_object(Bucket=self.bucket, Key=self._key(*parts))
                return True
            except ClientError:
                return False
        return self._path(*parts).exists()

    # ------------------------------------------------------------------ registry
    def latest_version(self, model: str) -> str:
        return self.get_json(model, "latest.json")["version"]

    def resolve(self, model: str, version: str = "latest") -> str:
        return self.latest_version(model) if version == "latest" else version

    def promote(self, model: str, version: str) -> dict[str, Any]:
        previous = self.latest_version(model) if self.exists(model, "latest.json") else None
        pointer = {"version": version, "previous": previous}
        self.put_json(pointer, model, "latest.json")
        return pointer

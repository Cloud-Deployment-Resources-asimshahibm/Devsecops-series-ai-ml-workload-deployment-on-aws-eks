"""Thread-safe holder for the currently served model with hot reload.

The server follows <model>/latest.json in the model store. When the training
pipeline promotes a new version, every replica picks it up on its next refresh
— no redeploy, no restart. Pin a version with MODEL_VERSION to opt out.
"""

from __future__ import annotations

import tempfile
import threading
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

import joblib

from mlstore import IntegrityError, ModelStore, sha256_file


@dataclass
class LoadedModel:
    name: str
    version: str
    pipeline: Any
    metadata: dict[str, Any] = field(default_factory=dict)

    @property
    def class_names(self) -> list[str]:
        return self.metadata.get("class_names") or [str(c) for c in getattr(self.pipeline, "classes_", [])]


class ModelManager:
    def __init__(self, store_uri: str, model_name: str, pinned_version: str = "latest", require_scan: bool = True) -> None:
        self.store = ModelStore(store_uri)
        self.require_scan = require_scan
        self.model_name = model_name
        self.pinned_version = pinned_version
        self._current: LoadedModel | None = None
        self._lock = threading.Lock()

    @property
    def current(self) -> LoadedModel | None:
        return self._current

    def target_version(self) -> str:
        return self.store.resolve(self.model_name, self.pinned_version)

    def verify(self, version: str, path: Path, metadata: dict[str, Any]) -> None:
        """Refuse artifacts that were modified after training or never passed the security scan.

        joblib/pickle executes code on load, so these checks run BEFORE joblib.load().
        """
        digest = sha256_file(path)
        if digest != metadata.get("artifact_sha256"):
            raise IntegrityError(f"{self.model_name}:{version} sha256 {digest} != recorded {metadata.get('artifact_sha256')}")
        if self.require_scan:
            if not self.store.exists(self.model_name, version, "security.json"):
                raise IntegrityError(f"{self.model_name}:{version} has no security scan record")
            sec = self.store.get_json(self.model_name, version, "security.json")
            if not sec.get("passed") or sec.get("sha256") != digest:
                raise IntegrityError(f"{self.model_name}:{version} security scan not passed for this digest")

    def load(self, version: str) -> LoadedModel:
        metadata = self.store.get_json(self.model_name, version, "metadata.json")
        with tempfile.TemporaryDirectory() as tmp:
            path = self.store.get_file(Path(tmp) / "model.pkl", self.model_name, version, "model.pkl")
            self.verify(version, path, metadata)
            pipeline = joblib.load(path)
        loaded = LoadedModel(self.model_name, version, pipeline, metadata)
        with self._lock:
            self._current = loaded
        return loaded

    def refresh(self) -> bool:
        """Load the target version if it differs from what is served. Returns True if swapped."""
        version = self.target_version()
        if self._current is not None and self._current.version == version:
            return False
        self.load(version)
        return True

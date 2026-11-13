"""DevSecOps tests: model supply-chain integrity, scan gate, API auth, secure headers."""

import pickle

import pytest
from fastapi.testclient import TestClient

from mlstore import ModelStore, sha256_file
from trainer import promote, scan_model, train

MODEL = "iris-classifier"
CLEAN = lambda path: {"issues": [], "errors": [], "exit_code": 0}  # noqa: E731
UNSAFE = lambda path: {"issues": [{"operator": "system", "module": "posix"}], "errors": [], "exit_code": 1}  # noqa: E731


def _train(store_uri: str, tmp_path) -> str:
    vf = tmp_path / "v"
    assert train.main(["--model-store", store_uri, "--n-estimators", "20", "--version-file", str(vf)]) == 0
    return vf.read_text()


def test_digest_recorded(tmp_path):
    store_uri = str(tmp_path / "m")
    version = _train(store_uri, tmp_path)
    store = ModelStore(store_uri)
    meta = store.get_json(MODEL, version, "metadata.json")
    assert meta["artifact_sha256"] == sha256_file(tmp_path / "m" / MODEL / version / "model.pkl")


def test_scan_pass_then_promote(tmp_path):
    store_uri = str(tmp_path / "m")
    version = _train(store_uri, tmp_path)
    assert promote.main(["--model-store", store_uri, "--version", version]) == 3  # not scanned yet
    code, record = scan_model.run(ModelStore(store_uri), MODEL, version, CLEAN)
    assert code == 0 and record["passed"] is True
    assert promote.main(["--model-store", store_uri, "--version", version]) == 0


def test_scan_blocks_unsafe_model(tmp_path):
    store_uri = str(tmp_path / "m")
    version = _train(store_uri, tmp_path)
    code, record = scan_model.run(ModelStore(store_uri), MODEL, version, UNSAFE)
    assert code == 5 and record["passed"] is False
    assert promote.main(["--model-store", store_uri, "--version", version]) == 3


def test_scan_detects_tampering(tmp_path):
    store_uri = str(tmp_path / "m")
    version = _train(store_uri, tmp_path)
    artifact = tmp_path / "m" / MODEL / version / "model.pkl"
    artifact.write_bytes(artifact.read_bytes() + b"tampered")
    code, record = scan_model.run(ModelStore(store_uri), MODEL, version, CLEAN)
    assert code == 4 and record["reason"] == "sha256 mismatch"


def test_real_modelscan_flags_malicious_pickle(tmp_path):
    pytest.importorskip("modelscan")

    class Evil:
        def __reduce__(self):
            import os

            return (os.system, ("echo pwned",))

    bad = tmp_path / "model.pkl"
    bad.write_bytes(pickle.dumps(Evil()))
    result = scan_model.modelscan_cli(bad)
    assert result["issues"], result


def test_real_modelscan_passes_trained_sklearn_model(tmp_path):
    pytest.importorskip("modelscan")
    store_uri = str(tmp_path / "m")
    version = _train(store_uri, tmp_path)
    code, record = scan_model.run(ModelStore(store_uri), MODEL, version)  # real scanner, no false positive
    assert code == 0, record


def _client(store_uri: str, monkeypatch, **env) -> TestClient:
    monkeypatch.setenv("MODEL_STORE_URI", store_uri)
    for k, v in env.items():
        monkeypatch.setenv(k, v)
    from app.main import app

    return TestClient(app)


def test_inference_refuses_tampered_model(tmp_path, monkeypatch):
    store_uri = str(tmp_path / "m")
    version = _train(store_uri, tmp_path)
    scan_model.run(ModelStore(store_uri), MODEL, version, CLEAN)
    assert promote.main(["--model-store", store_uri, "--version", version]) == 0
    artifact = tmp_path / "m" / MODEL / version / "model.pkl"
    artifact.write_bytes(artifact.read_bytes() + b"x")
    with _client(store_uri, monkeypatch) as c:
        assert c.get("/readyz").status_code == 503
        assert "mlserve_model_integrity_failures_total" in c.get("/metrics/").text


def test_inference_refuses_unscanned_model(tmp_path, monkeypatch):
    store_uri = str(tmp_path / "m")
    _train(store_uri, tmp_path)
    store = ModelStore(store_uri)
    version = (tmp_path / "v").read_text()
    store.promote(MODEL, version)  # bypass the pipeline gate on purpose
    with _client(store_uri, monkeypatch) as c:
        assert c.get("/readyz").status_code == 503
    with _client(store_uri, monkeypatch, REQUIRE_MODEL_SCAN="false") as c:
        assert c.get("/readyz").status_code == 200


def test_api_key_auth_and_headers(tmp_path, monkeypatch):
    store_uri = str(tmp_path / "m")
    version = _train(store_uri, tmp_path)
    scan_model.run(ModelStore(store_uri), MODEL, version, CLEAN)
    promote.main(["--model-store", store_uri, "--version", version])
    body = {"instances": [[5.1, 3.5, 1.4, 0.2]]}
    with _client(store_uri, monkeypatch, API_KEYS="k1,k2") as c:
        assert c.post("/v1/predict", json=body).status_code == 401
        assert c.post("/v1/predict", json=body, headers={"x-api-key": "wrong"}).status_code == 401
        r = c.post("/v1/predict", json=body, headers={"x-api-key": "k2"})
        assert r.status_code == 200
        assert r.headers["x-content-type-options"] == "nosniff"
        assert r.headers["x-frame-options"] == "DENY"
        assert c.get("/healthz").status_code == 200  # probes stay unauthenticated

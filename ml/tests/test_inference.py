import pytest
from fastapi.testclient import TestClient

from trainer import train


@pytest.fixture()
def client(tmp_path, monkeypatch):
    store = str(tmp_path / "models")
    assert train.main(["--model-store", store, "--promote", "--n-estimators", "50"]) == 0
    monkeypatch.setenv("MODEL_STORE_URI", store)
    from app.main import app

    with TestClient(app) as c:
        yield c


def test_health_and_ready(client):
    assert client.get("/healthz").status_code == 200
    r = client.get("/readyz")
    assert r.status_code == 200
    assert r.json()["status"] == "ready"


def test_predict_setosa(client):
    r = client.post("/v1/predict", json={"instances": [[5.1, 3.5, 1.4, 0.2], [6.7, 3.0, 5.2, 2.3]]})
    assert r.status_code == 200
    body = r.json()
    assert body["model"] == "iris-classifier"
    assert body["predictions"][0]["label"] == "setosa"
    assert body["predictions"][1]["label"] == "virginica"
    assert abs(sum(body["predictions"][0]["probabilities"].values()) - 1) < 1e-3


def test_rejects_wrong_feature_count(client):
    assert client.post("/v1/predict", json={"instances": [[1.0, 2.0]]}).status_code == 422


def test_rejects_empty(client):
    assert client.post("/v1/predict", json={"instances": []}).status_code == 422


def test_metrics_exposed(client):
    client.post("/v1/predict", json={"instances": [[5.1, 3.5, 1.4, 0.2]]})
    text = client.get("/metrics/").text
    assert "mlserve_predictions_total" in text
    assert "mlserve_model_loaded 1.0" in text
    assert "mlserve_model_info{" in text


def test_not_ready_without_model(tmp_path, monkeypatch):
    monkeypatch.setenv("MODEL_STORE_URI", str(tmp_path / "empty"))
    from app.main import app

    with TestClient(app) as c:
        assert c.get("/readyz").status_code == 503
        assert c.post("/v1/predict", json={"instances": [[1, 2, 3, 4]]}).status_code == 503

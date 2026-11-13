import json

from mlstore import ModelStore
from trainer import promote, train, validate_data


def test_validate_data_passes_on_iris():
    assert validate_data.main([]) == 0


def test_validate_data_fails_on_impossible_threshold():
    assert validate_data.main(["--min-rows", "100000"]) == 1


def test_train_registers_candidate_without_promoting(tmp_path):
    store_uri = str(tmp_path / "models")
    version_file = tmp_path / "version"

    rc = train.main(["--model-store", store_uri, "--version-file", str(version_file), "--n-estimators", "50"])

    assert rc == 0
    version = version_file.read_text()
    store = ModelStore(store_uri)
    meta = store.get_json("iris-classifier", version, "metadata.json")
    assert meta["gate_passed"] is True
    assert meta["metrics"]["accuracy"] >= 0.85
    assert not store.exists("iris-classifier", "latest.json")  # promotion is a separate step


def test_quality_gate_blocks_bad_model(tmp_path):
    rc = train.main(["--model-store", str(tmp_path), "--min-accuracy", "1.01"])
    assert rc == 2


def test_promote_and_rollback(tmp_path):
    store_uri = str(tmp_path)
    versions = []
    for i in range(2):
        vf = tmp_path / f"v{i}"
        assert train.main(["--model-store", store_uri, "--version-file", str(vf), "--n-estimators", "50"]) == 0
        versions.append(vf.read_text())
        assert promote.main(["--model-store", store_uri, "--version", versions[-1]]) == 0

    store = ModelStore(store_uri)
    assert store.latest_version("iris-classifier") == versions[1]
    assert promote.main(["--model-store", store_uri, "--rollback"]) == 0
    assert store.latest_version("iris-classifier") == versions[0]


def test_train_uses_tuned_params(tmp_path):
    params = tmp_path / "best.json"
    params.write_text(json.dumps({"best_params": {"n_estimators": 10, "max_depth": 3}}))
    vf = tmp_path / "v"
    assert train.main(["--model-store", str(tmp_path), "--params-uri", str(params), "--version-file", str(vf)]) == 0
    meta = ModelStore(str(tmp_path)).get_json("iris-classifier", vf.read_text(), "metadata.json")
    assert meta["params"]["n_estimators"] == 10

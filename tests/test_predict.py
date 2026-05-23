import math
import uuid
from unittest.mock import MagicMock

import pytest
from fastapi.testclient import TestClient

from app.schemas import PredictRequest


# --- schema / validator unit tests (no HTTP) ---


def test_schema_rejects_empty_list() -> None:
    with pytest.raises(Exception):
        PredictRequest(features=[])


def test_schema_rejects_infinity() -> None:
    with pytest.raises(Exception):
        PredictRequest(features=[float("inf"), 1.0, 2.0, 3.0])


def test_schema_rejects_nan() -> None:
    with pytest.raises(Exception):
        PredictRequest(features=[float("nan"), 1.0, 2.0, 3.0])


# --- HTTP endpoint tests ---


def test_predict_returns_200(client: TestClient) -> None:
    resp = client.post("/predict", json={"features": [5.1, 3.5, 1.4, 0.2]})
    assert resp.status_code == 200


def test_predict_response_schema(client: TestClient) -> None:
    data = client.post("/predict", json={"features": [5.1, 3.5, 1.4, 0.2]}).json()
    assert "request_id" in data
    assert "prediction" in data
    assert "confidence" in data
    assert "probabilities" in data
    assert "model_version" in data


def test_predict_request_id_is_uuid(client: TestClient) -> None:
    data = client.post("/predict", json={"features": [5.1, 3.5, 1.4, 0.2]}).json()
    uuid.UUID(data["request_id"])  # raises ValueError if invalid


def test_predict_probabilities_sum_to_one(client: TestClient) -> None:
    data = client.post("/predict", json={"features": [5.1, 3.5, 1.4, 0.2]}).json()
    assert abs(sum(data["probabilities"]) - 1.0) < 1e-5


def test_predict_confidence_matches_max_probability(client: TestClient) -> None:
    data = client.post("/predict", json={"features": [5.1, 3.5, 1.4, 0.2]}).json()
    assert math.isclose(data["confidence"], max(data["probabilities"]))


def test_predict_missing_features_returns_422(client: TestClient) -> None:
    resp = client.post("/predict", json={})
    assert resp.status_code == 422


def test_predict_empty_features_returns_422(client: TestClient) -> None:
    resp = client.post("/predict", json={"features": []})
    assert resp.status_code == 422


def test_predict_non_numeric_features_returns_422(client: TestClient) -> None:
    resp = client.post("/predict", json={"features": ["a", "b", "c", "d"]})
    assert resp.status_code == 422


def test_predict_wrong_feature_count_returns_422(
    client: TestClient, mock_predictor: MagicMock
) -> None:
    mock_predictor.predict.side_effect = ValueError(
        "Expected 4 features, got 2"
    )
    resp = client.post("/predict", json={"features": [1.0, 2.0]})
    assert resp.status_code == 422


def test_predict_db_failure_still_returns_200(client_db_down: TestClient) -> None:
    resp = client_db_down.post("/predict", json={"features": [1.0, 2.0, 3.0, 4.0]})
    assert resp.status_code == 200


def test_predict_logs_to_db(
    client: TestClient, mock_db: MagicMock
) -> None:
    client.post("/predict", json={"features": [5.1, 3.5, 1.4, 0.2]})
    mock_db.log_prediction.assert_called_once()


def test_predict_log_contains_request_id(
    client: TestClient, mock_db: MagicMock
) -> None:
    resp = client.post("/predict", json={"features": [5.1, 3.5, 1.4, 0.2]})
    logged_request_id = mock_db.log_prediction.call_args[0][0]
    assert logged_request_id == resp.json()["request_id"]


def test_predict_unique_request_ids(client: TestClient) -> None:
    ids = {
        client.post("/predict", json={"features": [1.0, 2.0, 3.0, 4.0]}).json()[
            "request_id"
        ]
        for _ in range(5)
    }
    assert len(ids) == 5

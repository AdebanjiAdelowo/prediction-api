from fastapi.testclient import TestClient


def test_health_returns_200(client: TestClient) -> None:
    resp = client.get("/health")
    assert resp.status_code == 200


def test_health_schema(client: TestClient) -> None:
    data = client.get("/health").json()
    assert "status" in data
    assert "model_loaded" in data
    assert "db_connected" in data


def test_health_status_ok(client: TestClient) -> None:
    data = client.get("/health").json()
    assert data["status"] == "ok"


def test_health_model_loaded(client: TestClient) -> None:
    data = client.get("/health").json()
    assert data["model_loaded"] is True


def test_health_db_connected(client: TestClient) -> None:
    data = client.get("/health").json()
    assert data["db_connected"] is True


def test_health_db_down_still_returns_200(client_db_down: TestClient) -> None:
    resp = client_db_down.get("/health")
    assert resp.status_code == 200


def test_health_db_down_reports_false(client_db_down: TestClient) -> None:
    data = client_db_down.get("/health").json()
    assert data["db_connected"] is False
    assert data["status"] == "ok"

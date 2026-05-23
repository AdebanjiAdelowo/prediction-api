from typing import Generator
from unittest.mock import AsyncMock, MagicMock, patch

import pytest
from fastapi.testclient import TestClient


@pytest.fixture
def mock_predictor() -> MagicMock:
    mock = MagicMock()
    mock.model = object()  # truthy — model is "loaded"
    mock.load = MagicMock()
    mock.predict.return_value = (1, 0.87, [0.05, 0.87, 0.08])
    return mock


@pytest.fixture
def mock_db() -> MagicMock:
    mock = MagicMock()
    mock.connect = AsyncMock()
    mock.disconnect = AsyncMock()
    mock.is_connected = AsyncMock(return_value=True)
    mock.log_prediction = AsyncMock()
    return mock


@pytest.fixture
def client(mock_predictor: MagicMock, mock_db: MagicMock) -> Generator[TestClient, None, None]:
    with patch("app.main.predictor", mock_predictor), patch("app.main.db", mock_db):
        from app.main import app

        with TestClient(app) as c:
            yield c


@pytest.fixture
def client_db_down(mock_predictor: MagicMock) -> Generator[TestClient, None, None]:
    down_db = MagicMock()
    down_db.connect = AsyncMock()
    down_db.disconnect = AsyncMock()
    down_db.is_connected = AsyncMock(return_value=False)
    down_db.log_prediction = AsyncMock(side_effect=Exception("DB unreachable"))

    with patch("app.main.predictor", mock_predictor), patch("app.main.db", down_db):
        from app.main import app

        with TestClient(app) as c:
            yield c

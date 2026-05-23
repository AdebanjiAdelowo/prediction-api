import json
import logging
from typing import List, Optional

import asyncpg

logger = logging.getLogger(__name__)

_CREATE_TABLE = """
CREATE TABLE IF NOT EXISTS predictions (
    id              SERIAL PRIMARY KEY,
    request_id      TEXT        NOT NULL,
    features        JSONB       NOT NULL,
    prediction      INTEGER     NOT NULL,
    confidence      FLOAT       NOT NULL,
    probabilities   JSONB       NOT NULL,
    processing_ms   FLOAT,
    created_at      TIMESTAMPTZ DEFAULT NOW()
)
"""

_INSERT = """
INSERT INTO predictions
    (request_id, features, prediction, confidence, probabilities, processing_ms)
VALUES ($1, $2, $3, $4, $5, $6)
"""


class Database:
    def __init__(self) -> None:
        self._pool: Optional[asyncpg.Pool] = None

    async def connect(self, dsn: str) -> None:
        self._pool = await asyncpg.create_pool(dsn)
        async with self._pool.acquire() as conn:
            await conn.execute(_CREATE_TABLE)
        logger.info("Database ready")

    async def disconnect(self) -> None:
        if self._pool:
            await self._pool.close()

    async def log_prediction(
        self,
        request_id: str,
        features: List[float],
        prediction: int,
        confidence: float,
        probabilities: List[float],
        processing_ms: float,
    ) -> None:
        if not self._pool:
            return
        async with self._pool.acquire() as conn:
            await conn.execute(
                _INSERT,
                request_id,
                json.dumps(features),
                prediction,
                confidence,
                json.dumps(probabilities),
                processing_ms,
            )

    async def is_connected(self) -> bool:
        if not self._pool:
            return False
        try:
            async with self._pool.acquire() as conn:
                await conn.fetchval("SELECT 1")
            return True
        except Exception:
            return False


db = Database()

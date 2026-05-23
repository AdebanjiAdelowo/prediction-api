import logging
import time
import uuid
from contextlib import asynccontextmanager
from typing import AsyncGenerator

from fastapi import FastAPI, HTTPException

from .config import settings
from .database import db
from .predictor import predictor
from .schemas import HealthResponse, PredictRequest, PredictResponse

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)


@asynccontextmanager
async def lifespan(app: FastAPI) -> AsyncGenerator[None, None]:
    predictor.load(
        settings.model_path,
        input_dim=settings.model_input_dim,
        num_classes=settings.model_num_classes,
    )
    try:
        await db.connect(settings.database_url)
    except Exception as exc:
        logger.warning("Could not connect to database: %s", exc)
    yield
    await db.disconnect()


app = FastAPI(
    title="Prediction API",
    version=settings.model_version,
    lifespan=lifespan,
)


@app.get("/health", response_model=HealthResponse)
async def health() -> HealthResponse:
    return HealthResponse(
        status="ok",
        model_loaded=predictor.model is not None,
        db_connected=await db.is_connected(),
    )


@app.post("/predict", response_model=PredictResponse)
async def predict(body: PredictRequest) -> PredictResponse:
    request_id = str(uuid.uuid4())
    t0 = time.monotonic()

    try:
        prediction, confidence, probabilities = predictor.predict(body.features)
    except (ValueError, RuntimeError) as exc:
        raise HTTPException(status_code=422, detail=str(exc))

    processing_ms = (time.monotonic() - t0) * 1000

    try:
        await db.log_prediction(
            request_id,
            body.features,
            prediction,
            confidence,
            probabilities,
            processing_ms,
        )
    except Exception as exc:
        logger.error("DB log failed for %s: %s", request_id, exc)

    return PredictResponse(
        request_id=request_id,
        prediction=prediction,
        confidence=confidence,
        probabilities=probabilities,
        model_version=settings.model_version,
    )

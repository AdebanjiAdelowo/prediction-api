import math
from typing import List

from pydantic import BaseModel, Field, field_validator


class PredictRequest(BaseModel):
    features: List[float] = Field(..., min_length=1, description="Input feature vector")

    @field_validator("features")
    @classmethod
    def features_must_be_finite(cls, v: List[float]) -> List[float]:
        for f in v:
            if not math.isfinite(f):
                raise ValueError("All features must be finite numbers")
        return v


class PredictResponse(BaseModel):
    model_config = {"protected_namespaces": ()}

    request_id: str
    prediction: int
    confidence: float
    probabilities: List[float]
    model_version: str


class HealthResponse(BaseModel):
    model_config = {"protected_namespaces": ()}

    status: str
    model_loaded: bool
    db_connected: bool

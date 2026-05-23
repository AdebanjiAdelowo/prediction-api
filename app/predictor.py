import logging
from pathlib import Path
from typing import List, Tuple

import torch
import torch.nn as nn

logger = logging.getLogger(__name__)


class SimpleClassifier(nn.Module):
    def __init__(self, input_dim: int, hidden_dim: int, num_classes: int) -> None:
        super().__init__()
        self.net = nn.Sequential(
            nn.Linear(input_dim, hidden_dim),
            nn.ReLU(),
            nn.Linear(hidden_dim, num_classes),
        )

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        return self.net(x)


class Predictor:
    def __init__(self) -> None:
        self.model: nn.Module | None = None
        self.input_dim: int = 4
        self.num_classes: int = 3

    def load(self, model_path: str, input_dim: int = 4, num_classes: int = 3) -> None:
        self.input_dim = input_dim
        self.num_classes = num_classes
        path = Path(model_path)
        if not path.exists():
            logger.warning("Model not found at %s — saving untrained weights", path)
            self._save_dummy(path)
        self.model = SimpleClassifier(input_dim, 16, num_classes)
        self.model.load_state_dict(
            torch.load(path, map_location="cpu", weights_only=True)
        )
        self.model.eval()
        logger.info("Model loaded from %s", path)

    def _save_dummy(self, path: Path) -> None:
        dummy = SimpleClassifier(self.input_dim, 16, self.num_classes)
        torch.save(dummy.state_dict(), path)

    def predict(self, features: List[float]) -> Tuple[int, float, List[float]]:
        if self.model is None:
            raise RuntimeError("Model not loaded")
        if len(features) != self.input_dim:
            raise ValueError(
                f"Expected {self.input_dim} features, got {len(features)}"
            )
        x = torch.tensor([features], dtype=torch.float32)
        with torch.no_grad():
            logits = self.model(x)
            probs = torch.softmax(logits, dim=1).squeeze(0)
        probs_list: List[float] = probs.tolist()
        prediction = int(torch.argmax(probs).item())
        confidence = float(probs[prediction].item())
        return prediction, confidence, probs_list


predictor = Predictor()

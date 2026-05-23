#!/usr/bin/env python
"""Train a simple Iris classifier and save weights to model.pt."""

import torch
import torch.nn as nn
from torch.utils.data import DataLoader, TensorDataset

from app.predictor import SimpleClassifier

try:
    from sklearn.datasets import load_iris
    from sklearn.model_selection import train_test_split
    from sklearn.preprocessing import StandardScaler

    iris = load_iris()
    X = iris.data.astype("float32")
    y = iris.target

    scaler = StandardScaler()
    X = scaler.fit_transform(X).astype("float32")
    X_train, X_val, y_train, y_val = train_test_split(
        X, y, test_size=0.2, random_state=42
    )

    ds = TensorDataset(
        torch.tensor(X_train), torch.tensor(y_train, dtype=torch.long)
    )
    loader = DataLoader(ds, batch_size=16, shuffle=True)

    model = SimpleClassifier(input_dim=4, hidden_dim=16, num_classes=3)
    opt = torch.optim.Adam(model.parameters(), lr=1e-2)
    loss_fn = nn.CrossEntropyLoss()

    model.train()
    for epoch in range(60):
        for xb, yb in loader:
            opt.zero_grad()
            loss_fn(model(xb), yb).backward()
            opt.step()

    model.eval()
    with torch.no_grad():
        preds = model(torch.tensor(X_val)).argmax(dim=1).numpy()
    acc = (preds == y_val).mean()
    print(f"Validation accuracy: {acc:.2%}")

except ImportError:
    print("scikit-learn not installed — saving untrained weights")
    model = SimpleClassifier(input_dim=4, hidden_dim=16, num_classes=3)

torch.save(model.state_dict(), "model.pt")
print("Saved model.pt")

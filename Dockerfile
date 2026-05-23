# ── Stage 1: install Python dependencies ─────────────────────────────────────
# A dedicated build stage keeps gcc and build artefacts out of the final image.
# asyncpg compiles a C extension, so gcc is required here but not at runtime.
FROM python:3.11-slim AS deps

RUN apt-get update \
    && apt-get install -y --no-install-recommends gcc \
    && rm -rf /var/lib/apt/lists/*

# All production dependencies land in an isolated virtual environment so we
# can copy the entire /venv directory into the slim runtime stage cleanly.
RUN python -m venv /venv
ENV PATH="/venv/bin:$PATH"

COPY requirements.txt .

# Install torch CPU-only first (separate layer — large and slow, so we cache it
# independently from the rest of the deps to avoid re-downloading on small code
# changes).
RUN pip install --no-cache-dir torch \
        --index-url https://download.pytorch.org/whl/cpu

# pip sees torch already satisfies torch>=2.2.0 in requirements.txt and skips it.
RUN pip install --no-cache-dir -r requirements.txt


# ── Stage 2: train model ──────────────────────────────────────────────────────
# scikit-learn is only needed to generate the Iris training data; it is not
# required at serve time so it never appears in the runtime image.
FROM deps AS trainer

RUN pip install --no-cache-dir scikit-learn

WORKDIR /build
COPY app/ ./app/
COPY train_model.py .

# Produces /build/model.pt — copied into the runtime stage below.
RUN python train_model.py


# ── Stage 3: production runtime ───────────────────────────────────────────────
# Fresh python:3.11-slim base with no build tools, no scikit-learn, no pip
# cache — only the venv and the application itself.
FROM python:3.11-slim AS runtime

ENV PATH="/venv/bin:$PATH" \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

# Non-root user: principle of least privilege.
RUN groupadd --gid 1001 appgroup \
    && useradd --uid 1001 --gid 1001 \
               --no-create-home --shell /bin/false appuser

WORKDIR /app

COPY --from=deps    /venv             /venv
COPY --from=trainer /build/app        ./app
COPY --from=trainer /build/model.pt   ./model.pt

USER appuser
EXPOSE 8000

# Docker marks the container unhealthy if /health stops responding; this
# surfaces in `docker ps`, Compose, and ECS health checks automatically.
HEALTHCHECK --interval=30s --timeout=10s --start-period=40s --retries=3 \
    CMD python -c \
        "import urllib.request; urllib.request.urlopen('http://localhost:8000/health')" \
        || exit 1

CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000"]

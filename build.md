# Build Notes — What Was Built and Why

This document explains every significant decision made in the prediction-api project: what was chosen, what the alternatives were, and the reasoning behind each call.

---

## Table of contents

1. [API layer](#1-api-layer)
2. [PyTorch model and predictor](#2-pytorch-model-and-predictor)
3. [PostgreSQL logging](#3-postgresql-logging)
4. [Input validation and error handling](#4-input-validation-and-error-handling)
5. [Test suite](#5-test-suite)
6. [Multi-stage Dockerfile](#6-multi-stage-dockerfile)
7. [Docker Compose](#7-docker-compose)
8. [Terraform infrastructure](#8-terraform-infrastructure)
9. [GitHub Actions CI/CD](#9-github-actions-cicd)

---

## 1. API layer

### FastAPI over Flask / Django

FastAPI was chosen over Flask and Django for three concrete reasons:

- **Pydantic is built in.** Request and response bodies are declared as Python dataclasses with type annotations. Validation, coercion, and error messages are generated automatically — no separate serializer layer needed.
- **Async from the start.** The database driver (`asyncpg`) and the server (`uvicorn`) are both async. FastAPI's async support means a single thread can handle many concurrent requests while waiting on the database, without the complexity of threading.
- **Lifespan events.** The `@asynccontextmanager` lifespan hook loads the model and opens the database pool exactly once at startup and tears them down cleanly on shutdown. Flask requires `before_first_request` hacks; Django has no equivalent for long-lived resources.

### `lifespan` over `@app.on_event`

FastAPI deprecated `@app.on_event("startup")` in favour of the `lifespan` context manager. The context manager makes the setup/teardown pair visually obvious — everything before `yield` is setup, everything after is teardown — and avoids the hidden coupling of separate event handlers.

### Uvicorn over Gunicorn

Uvicorn was kept as the single server (not Gunicorn + Uvicorn workers) because:
- This is a single-instance deployment on EC2, not a multi-process cluster.
- The workload is I/O-bound (database writes, tensor ops), not CPU-bound, so adding worker processes would not improve throughput meaningfully.
- Gunicorn adds operational complexity (worker restart policies, signal handling) that only pays off at scale.

---

## 2. PyTorch model and predictor

### Model trained inside the Docker build, not pre-baked

The `train_model.py` script runs inside the `trainer` Docker stage rather than committing `model.pt` to git. This decision was made because:

- **Model weights are binary blobs.** Storing them in git inflates repo size and produces meaningless diffs.
- **Reproducibility.** Anyone who clones the repo and builds the image gets a freshly trained, consistent model from the same code.
- **Separation of concerns.** Model training is a build-time concern; serving is a runtime concern. The Dockerfile boundary makes this explicit.

An S3 bucket is provisioned by Terraform for storing released model artefacts when training is expensive enough that rebuilding from scratch on every deploy is impractical. The EC2 instance role has `s3:GetObject` permission so a production variant could pull a specific versioned model at startup instead.

### `predictor` as a module-level singleton

The `Predictor` instance lives at module scope in `app/predictor.py` and is loaded once during the lifespan startup:

```python
predictor.load(settings.model_path, ...)
```

**Why a singleton rather than dependency injection?** The model weights are 100 % read-only after loading. There is no state shared between requests, no need to swap models mid-flight, and no test isolation concern because the tests mock the entire `predictor` object. A singleton avoids the overhead of re-reading weights from disk on every request.

### `weights_only=True` in `torch.load`

```python
torch.load(path, map_location="cpu", weights_only=True)
```

The `weights_only=True` flag prevents `torch.load` from unpickling arbitrary Python objects, which is a known arbitrary-code-execution vector. Only tensor data is deserialised. This was added as a security hardening measure when the model file may be supplied by an external source or downloaded from S3.

### CPU-only torch in the Docker image

The production image uses the CPU-only torch wheel (`--index-url https://download.pytorch.org/whl/cpu`). The classifier is a tiny two-layer MLP; it runs inference in microseconds on CPU. CUDA binaries would add ~3 GB to the image for zero measurable benefit on a `t3.small` instance that has no GPU.

---

## 3. PostgreSQL logging

### `asyncpg` over `psycopg2` / SQLAlchemy

`asyncpg` is a pure-async PostgreSQL driver. Using it directly (without SQLAlchemy) was a deliberate choice:

- **No ORM overhead.** The schema is a single table with five columns. An ORM adds abstraction that isn't useful here and complicates async usage.
- **Performance.** `asyncpg` encodes and decodes values using the PostgreSQL binary protocol, which is faster than the text protocol used by `psycopg2`.
- **Native async.** `psycopg2` is synchronous. Running it in a FastAPI route requires `asyncio.run_in_executor`, which spawns a thread and negates the benefit of async.

### DB failure does not fail the request

```python
try:
    await db.log_prediction(...)
except Exception as exc:
    logger.error("DB log failed for %s: %s", request_id, exc)
```

The prediction is returned to the caller even if the database write fails. This was an explicit product decision: the database is an audit log, not the source of truth for the prediction itself. Blocking the response on a flaky database would degrade availability of the core feature. The error is logged so it is observable.

### Table created at startup, not via migrations

`CREATE TABLE IF NOT EXISTS` runs in the lifespan startup. This is intentional for a single-table service where schema evolution is rare and the table definition is simple. A migration framework like Alembic would be the right choice if the schema were likely to change or if multiple services shared the same database.

### `JSONB` for features and probabilities

Features and probability vectors are stored as `JSONB` rather than `FLOAT[]` (PostgreSQL array) or a normalised column per feature. JSONB was chosen because:

- The number of features is configurable at runtime (`MODEL_INPUT_DIM`). A fixed array type or a column-per-feature schema would break when the model is retrained with a different input dimension.
- JSONB supports indexing if queries against individual feature values become necessary later.

---

## 4. Input validation and error handling

### Pydantic `field_validator` for finiteness

Pydantic validates that `features` is a non-empty list of floats automatically. A custom `@field_validator` additionally rejects `inf` and `NaN`:

```python
@field_validator("features")
@classmethod
def features_must_be_finite(cls, v):
    for f in v:
        if not math.isfinite(f):
            raise ValueError("All features must be finite numbers")
    return v
```

`torch.softmax` produces `NaN` outputs when given `inf` inputs. Catching this at the boundary returns a clear 422 error with a message rather than a 500 with a cryptic tensor error.

### Wrong feature count returns 422, not 500

The predictor raises `ValueError` when `len(features) != self.input_dim`. The endpoint catches `ValueError` and converts it to an `HTTPException(status_code=422)`:

```python
except (ValueError, RuntimeError) as exc:
    raise HTTPException(status_code=422, detail=str(exc))
```

422 Unprocessable Entity is semantically correct: the request was syntactically valid JSON but semantically invalid for this model. 400 Bad Request is for malformed syntax; 500 Internal Server Error would imply a bug in the server.

---

## 5. Test suite

### Mocking at the module boundary, not the function level

The tests patch `app.main.predictor` and `app.main.db` — the names as they are imported into the main module — rather than patching the underlying classes:

```python
with patch("app.main.predictor", mock_pred), patch("app.main.db", mock_db):
    ...
```

This is the correct level of abstraction. The tests verify the HTTP contract (status codes, response shape, UUID validity, DB logging called) without coupling to implementation details of the model or database driver.

### `TestClient` over `httpx.AsyncClient`

FastAPI's `TestClient` wraps the ASGI app in a synchronous interface. It runs the lifespan context manager (which calls the mocked `predictor.load` and `db.connect`) and lets tests be plain `def` functions rather than `async def`. This keeps tests simple and avoids requiring `pytest-asyncio` configuration.

### Database mock does not use a real PostgreSQL

Tests run in ~0.09 seconds with no external dependencies. Real-database tests have their place (catching migration errors, connection pool bugs) but belong in a separate integration test suite. The mock verifies that `db.log_prediction` was called with the correct `request_id`, which is the contract the endpoint is responsible for.

### `client_db_down` fixture

A second fixture simulates a database that is unreachable. This tests the explicit requirement that the API still returns HTTP 200 even when the database is down — the failure path is tested as a first-class case, not left to chance.

---

## 6. Multi-stage Dockerfile

### Three stages: `deps` → `trainer` → `runtime`

```
deps     — python:3.11-slim + gcc + venv + torch + runtime deps
trainer  — inherits deps, adds scikit-learn, trains model.pt
runtime  — fresh python:3.11-slim, copies /venv and model.pt only
```

**Why three stages rather than two?**

The `deps` and `trainer` stages are kept separate so that the dependency installation layer is cached independently from the training step. If `requirements.txt` changes, only `deps` and everything after it rebuilds; `torch` (the largest layer at ~700 MB) is not re-downloaded. If only `train_model.py` changes, only `trainer` and `runtime` rebuild.

### Virtual environment (`/venv`) pattern

Packages are installed into `/venv` rather than the system Python. This makes `COPY --from=deps /venv /venv` in the `runtime` stage an atomic copy of all installed packages, with no risk of partial copies or path mismatches. The runtime stage sets `ENV PATH="/venv/bin:$PATH"` so all Python commands use the venv automatically.

### Non-root user (`appuser`, uid 1001)

```dockerfile
RUN groupadd --gid 1001 appgroup \
    && useradd --uid 1001 --gid 1001 --no-create-home --shell /bin/false appuser
...
USER appuser
```

Running as root inside a container is the default but is a security risk: if a vulnerability allows container escape, the attacker has root on the host. A non-root user limits blast radius. uid/gid 1001 is used rather than a named user lookup so the numeric ID works consistently across different base image variants.

### `HEALTHCHECK` uses Python, not `curl`

```dockerfile
HEALTHCHECK CMD python -c \
    "import urllib.request; urllib.request.urlopen('http://localhost:8000/health')" \
    || exit 1
```

`curl` is not installed in `python:3.11-slim` and installing it just for the healthcheck adds a layer and a dependency. `urllib.request` is part of the Python standard library and is always available.

### `.dockerignore` excludes `model.pt`

The local `model.pt` is excluded from the build context because the model is always trained fresh inside the `trainer` stage. Including it would silently bake a potentially stale local model into the image, making builds non-reproducible.

---

## 7. Docker Compose

### `target: runtime` in the build section

```yaml
build:
  context: .
  target: runtime
```

Docker Compose builds all stages up to and including `runtime`. The intermediate stages are discarded. This means the local dev image is identical to the production image — the same torch version, the same non-root user, the same entry point. "It works in Compose" means it works in production.

### Volume mount for hot-reload

```yaml
volumes:
  - ./app:/app/app:ro
```

Source code is mounted into the container so `uvicorn --reload` picks up changes without rebuilding the image. Only `./app` is mounted, not the project root, so `model.pt` (which lives at `/app/model.pt` inside the image) is not shadowed by the mount.

### `depends_on: condition: service_healthy`

The API service only starts after Postgres passes its `pg_isready` healthcheck. Without this, the API container can start, attempt to connect to Postgres, fail, and crash — triggering a restart loop. The health condition gate eliminates that race.

### `postgres:16-alpine` over `postgres:16`

The Alpine variant is ~50 MB vs ~400 MB for the Debian-based image. For a local development dependency there is no reason to carry the full Debian image.

---

## 8. Terraform infrastructure

### Resources provisioned

| Resource | Why it exists |
|---|---|
| ECR repository | Stores the Docker image. ECR is tightly integrated with AWS IAM — no separate registry credentials to manage. |
| ECR lifecycle policy | Keeps the last 10 images. Without it, every push accumulates images and storage costs grow unbounded. |
| S3 bucket | Stores versioned `model.pt` artefacts. Versioning allows instant rollback to a previous model without rebuilding the image. |
| EC2 `t3.small` | Runs the container. `t3.small` gives 2 vCPU and 2 GB RAM — enough for the tiny Iris classifier with headroom for OS overhead. |
| Security group | Opens port 8000 (API) and 22 (SSH). Everything else is denied by default. |
| IAM role for EC2 | Grants the instance ECR pull, S3 read, and CloudWatch log write. No access keys are stored on the instance — credentials come from the instance metadata service. |
| IAM OIDC provider | Enables GitHub Actions to assume an AWS role via short-lived tokens. Eliminates the need to store `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` as GitHub secrets. |
| IAM role for GitHub Actions | Scoped to ECR push only. The CI/CD pipeline cannot access S3, EC2, or any other service — minimum viable permissions. |

### Files are split by resource type, not by environment

```
ecr.tf     — ECR repository and lifecycle policy
s3.tf      — S3 bucket and its settings
ec2.tf     — security group, IAM, EC2 instance
oidc.tf    — GitHub Actions OIDC
```

Splitting by resource type makes it easy to read all the networking in one place, all the storage in one place, and so on. Splitting by environment (dev.tf / prod.tf) creates duplication and makes cross-cutting changes — like updating an IAM policy — require edits in multiple files.

### IMDSv2 enforced (`http_tokens = "required"`)

```hcl
metadata_options {
  http_tokens                 = "required"
  http_put_response_hop_limit = 1
}
```

IMDSv1 (the default) is vulnerable to SSRF attacks: a malicious request can trick the server into fetching `http://169.254.169.254/latest/meta-data/iam/security-credentials/...` and leaking the instance's IAM credentials. IMDSv2 requires a session token obtained via a PUT request with a TTL, which cannot be initiated by a simple GET-based SSRF.

### `user_data_replace_on_change = true`

```hcl
user_data_replace_on_change = true
```

By default, changing `user_data` on an existing instance has no effect — the instance is not replaced. This flag causes Terraform to replace the instance when the bootstrap script changes. This ensures that a change to the ECR image URI or database URL in `user_data.sh.tpl` actually takes effect.

### Root volume encrypted with `gp3`

```hcl
root_block_device {
  volume_size = 20
  volume_type = "gp3"
  encrypted   = true
}
```

`gp3` is the current-generation SSD type and is cheaper than `gp2` at the same performance baseline. Encryption is enabled because the Docker image and application logs may contain prediction data; encrypting at rest costs nothing and satisfies most compliance requirements.

### AMI resolved by data source, not hard-coded

```hcl
data "aws_ami" "amazon_linux_2023" {
  most_recent = true
  owners      = ["amazon"]
  filter { name = "name", values = ["al2023-ami-2023.*-x86_64"] }
}
```

Hard-coded AMI IDs are region-specific and go stale as AWS releases patched images. The data source always resolves to the latest Amazon Linux 2023 AMI in whatever region Terraform is targeting, making the config portable and automatically pulling security patches.

### `force_delete = true` on the ECR repository

```hcl
resource "aws_ecr_repository" "api" {
  force_delete = true
  ...
}
```

By default, `terraform destroy` fails if the ECR repository contains images. `force_delete = true` allows `terraform destroy` to clean up completely. In a production environment this flag should be removed to prevent accidental image deletion.

---

## 9. GitHub Actions CI/CD

### Two separate workflow files

```
tests.yml   — runs on every push to every branch
deploy.yml  — runs on push to main only
```

Separating them means feature branch pushes still get test feedback without triggering a Docker build or AWS authentication. The deploy workflow re-runs the tests before pushing the image: this is intentional duplication. The test job in `deploy.yml` is the gate; if it fails, the build-and-push job is skipped.

### OIDC authentication — no stored AWS keys

```yaml
permissions:
  id-token: write
  contents: read

- uses: aws-actions/configure-aws-credentials@v4
  with:
    role-to-assume: ${{ secrets.AWS_ROLE_ARN }}
```

The only GitHub secret needed is `AWS_ROLE_ARN`. GitHub mints a short-lived OIDC JWT for the workflow run; AWS verifies it against the OIDC provider created by Terraform and issues temporary credentials valid for the duration of the job. Long-lived access keys:

- Can be leaked in logs, forks, or misconfigured repo settings.
- Cannot be automatically rotated.
- Grant permanent access until manually revoked.

OIDC tokens expire in minutes and cannot be reused outside the specific workflow run they were issued for.

### Two image tags: `:latest` and `:<git-sha>`

```yaml
tags: |
  ${{ env.REGISTRY }}/prediction-api:${{ github.sha }}
  ${{ env.REGISTRY }}/prediction-api:latest
```

- `:latest` is what the EC2 `user_data` script pulls on first boot. It always points to the most recently deployed version.
- `:<git-sha>` is immutable and traceable. If a bad deploy is discovered, the exact image that caused it can be identified from the git log. Rolling back is `docker pull <ECR>:previous-sha && docker run ...`.

Tagging with only `:latest` makes rollback harder. Tagging with only the SHA requires updating the EC2 bootstrap script on every deploy.

### GHA layer cache (`type=gha`)

```yaml
cache-from: type=gha
cache-to:   type=gha,mode=max
```

Docker layers are cached in the GitHub Actions cache store between runs. On a warm cache, only layers that have changed since the last push are rebuilt. For this image — where the `deps` stage (torch install, ~3 min) is stable — this reduces CI build time from ~5 minutes to under 30 seconds on typical code-only changes.

### `provenance: false`

```yaml
provenance: false
```

Docker Buildx with `docker/build-push-action@v6` generates SBOM provenance attestations by default. These are stored as additional manifest entries in ECR. Some older ECR configurations and deployment tooling do not handle multi-platform manifests correctly. Disabling provenance keeps the ECR manifest simple: one tag, one image.

### CPU-only torch in CI

```yaml
- name: Install PyTorch (CPU-only wheel)
  run: pip install torch --index-url https://download.pytorch.org/whl/cpu
```

GitHub Actions runners are CPU-only. Installing the default torch wheel (which includes CUDA binaries) downloads ~800 MB unnecessarily. The CPU wheel is ~200 MB and is functionally identical for training and running the Iris classifier.

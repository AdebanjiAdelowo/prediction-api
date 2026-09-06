# Prediction API

A FastAPI service that loads a PyTorch classifier at startup, exposes a `POST /predict` endpoint, and logs every prediction to PostgreSQL.

---

## Contents

- [Quick start (Docker Compose)](#quick-start-docker-compose)
- [Run locally without Docker](#run-locally-without-docker)
- [API endpoints](#api-endpoints)
- [Configuration](#configuration)
- [Running tests](#running-tests)
- [Deploy to AWS with Terraform](#deploy-to-aws-with-terraform)
- [CI/CD pipeline](#cicd-pipeline)
- [Project structure](#project-structure)

---

## Quick start (Docker Compose)

The fastest way to get the API and a PostgreSQL database running together.

**Prerequisites:** [Docker Desktop](https://www.docker.com/products/docker-desktop/) installed and running.

```bash
# 1. Clone the repo
git clone https://github.com/AdebanjiAdelowo/prediction-api.git
cd prediction-api

# 2. Start the stack (builds image on first run, takes ~3 min to train the model)
docker compose up --build

# 3. The API is now available at http://localhost:8000
```

On subsequent runs the image is cached, so startup is near-instant:

```bash
docker compose up
```

To stop and remove the database volume:

```bash
docker compose down -v
```

---

## Run locally without Docker

**Prerequisites:** Python 3.11+, PostgreSQL running on `localhost:5432`.

```bash
# 1. Create and activate a virtual environment
python -m venv .venv
source .venv/bin/activate        # Windows: .venv\Scripts\activate

# 2. Install PyTorch CPU-only (avoids downloading the large CUDA build)
pip install torch --index-url https://download.pytorch.org/whl/cpu

# 3. Install remaining dependencies
pip install -r requirements.txt

# 4. Train the model (produces model.pt in the project root)
python train_model.py

# 5. Copy the example env file and edit DATABASE_URL
cp .env.example .env
# Edit .env: set DATABASE_URL to point at your local Postgres instance

# 6. Start the server
uvicorn app.main:app --host 0.0.0.0 --port 8000 --reload
```

The `--reload` flag restarts the server automatically whenever you edit a source file.

---

## API endpoints

### `GET /health`

Returns the current health of the service.

```bash
curl http://localhost:8000/health
```

```json
{
  "status": "ok",
  "model_loaded": true,
  "db_connected": true
}
```

### `POST /predict`

Accepts a JSON body with a `features` array and returns a prediction, confidence score, and a unique request ID.

```bash
curl -X POST http://localhost:8000/predict \
  -H "Content-Type: application/json" \
  -d '{"features": [5.1, 3.5, 1.4, 0.2]}'
```

```json
{
  "request_id": "550e8400-e29b-41d4-a716-446655440000",
  "prediction": 0,
  "confidence": 0.9821,
  "probabilities": [0.9821, 0.0134, 0.0045],
  "model_version": "1.0.0"
}
```

**Validation errors** (wrong number of features, non-numeric values, empty list) return HTTP `422` with a detail message.

### Interactive docs

FastAPI generates interactive documentation automatically:

| URL | Description |
|-----|-------------|
| `http://localhost:8000/docs` | Swagger UI: try endpoints in the browser |
| `http://localhost:8000/redoc` | ReDoc: clean reference documentation |

---

## Configuration

All settings are read from environment variables (or a `.env` file).

| Variable | Default | Description |
|---|---|---|
| `MODEL_PATH` | `model.pt` | Path to the PyTorch weights file |
| `MODEL_VERSION` | `1.0.0` | Version string returned by `/health` |
| `MODEL_INPUT_DIM` | `4` | Number of input features the model expects |
| `MODEL_NUM_CLASSES` | `3` | Number of output classes |
| `DATABASE_URL` | `postgresql://postgres:postgres@localhost:5432/predictions` | PostgreSQL connection string |

Copy `.env.example` to `.env` and override any values you need.

---

## Running tests

Tests mock the database and the model, so **no real PostgreSQL or `model.pt` is required**.

```bash
# Install dev dependencies
pip install torch --index-url https://download.pytorch.org/whl/cpu
pip install -r requirements-dev.txt

# Run the full suite
pytest -v
```

To run tests against a real database:

```bash
DATABASE_URL=postgresql://postgres:postgres@localhost:5432/predictions_test \
  pytest -v
```

---

## Deploy to AWS with Terraform

Provisions an ECR repository, an S3 bucket for model artefacts, and an EC2 instance that pulls and runs the Docker image.

**Prerequisites:** [Terraform ≥ 1.6](https://developer.hashicorp.com/terraform/install), [AWS CLI](https://aws.amazon.com/cli/) configured.

```bash
cd terraform

# 1. Copy and edit variables
cp terraform.tfvars.example terraform.tfvars
# Set github_owner, aws_region, and optionally database_url

# 2. Initialise providers
terraform init

# 3. Preview what will be created
terraform plan

# 4. Apply (creates ECR, S3, EC2, IAM, OIDC provider)
terraform apply
```

After `apply` succeeds, note the outputs:

```
api_url                  = "http://1.2.3.4:8000"
ecr_repository_url       = "123456789.dkr.ecr.us-east-1.amazonaws.com/prediction-api"
github_actions_role_arn  = "arn:aws:iam::123456789:role/prediction-api-github-actions"
s3_models_bucket         = "prediction-api-models-123456789"
```

Then add the GitHub secret so the CI/CD pipeline can push images:

1. Go to **GitHub → Settings → Secrets → New repository secret**
2. Name: `AWS_ROLE_ARN`
3. Value: the `github_actions_role_arn` output from Terraform

The EC2 instance runs a bootstrap script on first boot that installs Docker, authenticates with ECR, and starts the container. Allow ~2 minutes for it to be ready after `terraform apply`.

To tear everything down:

```bash
terraform destroy
```

---

## CI/CD pipeline

Two GitHub Actions workflows are included.

### `tests.yml`: runs on every push to any branch

1. Spins up a PostgreSQL service container
2. Installs CPU-only PyTorch + dev dependencies
3. Trains `model.pt`
4. Runs `pytest -v`

### `deploy.yml`: runs on push to `main` only

1. Runs the same test suite (image is never pushed if tests fail)
2. Authenticates with AWS via **OIDC**: no long-lived keys stored as secrets
3. Builds the multi-stage Docker image (`deps → trainer → runtime`)
4. Pushes two tags to ECR: `:latest` and `:<git-sha>`

The only secret required is `AWS_ROLE_ARN` (set up in the Terraform step above).

---

## Project structure

```
prediction-api/
├── app/
│   ├── config.py      : settings loaded from environment variables
│   ├── database.py    : asyncpg connection pool, prediction logging
│   ├── main.py        : FastAPI app, /health and /predict endpoints
│   ├── predictor.py   : PyTorch model loading and inference
│   └── schemas.py     : Pydantic request / response models
│
├── tests/
│   ├── conftest.py    : mock predictor and database fixtures
│   ├── test_health.py : /health endpoint tests
│   └── test_predict.py: /predict endpoint tests (valid + invalid inputs)
│
├── terraform/
│   ├── main.tf        : AWS provider, data sources
│   ├── ecr.tf         : ECR repository + lifecycle policy
│   ├── s3.tf          : model artefact bucket
│   ├── ec2.tf         : EC2 instance, security group, IAM role
│   ├── oidc.tf        : GitHub Actions OIDC provider
│   ├── variables.tf   : all input variables with descriptions
│   ├── outputs.tf     : ECR URL, EC2 IP, role ARN, etc.
│   └── user_data.sh.tpl: EC2 bootstrap: install Docker, pull image, run container
│
├── .github/workflows/
│   ├── tests.yml      : run pytest on every push
│   └── deploy.yml     : build + push to ECR on push to main
│
├── Dockerfile         : 3-stage: deps / trainer / runtime
├── docker-compose.yml : local dev: API + PostgreSQL
├── train_model.py     : trains an Iris classifier, saves model.pt
├── requirements.txt   : production dependencies
└── requirements-dev.txt: adds pytest, httpx, scikit-learn
```

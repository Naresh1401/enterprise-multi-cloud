VENV    ?= .venv
PYTHON  ?= python3
BIN     := $(VENV)/bin
IMAGE   ?= multi-cloud-app
VERSION ?= $(shell git rev-parse --short HEAD 2>/dev/null || echo dev)

# docker compose's PostgreSQL; the tests create and drop their own database on it
TEST_DATABASE_ADMIN_URL ?= postgresql://postgres:local-only-password@127.0.0.1:5432/postgres

.PHONY: install lint format db-up db-down test audit check run up docker-build docker-run tofu-check helm-check inventory pipeline

$(BIN)/activate: requirements.txt requirements-dev.txt
	@$(PYTHON) -c 'import sys; sys.exit(0 if sys.version_info >= (3, 11) else "Python 3.11+ is required: make PYTHON=python3.11 ...")'
	$(PYTHON) -m venv --clear $(VENV)
	$(BIN)/pip install --upgrade pip
	$(BIN)/pip install -r requirements-dev.txt
	touch $(BIN)/activate

install: $(BIN)/activate

lint: install
	$(BIN)/ruff check .
	$(BIN)/ruff format --check .

format: install
	$(BIN)/ruff format .
	$(BIN)/ruff check --fix .

db-up:
	docker compose up --detach --wait db

db-down:
	docker compose down --volumes

test: install db-up
	TEST_DATABASE_ADMIN_URL=$(TEST_DATABASE_ADMIN_URL) $(BIN)/pytest --cov

audit: install
	$(BIN)/pip-audit -r requirements.txt

check: lint test audit

run: install
	APP_VERSION=$(VERSION) $(BIN)/python app/main.py

# The service with PostgreSQL and the migration job, as docker-compose.yml describes
up:
	docker compose up --build

docker-build:
	docker build --build-arg APP_VERSION=$(VERSION) --tag $(IMAGE):$(VERSION) .

docker-run: docker-build
	docker run --rm --publish 8000:8000 $(IMAGE):$(VERSION)

INFRA := aws azure gcp eks gke aks modules/aws-database modules/gcp-database modules/azure-database
CHART := deploy/helm/multi-cloud-app
# values.yaml alone, each cloud's values, then each cloud's with the database values its OpenTofu outputs
CHART_VALUES := "" values-gke.yaml values-aks.yaml values-eks.yaml \
	"values-gke.yaml ci/gke-database-values.yaml" "values-aks.yaml ci/aks-database-values.yaml" \
	"values-eks.yaml ci/eks-database-values.yaml" values-kind.yaml

tofu-check:
	@for dir in $(INFRA); do \
		echo "== infra/$$dir"; \
		(cd infra/$$dir && tofu fmt -check -recursive && tofu init -backend=false -input=false >/dev/null && tofu validate && tofu test) || exit 1; \
	done

helm-check:
	@for values in $(CHART_VALUES); do \
		args=""; for file in $$values; do args="$$args --values $(CHART)/$$file"; done; \
		echo "== values.yaml $$values"; \
		helm lint --strict $(CHART) $$args && helm template ci $(CHART) $$args >/dev/null || exit 1; \
	done

# Every resource each target would create, from plans against mock providers (no cloud account)
inventory:
	./scripts/inventory.sh

pipeline:
	./scripts/run_local_pipeline.sh

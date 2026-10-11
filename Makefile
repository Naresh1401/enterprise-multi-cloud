VENV    ?= .venv
PYTHON  ?= python3
BIN     := $(VENV)/bin
IMAGE   ?= multi-cloud-app
VERSION ?= $(shell git rev-parse --short HEAD 2>/dev/null || echo dev)

.PHONY: install lint format test audit check run docker-build docker-run tofu-check helm-check pipeline

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

test: install
	$(BIN)/pytest --cov

audit: install
	$(BIN)/pip-audit -r requirements.txt

check: lint test audit

run: install
	APP_VERSION=$(VERSION) $(BIN)/python app/main.py

docker-build:
	docker build --build-arg APP_VERSION=$(VERSION) --tag $(IMAGE):$(VERSION) .

docker-run: docker-build
	docker run --rm --publish 8000:8000 $(IMAGE):$(VERSION)

INFRA := aws azure gcp eks gke aks
CHART := deploy/helm/multi-cloud-app

tofu-check:
	@for dir in $(INFRA); do \
		echo "== infra/$$dir"; \
		(cd infra/$$dir && tofu fmt -check && tofu init -backend=false -input=false >/dev/null && tofu validate) || exit 1; \
	done

helm-check:
	@for values in "" values-gke.yaml values-aks.yaml values-eks.yaml; do \
		args=""; if [ -n "$$values" ]; then args="--values $(CHART)/$$values"; fi; \
		echo "== values.yaml $$values"; \
		helm lint --strict $(CHART) $$args && helm template ci $(CHART) $$args >/dev/null || exit 1; \
	done

pipeline:
	./scripts/run_local_pipeline.sh

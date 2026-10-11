VENV    ?= .venv
PYTHON  ?= python3
BIN     := $(VENV)/bin
IMAGE   ?= multi-cloud-app
VERSION ?= $(shell git rev-parse --short HEAD 2>/dev/null || echo dev)

.PHONY: install lint format test audit check run docker-build docker-run tofu-check pipeline

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

tofu-check:
	cd infra/azure && tofu fmt -check && tofu init -backend=false -input=false >/dev/null && tofu validate
	cd infra/gcp && tofu fmt -check && tofu init -backend=false -input=false >/dev/null && tofu validate

pipeline:
	./scripts/run_local_pipeline.sh

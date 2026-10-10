.PHONY: install test run docker-build

install:
	python3 -m venv .venv
	. .venv/bin/activate && pip install -r requirements.txt

test:
	PYTHONPATH=. pytest -q

run:
	PYTHONPATH=. python app/main.py

docker-build:
	docker build -t multi-cloud-app .

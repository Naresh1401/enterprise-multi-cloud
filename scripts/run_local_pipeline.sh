#!/usr/bin/env bash
# Runs the CI gates locally: lint, tests, dependency audit, image build and a
# container smoke test that checks the image reports the current commit.
# Set PYTHON to a 3.11+ interpreter, and HOST_PORT if port 8000 is taken.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

VERSION="$(git rev-parse --short HEAD 2>/dev/null || echo dev)"
IMAGE="multi-cloud-app:${VERSION}"
CONTAINER="multi-cloud-app-local"
HOST_PORT="${HOST_PORT:-8000}"
PYTHON="${PYTHON:-python3}"
REQUIRE_311='import sys; sys.exit(0 if sys.version_info >= (3, 11) else 1)'

if ! "$PYTHON" -c "$REQUIRE_311" 2>/dev/null; then
  echo "Python 3.11 or newer is required (${PYTHON} is $("$PYTHON" --version 2>&1))." >&2
  echo "Run with PYTHON=/path/to/python3.11 $0" >&2
  exit 1
fi

echo "[1/6] Preparing the virtual environment"
# Rebuild a virtual environment left over from an older interpreter
if [[ ! -x .venv/bin/python ]] || ! .venv/bin/python -c "$REQUIRE_311" 2>/dev/null; then
  "$PYTHON" -m venv --clear .venv
fi
.venv/bin/pip install --quiet --upgrade pip
.venv/bin/pip install --quiet -r requirements-dev.txt

echo "[2/6] Linting"
.venv/bin/ruff check .
.venv/bin/ruff format --check .

echo "[3/6] Running tests"
.venv/bin/pytest --cov

echo "[4/6] Auditing dependencies"
.venv/bin/pip-audit -r requirements.txt

echo "[5/6] Building ${IMAGE}"
docker build --build-arg APP_VERSION="$VERSION" --tag "$IMAGE" .

echo "[6/6] Smoke testing the container"
docker rm --force "$CONTAINER" >/dev/null 2>&1 || true
docker run --detach --name "$CONTAINER" --publish "${HOST_PORT}:8000" "$IMAGE" >/dev/null
trap 'docker rm --force "$CONTAINER" >/dev/null 2>&1 || true' EXIT

for _ in $(seq 1 30); do
  if body="$(curl --fail --silent "http://127.0.0.1:${HOST_PORT}/health")"; then
    reported="$(printf '%s' "$body" | python3 -c 'import json, sys; print(json.load(sys.stdin)["version"])')"
    if [[ "$reported" == "$VERSION" ]]; then
      echo "Healthy: ${body}"
      exit 0
    fi
    echo "The container reports version ${reported}, expected ${VERSION}" >&2
    exit 1
  fi
  sleep 1
done

docker logs "$CONTAINER" >&2
echo "The container did not become healthy" >&2
exit 1

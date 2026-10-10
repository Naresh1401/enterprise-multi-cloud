#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

echo "[1/5] Creating virtual environment..."
python3 -m venv .venv
source .venv/bin/activate

echo "[2/5] Installing Python dependencies..."
pip install --upgrade pip >/dev/null
pip install -r requirements.txt >/dev/null

echo "[3/5] Running tests..."
PYTHONPATH=. pytest -q

echo "[4/5] Building Docker image..."
docker build -t multi-cloud-app:local .

echo "[5/5] Running container and testing health..."
CONTAINER_ID="$(docker run -d -p 8000:8000 --name multi-cloud-app-local multi-cloud-app:local)"
trap 'echo "Cleaning up container..."; docker rm -f "$CONTAINER_ID" >/dev/null 2>&1 || true' EXIT

for i in {1..30}; do
  if curl -fsS http://localhost:8000/health >/tmp/multi_cloud_health.json 2>/dev/null; then
    echo "Health check passed"
    cat /tmp/multi_cloud_health.json
    exit 0
  fi
  sleep 1
done

echo "Health check failed"
exit 1

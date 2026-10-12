#!/usr/bin/env bash
# Checks a live deployment of the service end to end. Every deploy workflow runs it, and you can
# run it yourself against any deployment (it needs curl and jq):
#
#   scripts/verify-deployment.sh <base-url> <expected-version> [--write]
#   scripts/verify-deployment.sh https://multi-cloud-app-dev-abc123-uc.a.run.app 3f2c1ab... --write
#
# Checks, in order:
#   1. /health answers and reports <expected-version>, the commit SHA: the new code is serving.
#      Retried for WAIT_SECONDS (default 300) while the rollout finishes.
#   2. /ready answers 200 with "database": "ok": the service can query its database.
#   3. The security headers are set.
#   4. An unknown path answers a JSON 404.
#   5. GET /api/items answers: a read through the connection pool.
#   6. With --write: POST /api/items creates an item and GET /api/items/<id> reads it back.
#      This leaves the item in the database, so the workflows only write in dev.
#
# Prints one line per check, appends a table to $GITHUB_STEP_SUMMARY when it is set, and exits
# non-zero when any check fails.
set -euo pipefail

usage() {
  echo "usage: $0 <base-url> <expected-version> [--write]" >&2
  exit 2
}

if [ $# -lt 2 ] || [ $# -gt 3 ]; then usage; fi
base="${1%/}"
expected="$2"
write="${3:-}"
if [ -n "$write" ] && [ "$write" != --write ]; then usage; fi
wait_seconds="${WAIT_SECONDS:-300}"

workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"' EXIT

rows=()
failed=0
record() {
  # record <pass|fail> <check> <detail>
  rows+=("| $2 | $1 | $3 |")
  if [ "$1" != pass ]; then failed=1; fi
  printf '%-4s  %s: %s\n' "$1" "$2" "$3"
}

# GET or POST a path; writes the body to $workdir/body and prints the HTTP status ("000" when
# nothing answered)
request() {
  local method="$1" path="$2" data="${3:-}"
  local args=(--silent --max-time 10 --output "$workdir/body" --write-out '%{http_code}' --request "$method")
  if [ -n "$data" ]; then args+=(--header 'Content-Type: application/json' --data "$data"); fi
  curl "${args[@]}" "${base}${path}" || true
}

field() {
  jq -r "$1 // empty" "$workdir/body" 2>/dev/null || true
}

# 1. The new version is serving
deadline=$((SECONDS + wait_seconds))
version=""
while :; do
  status="$(request GET /health)"
  version="$(field .version)"
  if [ "$status" = 200 ] && [ "$version" = "$expected" ]; then break; fi
  if [ "$SECONDS" -ge "$deadline" ]; then break; fi
  echo "      waiting: /health answered ${status} with version '${version}'"
  sleep 10
done
if [ "$version" = "$expected" ]; then
  record pass "Serves the new version" "/health reports \`${expected}\`"
else
  record fail "Serves the new version" "/health reports '${version:-nothing}' after ${wait_seconds}s, expected ${expected}"
fi

# 2. The database answers
status="$(request GET /ready)"
database="$(field .database)"
if [ "$status" = 200 ] && [ "$database" = ok ]; then
  record pass "Database reachable" "/ready answers 200, database ok"
else
  record fail "Database reachable" "/ready answered ${status}, database '${database:-unknown}'"
fi

# 3. Security headers
headers="$(curl --silent --max-time 10 --head "${base}/health" | tr -d '\r' | tr '[:upper:]' '[:lower:]' || true)"
missing=()
for header in "x-content-type-options: nosniff" "x-frame-options: deny" "referrer-policy: no-referrer" "cache-control: no-store"; do
  if ! grep -qx "$header" <<<"$headers"; then missing+=("${header%%:*}"); fi
done
if [ "${#missing[@]}" -eq 0 ]; then
  record pass "Security headers" "nosniff, frame DENY, no-referrer, no-store"
else
  record fail "Security headers" "missing: ${missing[*]}"
fi

# 4. Errors are JSON
status="$(request GET /does-not-exist)"
if [ "$status" = 404 ] && [ "$(field .error)" = "not found" ]; then
  record pass "JSON errors" "unknown path answers a JSON 404"
else
  record fail "JSON errors" "unknown path answered ${status}"
fi

# 5. A read through the pool
status="$(request GET /api/items)"
if [ "$status" = 200 ] && jq -e '.items | type == "array"' "$workdir/body" >/dev/null 2>&1; then
  record pass "Database read" "GET /api/items lists $(jq '.items | length' "$workdir/body") items"
else
  record fail "Database read" "GET /api/items answered ${status}"
fi

# 6. A write and a read back
if [ "$write" = --write ]; then
  name="deploy check ${expected:0:12} $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  status="$(request POST /api/items "$(jq -cn --arg name "$name" '{name: $name}')")"
  id="$(field .id)"
  if [ "$status" = 201 ] && [ -n "$id" ]; then
    status="$(request GET "/api/items/${id}")"
    if [ "$status" = 200 ] && [ "$(field .name)" = "$name" ]; then
      record pass "Database write" "created item ${id} and read it back"
    else
      record fail "Database write" "created item ${id}, but reading it back answered ${status}"
    fi
  else
    record fail "Database write" "POST /api/items answered ${status}"
  fi
fi

if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  {
    echo "#### Checks against ${base}"
    echo "| Check | Result | Detail |"
    echo "| --- | --- | --- |"
    printf '%s\n' "${rows[@]}"
  } >> "$GITHUB_STEP_SUMMARY"
fi

exit "$failed"

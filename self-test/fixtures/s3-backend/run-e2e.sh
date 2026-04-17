#!/usr/bin/env bash
#
# run-e2e.sh — full roundtrip of scripts/state-{get,put}.sh against a
# localstack-backed DynamoDB. Exits 0 on success, non-zero on any mismatch.
#
# Flow:
#   1. Bring up localstack + create bucket/tables (setup-fixture.sh)
#   2. state-put.sh a known JSON blob into commander-active via the dynamodb
#      backend, pointed at localstack's endpoint
#   3. state-get.sh reads it back; compare JSON via jq
#   4. Teardown (docker compose down)
#
# If any step fails, the teardown still runs.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

cd "$SCRIPT_DIR"

# Pre-flight: docker must be available.
if ! command -v docker >/dev/null 2>&1; then
  echo "run-e2e: docker not on PATH — cannot run this test" >&2
  echo "run-e2e: (marked requires_docker in self-test/golden-cases.example.json)" >&2
  exit 2
fi
if ! docker info >/dev/null 2>&1; then
  echo "run-e2e: docker daemon not reachable — cannot run this test" >&2
  exit 2
fi
command -v aws >/dev/null 2>&1 || { echo "run-e2e: awscli required" >&2; exit 2; }
command -v jq >/dev/null 2>&1  || { echo "run-e2e: jq required" >&2; exit 2; }

cleanup() {
  local rc=$?
  echo
  echo "run-e2e: tearing down"
  "$SCRIPT_DIR/teardown-fixture.sh" >/dev/null 2>&1 || true
  exit "$rc"
}
trap cleanup EXIT INT TERM

# ---- Env for the adapters ----

export HYDRA_STATE_BACKEND=dynamodb
export HYDRA_AWS_ENDPOINT_URL="http://localhost:4566"
export HYDRA_AWS_REGION="us-east-1"
export HYDRA_S3_BUCKET="hydra-fixture-knowledge"
export HYDRA_S3_PREFIX="localstack-fixture"
export AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID:-test}"
export AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY:-test}"

echo "run-e2e: setting up localstack fixture"
"$SCRIPT_DIR/setup-fixture.sh"

# ---- Write ----

read -r -d '' PAYLOAD <<'JSON' || true
{
  "workers": [
    {"id": "w-e2e-1", "ticket": "fixture#1", "repo": "hydra", "tier": "T1", "started_at": "2026-04-16T00:00:00Z", "subagent_type": "worker-implementation"}
  ],
  "last_updated": "2026-04-16T00:00:00Z"
}
JSON

echo "run-e2e: state-put.sh --key active  (dynamodb backend, localstack endpoint)"
printf '%s' "$PAYLOAD" | "$REPO_ROOT/scripts/state-put.sh" --key active

# ---- Read ----

echo "run-e2e: state-get.sh --key active"
got="$("$REPO_ROOT/scripts/state-get.sh" --key active)"

# ---- Compare ----

expected="$(printf '%s' "$PAYLOAD" | jq -c .)"
actual="$(printf '%s' "$got" | jq -c .)"

if [[ "$expected" != "$actual" ]]; then
  echo "run-e2e: ROUNDTRIP FAILED" >&2
  echo "  expected: $expected" >&2
  echo "  actual:   $actual" >&2
  exit 1
fi

echo "run-e2e: roundtrip OK"
echo "run-e2e: PASS"

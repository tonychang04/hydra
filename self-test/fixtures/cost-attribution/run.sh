#!/usr/bin/env bash
#
# self-test fixture driver for the cost-attribution consumers (ticket #195).
#
# Exercises scripts/trace-cost.sh + scripts/cost-rollup.sh + scripts/cost-per-pr.sh
# end to end, offline (bash + jq, no network/docker):
#   1. The committed sample-trace.jsonl is valid JSONL.
#   2. The committed logs/*.json fixtures are valid JSON objects.
#   3. Delegates to scripts/test-cost.sh for the full assertion suite
#      (pricing math, per-model rollup, log merge, cost-per-PR join with the
#      offline --merged-prs override, divide-by-zero guard).
#
# Prints SMOKE_OK on success; non-zero exit on any failure.
#
# Invoked by self-test/golden-cases.example.json case "cost-attribution-script".
# Spec: docs/specs/2026-05-21-per-ticket-cost-and-cost-per-pr.md
set -euo pipefail
export NO_COLOR=1

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd -- "$SCRIPT_DIR/../../.." && pwd)"
FIXTURE="$SCRIPT_DIR/sample-trace.jsonl"
LOGS="$SCRIPT_DIR/logs"
MERGED="$SCRIPT_DIR/merged-prs.txt"
TEST="$ROOT_DIR/scripts/test-cost.sh"

command -v jq >/dev/null 2>&1 || { echo "FAIL: jq required" >&2; exit 1; }
[[ -f "$FIXTURE" ]] || { echo "FAIL: missing fixture $FIXTURE" >&2; exit 1; }
[[ -d "$LOGS" ]]    || { echo "FAIL: missing logs dir $LOGS" >&2; exit 1; }
[[ -f "$MERGED" ]]  || { echo "FAIL: missing merged list $MERGED" >&2; exit 1; }
[[ -x "$TEST" ]]    || { echo "FAIL: $TEST not executable" >&2; exit 1; }

# 1. Committed trace fixture is structurally sound.
if ! jq empty "$FIXTURE" >/dev/null 2>&1; then
  echo "FAIL: sample-trace.jsonl is not valid JSONL" >&2
  exit 1
fi

# 2. Every committed log fixture is a valid JSON object with a cost_usd.
for lf in "$LOGS"/*.json; do
  if ! jq -e 'type == "object" and has("cost_usd")' "$lf" >/dev/null 2>&1; then
    echo "FAIL: $lf is not a JSON object with cost_usd" >&2
    exit 1
  fi
done

# 3. Full assertion suite.
if ! "$TEST" >/dev/null 2>&1; then
  echo "FAIL: scripts/test-cost.sh assertions failed; run it directly for detail" >&2
  exit 1
fi

echo "SMOKE_OK"

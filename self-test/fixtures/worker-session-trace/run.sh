#!/usr/bin/env bash
#
# self-test fixture driver for the worker session-trace substrate (ticket #197).
#
# Exercises scripts/trace-append.sh + scripts/trace-analyze.sh end to end,
# offline (bash + jq, no network/docker):
#   1. The committed sample-trace.jsonl is valid JSONL with the five required
#      top-level keys on every line.
#   2. Delegates to scripts/test-trace.sh for the full assertion suite
#      (append round-trip, content gating, durations/errors/tools/summary).
#
# Prints SMOKE_OK on success; non-zero exit on any failure.
#
# Invoked by self-test/golden-cases.example.json case "worker-session-trace-script".
# Spec: docs/specs/2026-05-21-worker-session-trace.md

set -euo pipefail
export NO_COLOR=1

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd -- "$SCRIPT_DIR/../../.." && pwd)"
FIXTURE="$SCRIPT_DIR/sample-trace.jsonl"
TEST="$ROOT_DIR/scripts/test-trace.sh"

command -v jq >/dev/null 2>&1 || { echo "FAIL: jq required" >&2; exit 1; }
[[ -f "$FIXTURE" ]] || { echo "FAIL: missing fixture $FIXTURE" >&2; exit 1; }
[[ -x "$TEST" ]]    || { echo "FAIL: $TEST not executable" >&2; exit 1; }

# 1. Committed fixture is structurally sound.
if ! jq empty "$FIXTURE" >/dev/null 2>&1; then
  echo "FAIL: sample-trace.jsonl is not valid JSONL" >&2
  exit 1
fi

# Every line must carry the five required top-level keys.
bad_lines="$(jq -c 'select((["attrs","kind","parent_span_id","span_id","ts"] - (keys)) != []) | .span_id' "$FIXTURE")"
if [[ -n "$bad_lines" ]]; then
  echo "FAIL: lines missing required keys (span_ids): $bad_lines" >&2
  exit 1
fi

# 2. Full assertion suite.
if ! "$TEST" >/dev/null 2>&1; then
  echo "FAIL: scripts/test-trace.sh assertions failed; run it directly for detail" >&2
  exit 1
fi

echo "SMOKE_OK"

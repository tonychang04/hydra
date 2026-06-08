#!/usr/bin/env bash
#
# run.sh — self-test fixture for anti-drift parallelism (ticket #257).
#
# Proves scripts/plan-parallel-batch.sh deterministically partitions a candidate
# ticket batch into a parallel-safe set (disjoint footprints) + serialized groups
# (overlapping footprints), report-only, offline. The headline assertion is the
# ticket's acceptance criterion: 3 tickets, 2 sharing a file -> parallel{the
# disjoint one} + serialize{the 2 overlapping}.
#
# No network / no docker / no Claude auth. Delegates the full assertion matrix to
# scripts/test-plan-parallel-batch.sh (33 assertions) and adds an explicit,
# self-contained re-statement of the acceptance criterion so this fixture is
# legible on its own.
#
# Run from anywhere:
#   bash self-test/fixtures/anti-drift-parallelism/run.sh
#
# Exit 0 on pass, 1 on any failure.
#
# Spec: docs/specs/2026-06-07-anti-drift-parallelism.md

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/../../.." && pwd)"
HELPER="$REPO_ROOT/scripts/plan-parallel-batch.sh"
TEST_DRIVER="$REPO_ROOT/scripts/test-plan-parallel-batch.sh"

fail_count=0
fail() { echo "FAIL: $*" >&2; fail_count=$((fail_count + 1)); }
pass() { echo "  pass: $*"; }

# --- Test 1: helper present + bash -n clean ----------------------------------
echo "[anti-drift-parallelism] test 1: helper present and syntax-clean"
if [[ ! -f "$HELPER" ]]; then
  fail "helper missing at $HELPER"
elif ! bash -n "$HELPER" 2>/dev/null; then
  fail "helper is not bash -n clean"
else
  pass "scripts/plan-parallel-batch.sh present + bash -n clean"
fi

# --- Test 2: THE acceptance criterion (3 tickets, 2 share a file) ------------
echo "[anti-drift-parallelism] test 2: 3 tickets, 2 share a file -> parallel + serialize"
batch='{
  "tickets": [
    { "number": 301, "title": "Add --json to status", "body": "edits scripts/status.sh only" },
    { "number": 302, "title": "Fix interval guard", "body": "edits scripts/autopickup-tick.sh" },
    { "number": 303, "title": "Add gc marker", "body": "also edits scripts/autopickup-tick.sh" }
  ]
}'
set +e
out="$(printf '%s' "$batch" | NO_COLOR=1 bash "$HELPER" --json 2>&1)"; ec=$?
set -e

if [[ "$ec" -ne 0 ]]; then
  fail "helper exited $ec (expected 0); output: $out"
elif [[ "$(printf '%s' "$out" | jq -c '.parallel')" != "[301]" ]]; then
  fail "expected parallel == [301], got $(printf '%s' "$out" | jq -c '.parallel')"
elif [[ "$(printf '%s' "$out" | jq -c '.serialize_groups[0].group')" != "[302,303]" ]]; then
  fail "expected serialize group [302,303], got $(printf '%s' "$out" | jq -c '.serialize_groups[0].group')"
elif ! printf '%s' "$out" | jq -e '.serialize_groups[0].shared | index("scripts/autopickup-tick.sh")' >/dev/null 2>&1; then
  fail "expected shared to name scripts/autopickup-tick.sh, got $(printf '%s' "$out" | jq -c '.serialize_groups[0].shared')"
else
  pass "parallel{301} + serialize{302,303 share scripts/autopickup-tick.sh}"
fi

# --- Test 3: report-only — helper never mutates state / never spawns ----------
echo "[anti-drift-parallelism] test 3: helper is report-only (no spawn / mutate verbs)"
# A grep guard: the helper must not call gh pr/issue create, Agent spawns, or
# write into state/. (Mentions inside comments/docstrings are fine — we check for
# actual invocation patterns.)
if grep -nE '(^|[^#].*)(gh (pr|issue) (create|edit|merge)|TaskStop|>[[:space:]]*"?\$?\{?(STATE_DIR|.*state/))' "$HELPER" >/dev/null 2>&1; then
  fail "helper appears to mutate/spawn — it must be report-only"
else
  pass "no spawn / state-mutation verbs in the helper"
fi

# --- Test 4: determinism (same input twice -> identical, modulo timestamp) ----
echo "[anti-drift-parallelism] test 4: deterministic output"
a="$(printf '%s' "$batch" | NO_COLOR=1 bash "$HELPER" --json | jq 'del(.generated_at)')"
b="$(printf '%s' "$batch" | NO_COLOR=1 bash "$HELPER" --json | jq 'del(.generated_at)')"
if [[ "$a" == "$b" ]]; then
  pass "byte-identical output across runs"
else
  fail "non-deterministic output"
fi

# --- Test 5: delegate to the full assertion driver ---------------------------
echo "[anti-drift-parallelism] test 5: full assertion driver (33 assertions)"
if [[ ! -f "$TEST_DRIVER" ]]; then
  fail "test driver missing at $TEST_DRIVER"
elif NO_COLOR=1 bash "$TEST_DRIVER" >/dev/null 2>&1; then
  pass "scripts/test-plan-parallel-batch.sh all assertions pass"
else
  fail "scripts/test-plan-parallel-batch.sh reported failures"
fi

# --- Summary -----------------------------------------------------------------
if (( fail_count == 0 )); then
  echo "[anti-drift-parallelism] ALL TESTS PASS"
  exit 0
else
  echo "[anti-drift-parallelism] $fail_count test(s) failed" >&2
  exit 1
fi

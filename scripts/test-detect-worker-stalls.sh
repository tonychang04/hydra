#!/usr/bin/env bash
#
# test-detect-worker-stalls.sh — regression test for scripts/detect-worker-stalls.sh.
#
# Self-contained: builds a fixture active.json + logs in a temp dir, runs the
# subject with a fixed --now for determinism, and asserts on stdout / the jsonl.
# No network, no real GitHub, no real worktrees. Style matches
# scripts/test-retro-metrics.sh.
#
# Spec: docs/specs/2026-06-18-worker-stall-observability.md (ticket #306).

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SUBJECT="$SCRIPT_DIR/detect-worker-stalls.sh"

if [[ ! -x "$SUBJECT" ]]; then
  echo "test-detect-worker-stalls: $SUBJECT not found/executable" >&2
  exit 2
fi

if [[ -t 1 ]] && [[ "${NO_COLOR:-}" != "1" ]]; then
  C_GREEN=$'\033[32m'; C_RED=$'\033[31m'; C_DIM=$'\033[2m'; C_RESET=$'\033[0m'
else
  C_GREEN=''; C_RED=''; C_DIM=''; C_RESET=''
fi

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ${C_GREEN}PASS${C_RESET} $1"; }
bad() { FAIL=$((FAIL+1)); echo "  ${C_RED}FAIL${C_RESET} $1"; [[ -n "${2:-}" ]] && echo "       ${C_DIM}$2${C_RESET}"; }

# assert_eq <actual> <expected> <label>
assert_eq() {
  if [[ "$1" == "$2" ]]; then ok "$3"; else bad "$3" "expected '$2', got '$1'"; fi
}
assert_contains() {
  if grep -qF -- "$2" <<<"$1"; then ok "$3"; else bad "$3" "expected to find: $2"; fi
}

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

NOW="2026-06-18T12:00:00Z"   # fixed "now" for determinism

# -----------------------------------------------------------------------------
echo "Test 1: empty active.json → 0 stalls, exit 0"
# -----------------------------------------------------------------------------
mkdir -p "$TMP/t1/state" "$TMP/t1/logs"
echo '{"workers":[]}' > "$TMP/t1/state/active.json"
set +e
out="$("$SUBJECT" --json --no-log --state-dir "$TMP/t1/state" --logs-dir "$TMP/t1/logs" --now "$NOW")"
rc=$?
set -e
assert_eq "$rc" "0" "exit 0 on empty active.json"
assert_eq "$(printf '%s' "$out" | jq -r '.stall_count')" "0" "stall_count == 0"
assert_eq "$(printf '%s' "$out" | jq -r '.stalls | length')" "0" "stalls array empty"

# -----------------------------------------------------------------------------
echo "Test 2: one stale RUNNING worker → 1 stall flagged"
# -----------------------------------------------------------------------------
mkdir -p "$TMP/t2/state" "$TMP/t2/logs"
# started 30 min before NOW (2026-06-18T11:30:00Z) → idle 30m > 12m threshold.
cat > "$TMP/t2/state/active.json" <<'JSON'
{"workers":[
  {"id":"w-1","ticket":"tonychang04/hydra#306","repo":"tonychang04/hydra",
   "tier":"T2","started_at":"2026-06-18T11:30:00Z","subagent_type":"worker-implementation",
   "status":"running"}
]}
JSON
set +e
out="$("$SUBJECT" --json --no-log --state-dir "$TMP/t2/state" --logs-dir "$TMP/t2/logs" --now "$NOW")"
rc=$?
set -e
assert_eq "$rc" "0" "exit 0 with a stale worker"
assert_eq "$(printf '%s' "$out" | jq -r '.stall_count')" "1" "stall_count == 1"
assert_eq "$(printf '%s' "$out" | jq -r '.stalls[0].verdict')" "stalled" "verdict == stalled"
assert_eq "$(printf '%s' "$out" | jq -r '.stalls[0].worker_id')" "w-1" "worker_id == w-1"
assert_eq "$(printf '%s' "$out" | jq -r '.stalls[0].idle_min')" "30" "idle_min == 30"

# -----------------------------------------------------------------------------
echo "Test 3: worker UNDER threshold → not flagged"
# -----------------------------------------------------------------------------
mkdir -p "$TMP/t3/state" "$TMP/t3/logs"
# started 5 min before NOW → idle 5m < 12m threshold.
cat > "$TMP/t3/state/active.json" <<'JSON'
{"workers":[
  {"id":"w-2","ticket":"x#1","repo":"x","tier":"T1",
   "started_at":"2026-06-18T11:55:00Z","subagent_type":"worker-implementation",
   "status":"running"}
]}
JSON
out="$("$SUBJECT" --json --no-log --state-dir "$TMP/t3/state" --logs-dir "$TMP/t3/logs" --now "$NOW")"
assert_eq "$(printf '%s' "$out" | jq -r '.stall_count')" "0" "under-threshold worker not flagged"

# -----------------------------------------------------------------------------
echo "Test 4: paused-on-question worker (old) → NOT flagged"
# -----------------------------------------------------------------------------
mkdir -p "$TMP/t4/state" "$TMP/t4/logs"
cat > "$TMP/t4/state/active.json" <<'JSON'
{"workers":[
  {"id":"w-3","ticket":"y#2","repo":"y","tier":"T2",
   "started_at":"2026-06-18T09:00:00Z","subagent_type":"worker-implementation",
   "status":"paused-on-question"},
  {"id":"w-4","ticket":"y#3","repo":"y","tier":"T2",
   "started_at":"2026-06-18T09:00:00Z","subagent_type":"worker-implementation",
   "status":"paused_on_question"}
]}
JSON
out="$("$SUBJECT" --json --no-log --state-dir "$TMP/t4/state" --logs-dir "$TMP/t4/logs" --now "$NOW")"
assert_eq "$(printf '%s' "$out" | jq -r '.stall_count')" "0" "paused workers (both spellings) not flagged"
assert_eq "$(printf '%s' "$out" | jq -r '.active_workers')" "2" "active_workers still counts paused"

# -----------------------------------------------------------------------------
echo "Test 5: default (no --no-log) appends one jsonl event per stall"
# -----------------------------------------------------------------------------
mkdir -p "$TMP/t5/state" "$TMP/t5/logs"
cp "$TMP/t2/state/active.json" "$TMP/t5/state/active.json"
out="$("$SUBJECT" --json --state-dir "$TMP/t5/state" --logs-dir "$TMP/t5/logs" --now "$NOW")"
logf="$TMP/t5/logs/stalls-2026-06.jsonl"
if [[ -f "$logf" ]]; then ok "jsonl event log created"; else bad "jsonl event log created" "missing $logf"; fi
assert_eq "$(wc -l < "$logf" | tr -d ' ')" "1" "exactly one event line written"
assert_eq "$(jq -r '.verdict' < "$logf")" "stalled" "event verdict == stalled"
assert_eq "$(jq -r '.worker_id' < "$logf")" "w-1" "event worker_id == w-1"
assert_contains "$(jq -r 'keys|join(",")' < "$logf")" "idle_min" "event has idle_min field"
assert_contains "$(jq -r 'keys|join(",")' < "$logf")" "ts" "event has ts field"

# -----------------------------------------------------------------------------
echo "Test 6: --no-log suppresses the jsonl write"
# -----------------------------------------------------------------------------
mkdir -p "$TMP/t6/state" "$TMP/t6/logs"
cp "$TMP/t2/state/active.json" "$TMP/t6/state/active.json"
"$SUBJECT" --json --no-log --state-dir "$TMP/t6/state" --logs-dir "$TMP/t6/logs" --now "$NOW" >/dev/null
if [[ -f "$TMP/t6/logs/stalls-2026-06.jsonl" ]]; then
  bad "--no-log writes nothing" "jsonl was created despite --no-log"
else
  ok "--no-log writes nothing"
fi

# -----------------------------------------------------------------------------
echo "Test 7: --trends emits a top-N failure-mode list"
# -----------------------------------------------------------------------------
mkdir -p "$TMP/t7/state" "$TMP/t7/logs"
# failed-result logs (within window via completed_at).
cat > "$TMP/t7/logs/100.json" <<'JSON'
{"ticket":"a#1","result":"failed","completed_at":"2026-06-17T10:00:00Z"}
JSON
cat > "$TMP/t7/logs/101.json" <<'JSON'
{"ticket":"a#2","result":"failed","completed_at":"2026-06-16T10:00:00Z"}
JSON
cat > "$TMP/t7/logs/102.json" <<'JSON'
{"ticket":"a#3","result":"merged","completed_at":"2026-06-15T10:00:00Z","surprises":["browse tool flaky reset"]}
JSON
# a stall jsonl event (counts as worker-stall).
cat > "$TMP/t7/logs/stalls-2026-06.jsonl" <<'JSON'
{"ts":"2026-06-17T11:00:00Z","worker_id":"w-9","ticket":"a#4","repo":"a","idle_min":40,"verdict":"stalled"}
JSON
out="$("$SUBJECT" --trends --json --logs-dir "$TMP/t7/logs" --state-dir "$TMP/t7/state" --now "$NOW" --since-days 30)"
assert_eq "$(printf '%s' "$out" | jq -r '.trends | length >= 1')" "true" "--trends emits at least one mode"
# 'failed' should appear with count 2 (two failed logs).
assert_eq "$(printf '%s' "$out" | jq -r '.trends[] | select(.mode=="failed") | .count')" "2" "failed mode counted twice"
assert_eq "$(printf '%s' "$out" | jq -r '.trends[] | select(.mode=="worker-stall") | .count')" "1" "worker-stall counted once"

# -----------------------------------------------------------------------------
echo "Test 8: human (non-JSON) output renders cleanly for a stall"
# -----------------------------------------------------------------------------
human="$("$SUBJECT" --no-log --state-dir "$TMP/t2/state" --logs-dir "$TMP/t2/logs" --now "$NOW")"
assert_contains "$human" "stalls: 1" "human report shows stall count"
assert_contains "$human" "rescue-worker.sh --probe" "human report points to rescue-worker for actuation"

# -----------------------------------------------------------------------------
echo "Test 9: usage error on bad flag → exit 2"
# -----------------------------------------------------------------------------
set +e
"$SUBJECT" --bogus >/dev/null 2>&1; rc=$?
set -e
assert_eq "$rc" "2" "unknown flag exits 2"

# -----------------------------------------------------------------------------
echo
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  ${C_GREEN}${PASS} passed${C_RESET}, ${C_RED}${FAIL} failed${C_RESET}"
[[ "$FAIL" -eq 0 ]] || exit 1

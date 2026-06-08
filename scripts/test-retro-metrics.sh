#!/usr/bin/env bash
#
# test-retro-metrics.sh — regression test for scripts/retro-metrics.sh.
#
# Self-contained: builds fixture logs + a citations file in a temp dir, runs
# the subject with a fixed --now for determinism, and asserts on stdout. No
# network, no real GitHub. Style matches scripts/test-retro-file-proposed-edits.sh.
#
# Spec: docs/specs/2026-06-08-retro-per-worker-trend-metrics.md (ticket #284).

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SUBJECT="$SCRIPT_DIR/retro-metrics.sh"

if [[ ! -x "$SUBJECT" ]]; then
  echo "test-retro-metrics: $SUBJECT not found/executable" >&2
  exit 2
fi

if [[ -t 1 ]] && [[ "${NO_COLOR:-}" != "1" ]]; then
  C_GREEN=$'\033[32m'; C_RED=$'\033[31m'; C_DIM=$'\033[2m'
  C_BOLD=$'\033[1m'; C_RESET=$'\033[0m'
else
  C_GREEN=''; C_RED=''; C_DIM=''; C_BOLD=''; C_RESET=''
fi

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "  ${C_GREEN}PASS${C_RESET} $1"; }
bad()  { FAIL=$((FAIL+1)); echo "  ${C_RED}FAIL${C_RESET} $1"; [[ -n "${2:-}" ]] && echo "       ${C_DIM}$2${C_RESET}"; }

# assert_contains <haystack> <needle> <label>
assert_contains() {
  if grep -qF -- "$2" <<<"$1"; then ok "$3"; else bad "$3" "expected to find: $2"; fi
}
# assert_absent <haystack> <needle> <label>
assert_absent() {
  if grep -qF -- "$2" <<<"$1"; then bad "$3" "did NOT expect: $2"; else ok "$3"; fi
}

WORK="$(mktemp -d -t retro-metrics-test.XXXXXX)"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

LOGS="$WORK/logs"; mkdir -p "$LOGS"
CIT="$WORK/citations.json"
NOW="2026-06-08T12:00:00Z"   # anchor; window = [2026-06-01T12:00Z, 2026-06-08T12:00Z]

# --- fixtures ---------------------------------------------------------------

# In-window: hydra merged
cat > "$LOGS/200.json" <<'J'
{"ticket":"hydra#200","repo":"tonychang04/hydra","result":"merged","worker_type":"worker-implementation","wall_clock_minutes":10,"completed_at":"2026-06-05T10:00:00Z"}
J
# In-window: hydra stuck (via status=failed)
cat > "$LOGS/201.json" <<'J'
{"ticket":"hydra#201","repo":"tonychang04/hydra","result":"stuck","status":"failed","worker_type":"worker-implementation","wall_clock_minutes":4,"completed_at":"2026-06-06T10:00:00Z","surprises":["flaky-tool: browse hung"]}
J
# In-window: sdk pr_opened, review worker, explicit flaky_tool
cat > "$LOGS/202.json" <<'J'
{"ticket":"sdk#9","repo":"insforge/sdk","result":"pr_opened","worker_type":"worker-review","wall_clock_minutes":3,"completed_at":"2026-06-07T01:00:00Z","flaky_tool":"browse"}
J
# OUT of window (too old): must be excluded
cat > "$LOGS/199.json" <<'J'
{"ticket":"hydra#199","repo":"tonychang04/hydra","result":"merged","worker_type":"worker-implementation","wall_clock_minutes":99,"completed_at":"2026-05-01T10:00:00Z"}
J
# Non-JSON garbage: must be skipped without crashing
echo "not json {" > "$LOGS/junk.json"

cat > "$CIT" <<'J'
{"citations":{
  "learnings-hydra.md#\"git -C worktree discipline\"":{"count":5,"last_cited":"2026-06-07","tickets":["a","b","c","d","e"],"promotion_threshold_reached":true},
  "learnings-hydra.md#\"fresh this week\"":{"count":2,"last_cited":"2026-06-03","tickets":["q","r"],"promotion_threshold_reached":false},
  "learnings-hydra.md#\"stale entry\"":{"count":40,"last_cited":"2026-01-01","tickets":["z"],"promotion_threshold_reached":true},
  "_comment":"meta key — must be skipped"
}}
J

echo "${C_BOLD}retro-metrics.sh${C_RESET}"

OUT="$(bash "$SUBJECT" --logs-dir "$LOGS" --citations-file "$CIT" --now "$NOW")"

# --- Test 1: per-repo breakdown ---------------------------------------------
echo "Test 1: per-repo contribution"
assert_contains "$OUT" "## Per-repo contribution" "section header present"
assert_contains "$OUT" "| tonychang04/hydra | 1 | 0 | 1 | 50% | 50% |" "hydra row: 1 merged, 1 stuck, 50%/50%"
assert_contains "$OUT" "| insforge/sdk | 0 | 1 | 0 | 0% | 0% |" "sdk row: 1 pr_opened, 0 stuck"

# --- Test 2: per-worker breakdown -------------------------------------------
echo "Test 2: per-worker contribution"
assert_contains "$OUT" "## Per-worker contribution" "section header present"
# worker-implementation: 2 completions, 1 shipped, 1 stuck, 10+4=14 wall
assert_contains "$OUT" "| worker-implementation | 2 | 1 | 1 | 14 |" "impl worker row: 2 total, 1 shipped, 1 stuck, 14 min"
assert_contains "$OUT" "| worker-review | 1 | 1 | 0 | 3 |" "review worker row: 1 shipped, 3 min"

# --- Test 3: window filtering -----------------------------------------------
echo "Test 3: window filtering"
assert_absent "$OUT" "99" "out-of-window log (wall=99) excluded"

# --- Test 4: citation deltas ------------------------------------------------
echo "Test 4: citation leaderboard (active this week)"
assert_contains "$OUT" "## Citation leaderboard (active this week)" "section header present"
assert_contains "$OUT" 'git -C worktree discipline' "in-window high-count entry surfaced"
assert_contains "$OUT" 'fresh this week' "in-window low-count entry surfaced"
assert_absent  "$OUT" 'stale entry' "out-of-window citation excluded despite high count"
assert_absent  "$OUT" '_comment' "meta key excluded"
# sort: high-count entry must appear before the low-count one
hi_line="$(grep -n 'git -C worktree discipline' <<<"$OUT" | head -1 | cut -d: -f1)"
lo_line="$(grep -n 'fresh this week' <<<"$OUT" | head -1 | cut -d: -f1)"
if [[ -n "$hi_line" && -n "$lo_line" && "$hi_line" -lt "$lo_line" ]]; then
  ok "sorted by count desc (5 before 2)"
else
  bad "sorted by count desc (5 before 2)" "hi_line=$hi_line lo_line=$lo_line"
fi

# --- Test 5: flaky-tool hotspots --------------------------------------------
echo "Test 5: flaky-tool hotspots"
assert_contains "$OUT" "## Flaky-tool hotspots" "section header present"
# browse appears via surprises (201) + flaky_tool (202) = 2
assert_contains "$OUT" "| browse | 2 |" "browse grouped to count 2 across surprises + flaky_tool"

# --- Test 6: empty window ---------------------------------------------------
echo "Test 6: empty window"
EMPTY_LOGS="$WORK/empty-logs"; mkdir -p "$EMPTY_LOGS"
EMPTY_CIT="$WORK/empty-cit.json"; echo '{"citations":{}}' > "$EMPTY_CIT"
if EOUT="$(bash "$SUBJECT" --logs-dir "$EMPTY_LOGS" --citations-file "$EMPTY_CIT" --now "$NOW")"; then
  ok "exit 0 on empty window"
else
  bad "exit 0 on empty window" "non-zero exit"
fi
none_count="$(grep -c '_none in window_' <<<"$EOUT" || true)"
if [[ "$none_count" -eq 4 ]]; then
  ok "all 4 sections print _none in window_"
else
  bad "all 4 sections print _none in window_" "got $none_count"
fi

# --- Test 7: determinism ----------------------------------------------------
echo "Test 7: determinism"
OUT_A="$(bash "$SUBJECT" --logs-dir "$LOGS" --citations-file "$CIT" --now "$NOW")"
OUT_B="$(bash "$SUBJECT" --logs-dir "$LOGS" --citations-file "$CIT" --now "$NOW")"
if [[ "$OUT_A" == "$OUT_B" ]]; then
  ok "same inputs => byte-identical stdout"
else
  bad "same inputs => byte-identical stdout" "outputs differ"
fi

# --- summary ----------------------------------------------------------------
echo
echo "${C_BOLD}Total: $((PASS+FAIL))  ${C_GREEN}PASS: $PASS${C_RESET}  ${C_RED}FAIL: $FAIL${C_RESET}"
[[ "$FAIL" -eq 0 ]] || exit 1

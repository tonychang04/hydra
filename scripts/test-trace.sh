#!/usr/bin/env bash
#
# test-trace.sh — regression test for the worker session-trace substrate:
#   scripts/trace-append.sh   (emit one span event)
#   scripts/trace-analyze.sh  (jq analysis: durations / errors / tools / summary)
#
# Exercises (all offline, bash + jq, no network/docker):
#   APPEND
#     - writes exactly one valid-JSON line with the five required top-level keys
#     - copies kind into attrs."gen_ai.operation.name"
#     - echoes the span_id (reusable as --parent-span-id / to pair start+end)
#     - a start+end pair shares one span_id
#     - integer attr values are stored as JSON numbers (token counts)
#     - content gating: gen_ai.prompt dropped by default (+ stderr warning),
#       kept with --with-content
#     - empty-attr invocation still writes a valid line (empty-array guard)
#     - missing --kind / --ticket → exit 2, nothing written
#   ANALYZE (against the committed sample-trace.jsonl fixture)
#     - durations: complete spans report ms; half-open span → "incomplete";
#       phase-less event → "instant"
#     - errors: exactly the one error.type span is listed
#     - tools: tool sequence matches fixture order
#     - summary --json: counts match
#     - stdin input works
#     - missing file → exit 2
#
# Style: matches scripts/test-promote-citations.sh — bash, colored output,
# pass/fail counter, mktemp fixtures, no external harness.
#
# Spec: docs/specs/2026-05-21-worker-session-trace.md (ticket #197)

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"
APPEND="$SCRIPT_DIR/trace-append.sh"
ANALYZE="$SCRIPT_DIR/trace-analyze.sh"
FIXTURE="$ROOT_DIR/self-test/fixtures/worker-session-trace/sample-trace.jsonl"

for f in "$APPEND" "$ANALYZE"; do
  [[ -x "$f" ]] || { echo "test-trace: $f not found or not executable" >&2; exit 2; }
done
[[ -f "$FIXTURE" ]] || { echo "test-trace: fixture missing: $FIXTURE" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "test-trace: jq required" >&2; exit 2; }

if [[ -t 1 ]] && [[ "${NO_COLOR:-}" != "1" ]]; then
  C_GREEN=$'\033[32m'; C_RED=$'\033[31m'; C_BOLD=$'\033[1m'; C_RESET=$'\033[0m'
else
  C_GREEN=""; C_RED=""; C_BOLD=""; C_RESET=""
fi

passed=0
failed=0
say() { printf "\n${C_BOLD}▸ %s${C_RESET}\n" "$*"; }
ok()  { printf "  ${C_GREEN}✓${C_RESET} %s\n" "$*"; passed=$((passed + 1)); }
bad() { printf "  ${C_RED}✗${C_RESET} %s\n" "$*"; failed=$((failed + 1)); }

# assert_eq <label> <expected> <actual>
assert_eq() {
  if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1 (expected [$2], got [$3])"; fi
}

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

# =============================================================================
say "APPEND: single valid line + required keys"
# =============================================================================
sid="$("$APPEND" --ticket t1 --kind execute_tool --trace-dir "$tmpdir" --attr gen_ai.tool.name=Bash)"
file="$tmpdir/t1.jsonl"
assert_eq "exactly one line written" "1" "$(wc -l < "$file" | tr -d ' ')"
if jq empty "$file" >/dev/null 2>&1; then ok "line is valid JSON"; else bad "line is not valid JSON"; fi
keys="$(jq -rc '[keys[]] | sort | join(",")' "$file")"
assert_eq "five required top-level keys" "attrs,kind,parent_span_id,span_id,ts" "$keys"
assert_eq "kind copied to gen_ai.operation.name" "execute_tool" "$(jq -r '.attrs."gen_ai.operation.name"' "$file")"
assert_eq "span_id echoed matches written line" "$sid" "$(jq -r '.span_id' "$file")"
assert_eq "no-parent root → null parent_span_id" "null" "$(jq -r '.parent_span_id' "$file")"

# =============================================================================
say "APPEND: start/end pair shares one span_id; parent reuse"
# =============================================================================
root="$("$APPEND" --ticket t2 --kind invoke_agent --trace-dir "$tmpdir")"
st="$("$APPEND" --ticket t2 --kind execute_tool --parent-span-id "$root" --phase start --trace-dir "$tmpdir" --attr gen_ai.tool.name=Bash)"
"$APPEND" --ticket t2 --kind execute_tool --span-id "$st" --parent-span-id "$root" --phase end --trace-dir "$tmpdir" --attr gen_ai.tool.name=Bash >/dev/null
f2="$tmpdir/t2.jsonl"
pair_count="$(jq -rc --arg s "$st" 'select(.span_id == $s) | .span_id' "$f2" | wc -l | tr -d ' ')"
assert_eq "start+end share one span_id (2 events)" "2" "$pair_count"
assert_eq "child references parent span_id" "$root" "$(jq -r --arg s "$st" 'select(.span_id==$s and .attrs.phase=="start") | .parent_span_id' "$f2")"

# =============================================================================
say "APPEND: integer attrs are numeric; content gating"
# =============================================================================
warn="$tmpdir/warn.txt"
"$APPEND" --ticket t3 --kind chat --trace-dir "$tmpdir" \
  --attr gen_ai.usage.input_tokens=1200 --attr gen_ai.usage.output_tokens=340 \
  --attr gen_ai.prompt="secret prompt" >/dev/null 2>"$warn"
f3="$tmpdir/t3.jsonl"
assert_eq "input_tokens stored as number" "number" "$(jq -r '.attrs."gen_ai.usage.input_tokens"|type' "$f3")"
assert_eq "output_tokens present (all attrs processed)" "340" "$(jq -r '.attrs."gen_ai.usage.output_tokens"' "$f3")"
assert_eq "gen_ai.prompt dropped by default" "null" "$(jq -r '.attrs."gen_ai.prompt" // "null"' "$f3")"
if grep -q "dropping sensitive attr 'gen_ai.prompt'" "$warn"; then ok "stderr warns on dropped content"; else bad "no drop warning on stderr"; fi

"$APPEND" --ticket t4 --kind chat --trace-dir "$tmpdir" --with-content --attr gen_ai.prompt="kept prompt" >/dev/null
assert_eq "gen_ai.prompt kept with --with-content" "kept prompt" "$(jq -r '.attrs."gen_ai.prompt"' "$tmpdir/t4.jsonl")"

# HYDRA_TRACE_CONTENT=1 env opt-in is equivalent to --with-content
HYDRA_TRACE_CONTENT=1 "$APPEND" --ticket t4b --kind chat --trace-dir "$tmpdir" --attr gen_ai.completion="kept via env" >/dev/null
assert_eq "HYDRA_TRACE_CONTENT=1 keeps completion" "kept via env" "$(jq -r '.attrs."gen_ai.completion"' "$tmpdir/t4b.jsonl")"

# =============================================================================
say "APPEND: empty-attr invocation + usage errors"
# =============================================================================
"$APPEND" --ticket t5 --kind chat --trace-dir "$tmpdir" >/dev/null
if jq empty "$tmpdir/t5.jsonl" >/dev/null 2>&1; then ok "zero-attr invocation writes a valid line"; else bad "zero-attr line invalid"; fi

set +e
"$APPEND" --ticket t6 --trace-dir "$tmpdir" >/dev/null 2>&1; rc_kind=$?
"$APPEND" --kind chat --trace-dir "$tmpdir" >/dev/null 2>&1; rc_ticket=$?
"$APPEND" --ticket t6 --kind bogus --trace-dir "$tmpdir" >/dev/null 2>&1; rc_badkind=$?
set -e
assert_eq "missing --kind → exit 2" "2" "$rc_kind"
assert_eq "missing --ticket → exit 2" "2" "$rc_ticket"
assert_eq "invalid --kind → exit 2" "2" "$rc_badkind"
if [[ ! -f "$tmpdir/t6.jsonl" ]]; then ok "no file written on usage error"; else bad "file written despite usage error"; fi

# =============================================================================
say "ANALYZE: durations against fixture"
# =============================================================================
dur_json="$("$ANALYZE" durations --json "$FIXTURE")"
get_dur() { jq -r --arg s "$1" '.[] | select(.span_id==$s) | "\(.status):\(.duration_ms)"' <<<"$dur_json"; }
assert_eq "root span duration" "complete:9000" "$(get_dur root0001)"
assert_eq "Bash tool duration" "complete:250" "$(get_dur tool0001)"
assert_eq "Edit tool duration" "complete:100" "$(get_dur tool0002)"
assert_eq "failed-test span duration" "complete:2500" "$(get_dur tool0003)"
assert_eq "half-open span → incomplete" "incomplete:null" "$(get_dur tool0004)"
assert_eq "phase-less chat → instant" "instant:null" "$(get_dur chat0001)"

# =============================================================================
say "ANALYZE: errors / tools / summary"
# =============================================================================
err_json="$("$ANALYZE" errors --json "$FIXTURE")"
assert_eq "exactly one error span" "1" "$(jq 'length' <<<"$err_json")"
assert_eq "error span is tool0003/test_failed" "tool0003:test_failed" "$(jq -r '.[0] | "\(.span_id):\(.error_type)"' <<<"$err_json")"

tools_seq="$("$ANALYZE" tools "$FIXTURE" | tr '\n' ',' | sed 's/,$//')"
assert_eq "tool sequence in order" "Bash,Edit,Bash,Bash" "$tools_seq"

sum_json="$("$ANALYZE" summary --json "$FIXTURE")"
assert_eq "summary events" "10" "$(jq -r '.events' <<<"$sum_json")"
assert_eq "summary spans" "6" "$(jq -r '.spans' <<<"$sum_json")"
assert_eq "summary tool_calls" "4" "$(jq -r '.tool_calls' <<<"$sum_json")"
assert_eq "summary errors" "1" "$(jq -r '.errors' <<<"$sum_json")"
assert_eq "summary wall_ms" "9000" "$(jq -r '.wall_ms' <<<"$sum_json")"

# =============================================================================
say "ANALYZE: stdin input + error paths"
# =============================================================================
stdin_tools="$(cat "$FIXTURE" | "$ANALYZE" tools | tr '\n' ',' | sed 's/,$//')"
assert_eq "stdin input matches file input" "Bash,Edit,Bash,Bash" "$stdin_tools"

set +e
"$ANALYZE" durations /no/such/file.jsonl >/dev/null 2>&1; rc_missing=$?
"$ANALYZE" "$FIXTURE" >/dev/null 2>&1; rc_nosub=$?
set -e
assert_eq "missing file → exit 2" "2" "$rc_missing"
assert_eq "no subcommand → exit 2" "2" "$rc_nosub"

# =============================================================================
# Round-trip: append a few events, analyze them end to end.
say "ROUND-TRIP: append → analyze"
# =============================================================================
rt="$tmpdir/rt"
mkdir -p "$rt"
rroot="$("$APPEND" --ticket rt --kind invoke_agent --phase start --trace-dir "$rt")"
rt1="$("$APPEND" --ticket rt --kind execute_tool --parent-span-id "$rroot" --phase start --trace-dir "$rt" --attr gen_ai.tool.name=Grep)"
"$APPEND" --ticket rt --kind execute_tool --span-id "$rt1" --parent-span-id "$rroot" --phase end --trace-dir "$rt" --attr gen_ai.tool.name=Grep --attr error.type=tool_error >/dev/null
rt_sum="$("$ANALYZE" summary --json "$rt/rt.jsonl")"
assert_eq "round-trip tool_calls" "1" "$(jq -r '.tool_calls' <<<"$rt_sum")"
assert_eq "round-trip errors" "1" "$(jq -r '.errors' <<<"$rt_sum")"

# =============================================================================
printf "\n${C_BOLD}%d passed, %d failed${C_RESET}\n" "$passed" "$failed"
[[ "$failed" -eq 0 ]]

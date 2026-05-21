#!/usr/bin/env bash
#
# test-promote-trace-to-golden.sh — regression test for
# scripts/promote-trace-to-golden.sh.
#
# Proves the production-to-test flywheel: a failed/stuck/rescued run's session
# trace (#197) becomes a valid kind:"script" golden case that self-test/run.sh
# executes green (#205). Offline, bash + jq, no network/docker.
#
# Cases:
#   1. emit: --dry-run produces ONE valid case (id, kind:script, non-empty steps).
#   2. emit: the case captures the trace's failure signature (error.type).
#   3. sanitize: a written fixture has NO gen_ai.prompt anywhere (content strip),
#      while preserving the error.type event.
#   4. idempotent: --into <file> twice yields exactly one trace-golden-<N> case.
#   5. flywheel: promote into a tmp cases file, run run.sh on that case → exit 0.
#   6. idle-ghost: a zero-error trace promotes to a non-empty case with a
#      .errors == 0 assertion and also runs green via run.sh.
#   7. usage/missing-trace errors exit 2.
#   8. --dry-run writes no fixture.
#
# Style: matches scripts/test-promote-citations.sh.
#
# Spec: docs/specs/2026-05-21-trace-to-golden-promotion.md (ticket #205)

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"
PROMOTE="$SCRIPT_DIR/promote-trace-to-golden.sh"
RUN_SH="$ROOT_DIR/self-test/run.sh"
SAMPLE="$ROOT_DIR/self-test/fixtures/trace-golden/sample-failed-trace.jsonl"
IDLE="$ROOT_DIR/self-test/fixtures/trace-golden/sample-idle-ghost-trace.jsonl"

if [[ ! -x "$PROMOTE" ]]; then
  echo "test-promote-trace-to-golden: $PROMOTE not found or not executable" >&2
  exit 2
fi

if [[ -t 1 ]] && [[ "${NO_COLOR:-}" != "1" ]]; then
  C_GREEN=$'\033[32m'
  C_RED=$'\033[31m'
  C_BOLD=$'\033[1m'
  C_RESET=$'\033[0m'
else
  C_GREEN=""; C_RED=""; C_BOLD=""; C_RESET=""
fi

passed=0
failed=0
tmpdir="$(mktemp -d)"
# The flywheel checks (5, 6) need a fixture path that run.sh — which runs case
# cmds from worktree root — can resolve, so it must live UNDER ROOT_DIR. Use a
# dedicated, gitignore-free, self-cleaning dir (NOT the committed sample dir) so
# a test run never pollutes the committed fixtures. The trap removes it.
flywheel_fixdir="$ROOT_DIR/self-test/fixtures/trace-golden-test-tmp"
mkdir -p "$flywheel_fixdir"
trap 'rm -rf "$tmpdir" "$flywheel_fixdir"' EXIT

say() { echo "${C_BOLD}== $*${C_RESET}"; }
ok()  { echo "  ${C_GREEN}✓${C_RESET} $*"; passed=$((passed + 1)); }
bad() { echo "  ${C_RED}✗${C_RESET} $*"; failed=$((failed + 1)); }

# -----------------------------------------------------------------------------
# 1 + 2. emit a valid case capturing the failure signature
# -----------------------------------------------------------------------------
say "1+2. --dry-run emits one valid case with the failure signature"
case_json="$("$PROMOTE" --ticket 2050 --trace "$SAMPLE" --verdict nothing-to-rescue --dry-run --emit-case-only)"

if jq -e . >/dev/null 2>&1 <<<"$case_json"; then
  ok "emitted case is valid JSON"
else
  bad "emitted case is not valid JSON: $case_json"
fi

if [[ "$(jq -r '.id' <<<"$case_json")" == "trace-golden-2050" ]]; then
  ok "case id is trace-golden-2050"
else
  bad "case id wrong: $(jq -r '.id' <<<"$case_json")"
fi

if [[ "$(jq -r '.kind' <<<"$case_json")" == "script" ]]; then
  ok "case kind is script"
else
  bad "case kind wrong: $(jq -r '.kind' <<<"$case_json")"
fi

if [[ "$(jq -r '.steps | length' <<<"$case_json")" -ge 1 ]]; then
  ok "case has at least one step"
else
  bad "case has no steps"
fi

if jq -e '[.steps[].expected_stdout_jq // ""] | any(contains("test_failed"))' >/dev/null <<<"$case_json"; then
  ok "a step asserts the captured failure signature (test_failed)"
else
  bad "no step references the failure signature test_failed"
fi

if [[ "$(jq -r '._provenance.verdict' <<<"$case_json")" == "nothing-to-rescue" ]]; then
  ok "provenance records the rescue verdict"
else
  bad "provenance verdict missing/wrong: $(jq -r '._provenance' <<<"$case_json")"
fi

# -----------------------------------------------------------------------------
# 3. sanitize: written fixture has no gen_ai.prompt, keeps error.type
# -----------------------------------------------------------------------------
say "3. sanitization strips content attrs from the written fixture"
fixdir="$tmpdir/fix3"
"$PROMOTE" --ticket 2050 --trace "$SAMPLE" --verdict nothing-to-rescue \
  --fixture-dir "$fixdir" --emit-case-only >/dev/null

written="$fixdir/2050.jsonl"
if [[ -f "$written" ]]; then
  ok "fixture written to $written"
else
  bad "fixture not written"
fi

if [[ -f "$written" ]] && ! grep -q 'gen_ai.prompt' "$written"; then
  ok "no gen_ai.prompt in the written fixture (content stripped)"
else
  bad "gen_ai.prompt still present in the written fixture"
fi

if [[ -f "$written" ]] && ! grep -q 'SECRET-PROMPT' "$written"; then
  ok "no secret content value in the written fixture"
else
  bad "secret content value leaked into the written fixture"
fi

if [[ -f "$written" ]] && grep -q '"error.type":"test_failed"' "$written"; then
  ok "error.type event preserved through sanitization"
else
  bad "error.type event lost during sanitization"
fi

# Sanitized fixture must still be valid JSONL.
if [[ -f "$written" ]] && jq empty "$written" >/dev/null 2>&1 && \
   [[ "$(jq -s 'length' "$written")" -eq "$(jq -s 'length' "$SAMPLE")" ]]; then
  ok "sanitized fixture is valid JSONL with the same event count"
else
  bad "sanitized fixture malformed or dropped events"
fi

# -----------------------------------------------------------------------------
# 4. idempotent merge into a cases file
# -----------------------------------------------------------------------------
say "4. --into merges idempotently (no duplicate case)"
cases_file="$tmpdir/cases.json"
echo '{"_description":"test","cases":[]}' > "$cases_file"
fixdir4="$tmpdir/fix4"
"$PROMOTE" --ticket 2050 --trace "$SAMPLE" --verdict nothing-to-rescue \
  --fixture-dir "$fixdir4" --into "$cases_file" >/dev/null
"$PROMOTE" --ticket 2050 --trace "$SAMPLE" --verdict nothing-to-rescue \
  --fixture-dir "$fixdir4" --into "$cases_file" >/dev/null

n_cases="$(jq -r '[.cases[] | select(.id == "trace-golden-2050")] | length' "$cases_file")"
if [[ "$n_cases" -eq 1 ]]; then
  ok "exactly one trace-golden-2050 case after two runs"
else
  bad "expected 1 case, got $n_cases"
fi

if jq -e '.cases | length == 1' "$cases_file" >/dev/null; then
  ok "cases array length is 1 (no leftover/dup rows)"
else
  bad "cases array length wrong: $(jq -r '.cases | length' "$cases_file")"
fi

# -----------------------------------------------------------------------------
# 5. flywheel proof — run.sh executes the promoted case green
# -----------------------------------------------------------------------------
say "5. flywheel — run.sh executes the promoted case green"
cases5="$tmpdir/cases5.json"
echo '{"_description":"test","cases":[]}' > "$cases5"
# Fixture must live under ROOT_DIR so run.sh (which runs cmds from worktree root)
# resolves the case's repo-relative path. Use the self-cleaning tmp fixture dir,
# never the committed sample dir.
"$PROMOTE" --ticket 2050 --trace "$SAMPLE" --verdict nothing-to-rescue \
  --fixture-dir "$flywheel_fixdir" --into "$cases5" >/dev/null

if NO_COLOR=1 "$RUN_SH" --cases-file "$cases5" --case trace-golden-2050 >"$tmpdir/run5.out" 2>&1; then
  ok "run.sh exits 0 on the promoted case"
else
  bad "run.sh failed on the promoted case:"
  sed 's/^/      /' "$tmpdir/run5.out"
fi

if grep -q '✓ trace-golden-2050' "$tmpdir/run5.out"; then
  ok "run.sh reports the case as passed"
else
  bad "run.sh did not report trace-golden-2050 as passed"
fi

# -----------------------------------------------------------------------------
# 6. idle-ghost trace (zero error.type) → non-empty case, runs green
# -----------------------------------------------------------------------------
say "6. idle-ghost trace promotes to a non-empty case that runs green"
cases6="$tmpdir/cases6.json"
echo '{"_description":"test","cases":[]}' > "$cases6"
idle_case="$("$PROMOTE" --ticket 3060 --trace "$IDLE" --verdict nothing-to-rescue --dry-run --emit-case-only)"

if [[ "$(jq -r '.steps | length' <<<"$idle_case")" -ge 1 ]]; then
  ok "idle-ghost case is non-empty"
else
  bad "idle-ghost case has no steps"
fi

if jq -e '[.steps[].expected_stdout_jq // ""] | any(contains(".errors == 0") or contains(".errors==0"))' >/dev/null <<<"$idle_case"; then
  ok "idle-ghost case asserts .errors == 0"
else
  bad "idle-ghost case missing the .errors == 0 assertion"
fi

"$PROMOTE" --ticket 3060 --trace "$IDLE" --verdict nothing-to-rescue \
  --fixture-dir "$flywheel_fixdir" --into "$cases6" >/dev/null
if NO_COLOR=1 "$RUN_SH" --cases-file "$cases6" --case trace-golden-3060 >"$tmpdir/run6.out" 2>&1; then
  ok "run.sh exits 0 on the idle-ghost case"
else
  bad "run.sh failed on the idle-ghost case:"
  sed 's/^/      /' "$tmpdir/run6.out"
fi

# -----------------------------------------------------------------------------
# 7. usage / missing-trace errors
# -----------------------------------------------------------------------------
say "7. usage and missing-trace errors exit 2"
if "$PROMOTE" --trace "$SAMPLE" --dry-run --emit-case-only >/dev/null 2>&1; then
  bad "missing --ticket should exit 2"
else
  [[ $? -eq 2 ]] && ok "missing --ticket exits 2" || bad "missing --ticket wrong exit code"
fi

if "$PROMOTE" --ticket 9999 --trace "$tmpdir/nope.jsonl" --dry-run --emit-case-only >/dev/null 2>&1; then
  bad "missing trace file should exit 2"
else
  [[ $? -eq 2 ]] && ok "missing trace file exits 2" || bad "missing trace file wrong exit code"
fi

empty_trace="$tmpdir/empty.jsonl"
: > "$empty_trace"
if "$PROMOTE" --ticket 9999 --trace "$empty_trace" --dry-run --emit-case-only >/dev/null 2>&1; then
  bad "empty trace should exit 2"
else
  [[ $? -eq 2 ]] && ok "empty trace exits 2" || bad "empty trace wrong exit code"
fi

# -----------------------------------------------------------------------------
# 8. --dry-run writes no fixture
# -----------------------------------------------------------------------------
say "8. --dry-run writes no fixture"
fixdir8="$tmpdir/fix8"
"$PROMOTE" --ticket 2050 --trace "$SAMPLE" --fixture-dir "$fixdir8" --dry-run --emit-case-only >/dev/null
if [[ ! -e "$fixdir8/2050.jsonl" ]]; then
  ok "--dry-run did not create the fixture"
else
  bad "--dry-run created a fixture (should not)"
fi

# -----------------------------------------------------------------------------
say "summary"
echo "${C_BOLD}${passed} passed · ${failed} failed${C_RESET}"
[[ "$failed" -gt 0 ]] && exit 1
exit 0

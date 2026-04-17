#!/usr/bin/env bash
#
# test-check-claude-md-size.sh — regression test for scripts/check-claude-md-size.sh.
#
# Exercises:
#   - under-threshold case exits 0 with an ok: message
#   - over-threshold case exits 1 and lists the H2 sections by char count
#   - env var HYDRA_CLAUDEMD_MAX lowers the threshold
#   - --max flag beats the env var when both are set
#   - missing file exits 2
#   - validate-state-all.sh invokes the size check and surfaces over-budget
#     as a failure in its summary
#
# Style: matches scripts/test-cloud-config.sh (bash, colored output, pass/fail
# counter, no external test harness). Spec:
# docs/specs/2026-04-17-claudemd-size-guard.md

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"
CHECK="$SCRIPT_DIR/check-claude-md-size.sh"
VALIDATE_ALL="$SCRIPT_DIR/validate-state-all.sh"

if [[ ! -f "$CHECK" ]]; then
  echo "test-check-claude-md-size: $CHECK not found" >&2
  exit 2
fi

if [[ -t 1 ]] && [[ "${NO_COLOR:-}" != "1" ]]; then
  C_GREEN=$'\033[32m'
  C_RED=$'\033[31m'
  C_DIM=$'\033[2m'
  C_BOLD=$'\033[1m'
  C_RESET=$'\033[0m'
else
  C_GREEN=""
  C_RED=""
  C_DIM=""
  C_BOLD=""
  C_RESET=""
fi

passed=0
failed=0
tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

say()  { printf "\n${C_BOLD}▸ %s${C_RESET}\n" "$*"; }
ok()   { printf "  ${C_GREEN}✓${C_RESET} %s\n" "$*"; passed=$((passed + 1)); }
bad()  { printf "  ${C_RED}✗${C_RESET} %s\n" "$*"; failed=$((failed + 1)); }

# Helper: write N identical bytes to a file, interspersed with H2 headers.
write_fixture() {
  local path="$1" size="$2"
  local section_a_lines="${3:-0}"
  local section_b_lines="${4:-0}"
  local section_c_lines="${5:-0}"
  {
    echo "# Fixture CLAUDE.md"
    echo ""
    echo "Preamble goes here."
    echo ""
    if [[ "$section_a_lines" -gt 0 ]]; then
      echo "## Section Alpha"
      echo ""
      for ((i=0; i<section_a_lines; i++)); do
        echo "Alpha line $i filler filler filler filler filler filler filler filler"
      done
      echo ""
    fi
    if [[ "$section_b_lines" -gt 0 ]]; then
      echo "## Section Beta"
      echo ""
      for ((i=0; i<section_b_lines; i++)); do
        echo "Beta line $i filler filler filler filler"
      done
      echo ""
    fi
    if [[ "$section_c_lines" -gt 0 ]]; then
      echo "## Section Gamma"
      echo ""
      for ((i=0; i<section_c_lines; i++)); do
        echo "Gamma line $i filler"
      done
      echo ""
    fi
  } > "$path"

  # Pad to exact size if needed (with raw bytes, no extra newlines).
  local cur
  cur="$(wc -c < "$path" | tr -d ' \n')"
  if [[ "$cur" -lt "$size" ]]; then
    local pad=$((size - cur))
    head -c "$pad" /dev/zero | tr '\0' 'x' >> "$path"
  fi
}

# ---------- Test 1: under threshold exits 0 ----------
say "Test 1: 5000-char fixture under 18000 → exit 0"
fix1="$tmpdir/claude-small.md"
write_fixture "$fix1" 5000 10 10 10
set +e
NO_COLOR=1 bash "$CHECK" --path "$fix1" --max 18000 > "$tmpdir/t1.out" 2> "$tmpdir/t1.err"
ec=$?
set -e
if [[ "$ec" -eq 0 ]]; then
  ok "exit 0 as expected"
else
  bad "expected exit 0, got $ec; stderr: $(cat "$tmpdir/t1.err")"
fi
if grep -q "check-claude-md-size:" "$tmpdir/t1.out"; then
  ok "ok-line present"
else
  bad "expected 'check-claude-md-size:' in stdout; got: $(cat "$tmpdir/t1.out")"
fi

# ---------- Test 2: over threshold exits 1 + lists sections ----------
say "Test 2: 20000-char fixture over 18000 → exit 1 + trim candidates"
fix2="$tmpdir/claude-big.md"
# Three sections of very different sizes so we can check the sort order.
write_fixture "$fix2" 20000 200 50 10
set +e
NO_COLOR=1 bash "$CHECK" --path "$fix2" --max 18000 > "$tmpdir/t2.out" 2> "$tmpdir/t2.err"
ec=$?
set -e
if [[ "$ec" -eq 1 ]]; then
  ok "exit 1 as expected"
else
  bad "expected exit 1, got $ec"
fi
# Over-budget banner goes to stderr.
if grep -q "20000 / 18000" "$tmpdir/t2.err"; then
  ok "size banner present in stderr"
else
  bad "expected '20000 / 18000' in stderr; got:"
  sed 's/^/    /' "$tmpdir/t2.err"
fi
if grep -q "top 5 H2 sections" "$tmpdir/t2.err"; then
  ok "trim-candidates header present"
else
  bad "expected 'top 5 H2 sections' in stderr"
fi
# Each section name should appear (we wrote Alpha, Beta, Gamma).
for name in "Section Alpha" "Section Beta" "Section Gamma"; do
  if grep -qF "$name" "$tmpdir/t2.err"; then
    ok "section listed: $name"
  else
    bad "expected section '$name' in trim candidates; got:"
    sed 's/^/    /' "$tmpdir/t2.err"
  fi
done

# ---------- Test 3: env var lowers the ceiling ----------
say "Test 3: HYDRA_CLAUDEMD_MAX=1000 on 5000-char fixture → exit 1"
set +e
HYDRA_CLAUDEMD_MAX=1000 NO_COLOR=1 bash "$CHECK" --path "$fix1" > "$tmpdir/t3.out" 2> "$tmpdir/t3.err"
ec=$?
set -e
if [[ "$ec" -eq 1 ]]; then
  ok "env-override lowers ceiling as expected"
else
  bad "expected exit 1 with HYDRA_CLAUDEMD_MAX=1000, got $ec"
fi

# ---------- Test 4: --max flag beats env ----------
say "Test 4: HYDRA_CLAUDEMD_MAX=1000 --max 18000 on 5000-char fixture → exit 0"
set +e
HYDRA_CLAUDEMD_MAX=1000 NO_COLOR=1 bash "$CHECK" --path "$fix1" --max 18000 > "$tmpdir/t4.out" 2> "$tmpdir/t4.err"
ec=$?
set -e
if [[ "$ec" -eq 0 ]]; then
  ok "flag beats env as expected"
else
  bad "expected exit 0 with flag override, got $ec; stderr: $(cat "$tmpdir/t4.err")"
fi

# ---------- Test 5: missing file exits 2 ----------
say "Test 5: nonexistent path → exit 2"
set +e
NO_COLOR=1 bash "$CHECK" --path "$tmpdir/does-not-exist.md" > "$tmpdir/t5.out" 2> "$tmpdir/t5.err"
ec=$?
set -e
if [[ "$ec" -eq 2 ]]; then
  ok "missing file → exit 2"
else
  bad "expected exit 2 for missing file, got $ec"
fi

# ---------- Test 6: non-integer --max rejected ----------
say "Test 6: --max foo → exit 2"
set +e
NO_COLOR=1 bash "$CHECK" --path "$fix1" --max "foo" > "$tmpdir/t6.out" 2> "$tmpdir/t6.err"
ec=$?
set -e
if [[ "$ec" -eq 2 ]]; then
  ok "non-integer --max → exit 2"
else
  bad "expected exit 2 for non-integer --max, got $ec"
fi

# ---------- Test 7: integration — validate-state-all.sh invokes the check ----------
# Run against the real repo. The working CLAUDE.md should be <= 18000 after
# this PR's trim lands; that's the under-budget path. Then run with a tiny
# HYDRA_CLAUDEMD_MAX to force the check to fail and assert the bulk runner
# reports an over-budget failure.
if [[ -x "$VALIDATE_ALL" ]] || [[ -f "$VALIDATE_ALL" ]]; then
  say "Test 7: validate-state-all.sh surfaces CLAUDE.md over-budget as a failure"

  # 7a: current repo under budget (or at least won't fail *because of* the
  # size check) — we don't assert exit 0 here because the test also has to
  # pass while the repo's CLAUDE.md is still being trimmed. Instead assert
  # the invocation line shows up in the output.
  set +e
  NO_COLOR=1 bash "$VALIDATE_ALL" > "$tmpdir/t7a.out" 2> "$tmpdir/t7a.err"
  ec=$?
  set -e
  combined_a="$tmpdir/t7a.combined"
  cat "$tmpdir/t7a.out" "$tmpdir/t7a.err" > "$combined_a"
  if grep -q "check-claude-md-size" "$combined_a"; then
    ok "validate-state-all invokes check-claude-md-size"
  else
    bad "expected 'check-claude-md-size' in validate-state-all output; got:"
    sed 's/^/    /' "$combined_a"
  fi

  # 7b: force the check to fail by setting a tiny ceiling and assert the
  # bulk runner reports a failure. The bulk runner exits 1 on any sub-check
  # failure.
  set +e
  HYDRA_CLAUDEMD_MAX=100 NO_COLOR=1 bash "$VALIDATE_ALL" > "$tmpdir/t7b.out" 2> "$tmpdir/t7b.err"
  ec=$?
  set -e
  combined_b="$tmpdir/t7b.combined"
  cat "$tmpdir/t7b.out" "$tmpdir/t7b.err" > "$combined_b"
  if [[ "$ec" -eq 1 ]]; then
    ok "validate-state-all exits 1 when CLAUDE.md is over budget"
  else
    bad "expected validate-state-all to exit 1 with tiny HYDRA_CLAUDEMD_MAX, got $ec"
  fi
  if grep -qE "(FAIL|over budget|check-claude-md-size)" "$combined_b"; then
    ok "bulk runner reports the size failure"
  else
    bad "expected bulk runner to surface the size failure; got:"
    sed 's/^/    /' "$combined_b"
  fi
else
  say "Test 7: SKIPPED — validate-state-all.sh not found at $VALIDATE_ALL"
fi

# ---------- summary ----------
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
if [[ "$failed" -eq 0 ]]; then
  printf "${C_GREEN}${C_BOLD}test-check-claude-md-size: OK${C_RESET} (%d passed)\n" "$passed"
  exit 0
fi
printf "${C_RED}${C_BOLD}test-check-claude-md-size: FAIL${C_RESET} (%d passed, %d failed)\n" \
  "$passed" "$failed" >&2
exit 1

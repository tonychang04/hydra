#!/usr/bin/env bash
#
# test-check-claude-md-size.sh — regression test for scripts/check-claude-md-size.sh.
#
# Exercises:
#   - OK band (under NOTICE floor) exits 0 with an ok: message, no band keyword
#   - over-threshold (FAIL) case exits 1 and lists the H2 sections by char count
#   - NOTICE band exits 0, prints the advisory line + trim candidates
#   - WARN band exits 0, prints a prominent block + call to action
#   - band cut points tunable via HYDRA_CLAUDEMD_NOTICE_PCT / _WARN_PCT
#   - inverted percentages (NOTICE > WARN) exit 2
#   - --quiet: silent at OK, one CLAUDE.md: line at NOTICE/WARN
#   - env var HYDRA_CLAUDEMD_MAX lowers the threshold
#   - --max flag beats the env var when both are set
#   - missing file exits 2
#   - validate-state-all.sh invokes the size check, surfaces over-budget as a
#     failure, AND stays green (exit 0) when CLAUDE.md is only NOTICE/WARN
#
# Style: matches scripts/test-cloud-config.sh (bash, colored output, pass/fail
# counter, no external test harness). Specs:
# docs/specs/2026-04-17-claudemd-size-guard.md (binary guard, original)
# docs/specs/2026-05-20-claudemd-size-graduated-bands.md (NOTICE/WARN bands)

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

# ---------- Test 1: OK band (well under NOTICE floor) exits 0 ----------
say "Test 1: 5000-char fixture under 18000 (OK band) → exit 0, silent on bands"
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
# OK band must NOT emit a NOTICE or WARN keyword — that would be false alarm.
if grep -qE "NOTICE|WARN" "$tmpdir/t1.out" "$tmpdir/t1.err"; then
  bad "OK band should not print NOTICE/WARN; got: $(cat "$tmpdir/t1.out" "$tmpdir/t1.err")"
else
  ok "OK band is silent on bands (no NOTICE/WARN)"
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

# Default bands: NOTICE_PCT=85 (notice_floor=850 @ max=1000),
# WARN_PCT=95 (warn_floor=950 @ max=1000). Use --max 1000 so fixture sizes map
# cleanly to percentages.

# ---------- Test 8: NOTICE band → exit 0 + advisory line + trim candidates ----------
say "Test 8: 880-char fixture @ max 1000 (88%, NOTICE band) → exit 0 + advisory"
fix_notice="$tmpdir/claude-notice.md"
write_fixture "$fix_notice" 880 8 4 2
set +e
NO_COLOR=1 bash "$CHECK" --path "$fix_notice" --max 1000 > "$tmpdir/t8.out" 2> "$tmpdir/t8.err"
ec=$?
set -e
combined8="$tmpdir/t8.combined"; cat "$tmpdir/t8.out" "$tmpdir/t8.err" > "$combined8"
if [[ "$ec" -eq 0 ]]; then
  ok "NOTICE exits 0 (advisory, does not block)"
else
  bad "expected exit 0 for NOTICE band, got $ec; output: $(cat "$combined8")"
fi
if grep -q "NOTICE" "$combined8"; then
  ok "NOTICE keyword present"
else
  bad "expected 'NOTICE' in output; got: $(cat "$combined8")"
fi
if grep -q "to ceiling" "$combined8"; then
  ok "'to ceiling' headroom phrase present"
else
  bad "expected 'to ceiling' in NOTICE output; got: $(cat "$combined8")"
fi
if grep -qF "Section Alpha" "$combined8"; then
  ok "NOTICE lists a trim candidate"
else
  bad "expected a trim candidate (Section Alpha) in NOTICE output; got: $(cat "$combined8")"
fi
# NOTICE must not also claim WARN.
if grep -q "WARN" "$combined8"; then
  bad "NOTICE band should not print WARN; got: $(cat "$combined8")"
else
  ok "NOTICE band does not over-escalate to WARN"
fi

# ---------- Test 9: WARN band → exit 0 + prominent block + call to action ----------
say "Test 9: 970-char fixture @ max 1000 (97%, WARN band) → exit 0 + call to action"
fix_warn="$tmpdir/claude-warn.md"
write_fixture "$fix_warn" 970 8 4 2
set +e
NO_COLOR=1 bash "$CHECK" --path "$fix_warn" --max 1000 > "$tmpdir/t9.out" 2> "$tmpdir/t9.err"
ec=$?
set -e
combined9="$tmpdir/t9.combined"; cat "$tmpdir/t9.out" "$tmpdir/t9.err" > "$combined9"
if [[ "$ec" -eq 0 ]]; then
  ok "WARN exits 0 (advisory, does not block)"
else
  bad "expected exit 0 for WARN band, got $ec; output: $(cat "$combined9")"
fi
if grep -q "WARN" "$combined9"; then
  ok "WARN keyword present"
else
  bad "expected 'WARN' in output; got: $(cat "$combined9")"
fi
if grep -qiE "trim.*(before adding|before you add).*routing|trim a section" "$combined9"; then
  ok "WARN call-to-action present"
else
  bad "expected a 'trim before adding routing' call to action; got: $(cat "$combined9")"
fi

# ---------- Test 10: NOTICE_PCT override moves the band ----------
# At max 1000, 880 chars is NOTICE by default (>=850). Raise NOTICE_PCT to 90
# (notice_floor=900) so 880 < 900 → falls back to OK band.
say "Test 10: HYDRA_CLAUDEMD_NOTICE_PCT=90 demotes an 88% fixture to OK"
set +e
HYDRA_CLAUDEMD_NOTICE_PCT=90 NO_COLOR=1 bash "$CHECK" --path "$fix_notice" --max 1000 > "$tmpdir/t10.out" 2> "$tmpdir/t10.err"
ec=$?
set -e
combined10="$tmpdir/t10.combined"; cat "$tmpdir/t10.out" "$tmpdir/t10.err" > "$combined10"
if [[ "$ec" -eq 0 ]]; then
  ok "exit 0 with raised NOTICE_PCT"
else
  bad "expected exit 0, got $ec"
fi
if grep -qE "NOTICE|WARN" "$combined10"; then
  bad "raising NOTICE_PCT should demote 88% to OK (silent); got: $(cat "$combined10")"
else
  ok "raised NOTICE_PCT demotes the fixture to OK band (no band keyword)"
fi

# ---------- Test 11: WARN_PCT override moves the band ----------
# 970 chars @ max 1000 is WARN by default (>=950). Raise WARN_PCT to 98
# (warn_floor=980) so 970 < 980 → drops to NOTICE band instead of WARN.
say "Test 11: HYDRA_CLAUDEMD_WARN_PCT=98 demotes a 97% fixture WARN→NOTICE"
set +e
HYDRA_CLAUDEMD_WARN_PCT=98 NO_COLOR=1 bash "$CHECK" --path "$fix_warn" --max 1000 > "$tmpdir/t11.out" 2> "$tmpdir/t11.err"
ec=$?
set -e
combined11="$tmpdir/t11.combined"; cat "$tmpdir/t11.out" "$tmpdir/t11.err" > "$combined11"
if [[ "$ec" -eq 0 ]]; then
  ok "exit 0 with raised WARN_PCT"
else
  bad "expected exit 0, got $ec"
fi
if grep -q "NOTICE" "$combined11" && ! grep -q "WARN" "$combined11"; then
  ok "raised WARN_PCT demotes the fixture to NOTICE band"
else
  bad "expected NOTICE (not WARN) with raised WARN_PCT; got: $(cat "$combined11")"
fi

# ---------- Test 12: inverted percentages rejected ----------
say "Test 12: NOTICE_PCT=95 WARN_PCT=85 (inverted) → exit 2"
set +e
HYDRA_CLAUDEMD_NOTICE_PCT=95 HYDRA_CLAUDEMD_WARN_PCT=85 NO_COLOR=1 \
  bash "$CHECK" --path "$fix_notice" --max 1000 > "$tmpdir/t12.out" 2> "$tmpdir/t12.err"
ec=$?
set -e
if [[ "$ec" -eq 2 ]]; then
  ok "inverted NOTICE>WARN → exit 2"
else
  bad "expected exit 2 for inverted percentages, got $ec; stderr: $(cat "$tmpdir/t12.err")"
fi

# ---------- Test 13: non-integer NOTICE_PCT rejected ----------
say "Test 13: HYDRA_CLAUDEMD_NOTICE_PCT=foo → exit 2"
set +e
HYDRA_CLAUDEMD_NOTICE_PCT=foo NO_COLOR=1 bash "$CHECK" --path "$fix_notice" --max 1000 \
  > "$tmpdir/t13.out" 2> "$tmpdir/t13.err"
ec=$?
set -e
if [[ "$ec" -eq 2 ]]; then
  ok "non-integer NOTICE_PCT → exit 2"
else
  bad "expected exit 2 for non-integer NOTICE_PCT, got $ec"
fi

# ---------- Test 14: --quiet is silent at OK ----------
say "Test 14: --quiet on OK fixture → no stdout"
set +e
NO_COLOR=1 bash "$CHECK" --path "$fix1" --max 18000 --quiet > "$tmpdir/t14.out" 2> "$tmpdir/t14.err"
ec=$?
set -e
if [[ "$ec" -eq 0 ]]; then
  ok "--quiet OK exits 0"
else
  bad "expected exit 0, got $ec"
fi
if [[ -s "$tmpdir/t14.out" ]]; then
  bad "--quiet on OK band must produce no stdout; got: $(cat "$tmpdir/t14.out")"
else
  ok "--quiet OK band is silent"
fi

# ---------- Test 15: --quiet emits one CLAUDE.md: line at NOTICE ----------
say "Test 15: --quiet on NOTICE fixture → one 'CLAUDE.md:' line"
set +e
NO_COLOR=1 bash "$CHECK" --path "$fix_notice" --max 1000 --quiet > "$tmpdir/t15.out" 2> "$tmpdir/t15.err"
ec=$?
set -e
if [[ "$ec" -eq 0 ]]; then
  ok "--quiet NOTICE exits 0"
else
  bad "expected exit 0, got $ec"
fi
lines15="$(wc -l < "$tmpdir/t15.out" | tr -d ' ')"
if grep -q "^CLAUDE.md:" "$tmpdir/t15.out" && [[ "$lines15" -eq 1 ]]; then
  ok "--quiet NOTICE emits exactly one 'CLAUDE.md:' line"
else
  bad "expected exactly one 'CLAUDE.md:' line; got ($lines15 lines): $(cat "$tmpdir/t15.out")"
fi

# ---------- Test 16: --quiet emits one CLAUDE.md: line at WARN ----------
say "Test 16: --quiet on WARN fixture → one 'CLAUDE.md:' line"
set +e
NO_COLOR=1 bash "$CHECK" --path "$fix_warn" --max 1000 --quiet > "$tmpdir/t16.out" 2> "$tmpdir/t16.err"
ec=$?
set -e
lines16="$(wc -l < "$tmpdir/t16.out" | tr -d ' ')"
if [[ "$ec" -eq 0 ]] && grep -q "^CLAUDE.md:" "$tmpdir/t16.out" && [[ "$lines16" -eq 1 ]]; then
  ok "--quiet WARN exits 0 with exactly one 'CLAUDE.md:' line"
else
  bad "expected exit 0 + one 'CLAUDE.md:' line; got ec=$ec ($lines16 lines): $(cat "$tmpdir/t16.out")"
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

  # 7c: NOTICE/WARN must NOT fail preflight. Compute a ceiling that lands the
  # real CLAUDE.md inside the NOTICE/WARN band (size <= max but >= notice_floor)
  # and assert validate-state-all STILL exits 0. We pick max = size + 1 so the
  # file is at ~99% (WARN band, but strictly under the ceiling).
  real_claude="$ROOT_DIR/CLAUDE.md"
  if [[ -f "$real_claude" ]]; then
    real_size="$(wc -c < "$real_claude" | tr -d ' \n')"
    warn_max=$((real_size + 1))   # size < max → not FAIL; size/max ~ 99% → WARN
    set +e
    HYDRA_CLAUDEMD_MAX="$warn_max" NO_COLOR=1 bash "$VALIDATE_ALL" \
      > "$tmpdir/t7c.out" 2> "$tmpdir/t7c.err"
    ec=$?
    set -e
    combined_c="$tmpdir/t7c.combined"
    cat "$tmpdir/t7c.out" "$tmpdir/t7c.err" > "$combined_c"
    if [[ "$ec" -eq 0 ]]; then
      ok "validate-state-all stays green (exit 0) when CLAUDE.md is WARN, not over"
    else
      bad "expected validate-state-all exit 0 with WARN-band CLAUDE.md (max=$warn_max), got $ec; output:"
      sed 's/^/    /' "$combined_c"
    fi
    if grep -qE "NOTICE|WARN" "$combined_c"; then
      ok "validate-state-all surfaces the NOTICE/WARN advisory line"
    else
      bad "expected NOTICE/WARN advisory in validate-state-all output; got:"
      sed 's/^/    /' "$combined_c"
    fi
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

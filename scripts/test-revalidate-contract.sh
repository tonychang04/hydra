#!/usr/bin/env bash
#
# test-revalidate-contract.sh — regression test for scripts/revalidate-contract.sh
# (ticket #256, black-box runtime validation: re-run the contract for TRUTH).
#
# #255's validate-contract.sh checks evidence PRESENCE (every PASS row has
# non-empty, non-placeholder text). It does NOT re-run the command, so a worker
# can paste "works" as evidence for a command that actually FAILS and the
# presence gate passes anyway. #256 closes that gap: revalidate-contract.sh
# RE-RUNS each claimed-PASS Command and compares the ACTUAL exit/output to the
# contract's Expected. The headline assertion is the LYING-EVIDENCE RED -> GREEN
# pair using the committed fixtures under self-test/fixtures/revalidate-contract/.
#
# Exercises:
#   - LYING fixture passes the #255 presence gate (proves the gap)   -> exit 0
#   - LYING fixture is CAUGHT by the truth gate (re-run mismatch)    -> exit 1
#   - HONEST fixture (commands reproduce)                            -> exit 0
#   - `exit <N>` Expected matching (nonzero-exit-as-proof rows)      -> exit 0
#   - UNVERIFIED rows are SKIPPED, not run                           -> exit 0
#   - output-substring drift is a WARN, not a hard fail             -> exit 0
#   - claimed PASS, command exits 0, no parseable Expected          -> exit 0
#   - claimed PASS, command exits nonzero, no parseable Expected    -> exit 1
#   - --cwd <dir> runs commands in that directory                    -> exit 0
#   - no / garbled table header                                      -> exit 2
#   - escaped pipe \| in a Command cell (shared splitter, no shift)  -> exit 0
#   - --help                                                         -> exit 0
#
# Style: matches scripts/test-validate-contract.sh (bash, colored output,
# pass/fail counter, no external harness). Spec:
# docs/specs/2026-06-07-worker-validator.md

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
CHECK="$SCRIPT_DIR/revalidate-contract.sh"
PRESENCE="$SCRIPT_DIR/validate-contract.sh"
FIXDIR="$REPO_ROOT/self-test/fixtures/revalidate-contract"

if [[ ! -f "$CHECK" ]]; then
  echo "test-revalidate-contract: $CHECK not found" >&2
  exit 2
fi

if [[ -t 1 ]] && [[ "${NO_COLOR:-}" != "1" ]]; then
  C_GREEN=$'\033[32m'
  C_RED=$'\033[31m'
  C_BOLD=$'\033[1m'
  C_RESET=$'\033[0m'
else
  C_GREEN=""
  C_RED=""
  C_BOLD=""
  C_RESET=""
fi

passed=0
failed=0
tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

say() { printf "\n${C_BOLD}> %s${C_RESET}\n" "$*"; }
ok()  { printf "  ${C_GREEN}OK${C_RESET}  %s\n" "$*"; passed=$((passed + 1)); }
bad() { printf "  ${C_RED}XX${C_RESET}  %s\n" "$*"; failed=$((failed + 1)); }

# run <args...> -> sets EC + $tmpdir/out
run() {
  set +e
  NO_COLOR=1 bash "$CHECK" "$@" > "$tmpdir/out" 2>&1
  EC=$?
  set -e
}

# ---------- Test 1: LYING fixture passes the #255 PRESENCE gate (the gap) ----------
say "Test 1: LYING fixture passes #255 presence gate (validate-contract.sh exit 0)"
if [[ -f "$PRESENCE" && -f "$FIXDIR/lying.md" ]]; then
  set +e
  NO_COLOR=1 bash "$PRESENCE" --file "$FIXDIR/lying.md" > "$tmpdir/out" 2>&1
  pec=$?
  set -e
  if [[ "$pec" -eq 0 ]]; then ok "presence gate accepts lying.md (exit 0) — confirms presence != truth"; else bad "expected presence gate exit 0, got $pec; out: $(cat "$tmpdir/out")"; fi
else
  bad "missing $PRESENCE or $FIXDIR/lying.md"
fi

# ---------- Test 2: LYING fixture CAUGHT by the truth gate (RED) ----------
say "Test 2: LYING fixture caught by truth gate (re-run mismatch) -> exit 1"
if [[ -f "$FIXDIR/lying.md" ]]; then
  run --file "$FIXDIR/lying.md" --cwd "$FIXDIR"
  if [[ "$EC" -eq 1 ]]; then ok "lying.md rejected (exit 1)"; else bad "expected 1, got $EC; out: $(cat "$tmpdir/out")"; fi
  if grep -qiE "mismatch|row 1|assertion 1" "$tmpdir/out"; then ok "names the lying row"; else bad "expected the lying row named; out: $(cat "$tmpdir/out")"; fi
  if grep -qiE "row 2" "$tmpdir/out" | grep -qiE "mismatch"; then bad "row 2 (honest) wrongly flagged"; else ok "honest row 2 not flagged as mismatch"; fi
else
  bad "fixture $FIXDIR/lying.md missing"
fi

# ---------- Test 3: HONEST fixture reproduces (GREEN) ----------
say "Test 3: HONEST fixture (commands reproduce) -> exit 0"
if [[ -f "$FIXDIR/honest.md" ]]; then
  run --file "$FIXDIR/honest.md" --cwd "$FIXDIR"
  if [[ "$EC" -eq 0 ]]; then ok "honest.md -> exit 0"; else bad "expected 0, got $EC; out: $(cat "$tmpdir/out")"; fi
else
  bad "fixture $FIXDIR/honest.md missing"
fi

# ---------- Test 4: `exit <N>` Expected matching (nonzero-as-proof) ----------
say "Test 4: PASS row whose Expected is 'exit 1' and command really exits 1 -> exit 0"
cat > "$tmpdir/t4.md" <<'EOF'
| # | Assertion | Command | Expected | Verdict | Evidence |
|---|---|---|---|---|---|
| 1 | rejecter exits nonzero | `sh -c 'exit 1'` | exit 1 | PASS | ran it -> exit 1 |
EOF
run --file "$tmpdir/t4.md"
if [[ "$EC" -eq 0 ]]; then ok "nonzero-exit-as-proof accepted"; else bad "expected 0, got $EC; out: $(cat "$tmpdir/out")"; fi

# ---------- Test 5: `exit 1` Expected but command exits 0 -> MISMATCH ----------
say "Test 5: PASS row whose Expected is 'exit 1' but command exits 0 -> exit 1"
cat > "$tmpdir/t5.md" <<'EOF'
| # | Assertion | Command | Expected | Verdict | Evidence |
|---|---|---|---|---|---|
| 1 | should reject but does not | `sh -c 'exit 0'` | exit 1 | PASS | claimed it rejects |
EOF
run --file "$tmpdir/t5.md"
if [[ "$EC" -eq 1 ]]; then ok "exit-code disagreement caught"; else bad "expected 1, got $EC; out: $(cat "$tmpdir/out")"; fi

# ---------- Test 6: UNVERIFIED rows are SKIPPED, not run ----------
say "Test 6: UNVERIFIED row is SKIPPED (command never run) -> exit 0"
cat > "$tmpdir/t6.md" <<'EOF'
| # | Assertion | Command | Expected | Verdict | Evidence |
|---|---|---|---|---|---|
| 1 | needs prod data | `sh -c 'echo SHOULD_NOT_RUN; exit 7'` | rollback | UNVERIFIED | no live DB |
EOF
run --file "$tmpdir/t6.md"
if [[ "$EC" -eq 0 ]]; then ok "UNVERIFIED does not fail the gate"; else bad "expected 0, got $EC; out: $(cat "$tmpdir/out")"; fi
if grep -q "SHOULD_NOT_RUN" "$tmpdir/out"; then bad "UNVERIFIED command was RUN (leaked stdout)"; else ok "UNVERIFIED command was not run"; fi
if grep -qiE "skip" "$tmpdir/out"; then ok "reports the row as SKIPPED"; else bad "expected SKIPPED in output; out: $(cat "$tmpdir/out")"; fi

# ---------- Test 7: output-substring drift is a WARN, not a hard fail ----------
say "Test 7: exit matches but Expected output substring missing -> WARN, exit 0"
cat > "$tmpdir/t7.md" <<'EOF'
| # | Assertion | Command | Expected | Verdict | Evidence |
|---|---|---|---|---|---|
| 1 | prints a banner | `sh -c 'echo HELLO'` | exit 0 / `GOODBYE` | PASS | ran it -> exit 0 |
EOF
run --file "$tmpdir/t7.md"
if [[ "$EC" -eq 0 ]]; then ok "substring drift is non-fatal (exit 0)"; else bad "expected 0, got $EC; out: $(cat "$tmpdir/out")"; fi
if grep -qiE "warn" "$tmpdir/out"; then ok "reports a WARN for the missing substring"; else bad "expected WARN in output; out: $(cat "$tmpdir/out")"; fi

# ---------- Test 8: matching output substring is OK ----------
say "Test 8: exit matches AND Expected output substring present -> exit 0, no warn"
cat > "$tmpdir/t8.md" <<'EOF'
| # | Assertion | Command | Expected | Verdict | Evidence |
|---|---|---|---|---|---|
| 1 | prints a banner | `sh -c 'echo HELLO'` | exit 0 / `HELLO` | PASS | ran it -> exit 0; HELLO |
EOF
run --file "$tmpdir/t8.md"
if [[ "$EC" -eq 0 ]]; then ok "matching substring -> exit 0"; else bad "expected 0, got $EC; out: $(cat "$tmpdir/out")"; fi

# ---------- Test 9: PASS, no parseable Expected, command exits 0 -> OK ----------
say "Test 9: PASS with prose Expected, command exits 0 -> exit 0 (fallback)"
cat > "$tmpdir/t9.md" <<'EOF'
| # | Assertion | Command | Expected | Verdict | Evidence |
|---|---|---|---|---|---|
| 1 | does the thing | `sh -c 'exit 0'` | the thing happens | PASS | ran it |
EOF
run --file "$tmpdir/t9.md"
if [[ "$EC" -eq 0 ]]; then ok "prose-Expected PASS w/ exit 0 -> ok"; else bad "expected 0, got $EC; out: $(cat "$tmpdir/out")"; fi

# ---------- Test 10: PASS, no parseable Expected, command exits nonzero -> MISMATCH ----------
say "Test 10: PASS with prose Expected, command exits nonzero -> exit 1 (fallback)"
cat > "$tmpdir/t10.md" <<'EOF'
| # | Assertion | Command | Expected | Verdict | Evidence |
|---|---|---|---|---|---|
| 1 | does the thing | `sh -c 'exit 2'` | the thing happens | PASS | claimed it works |
EOF
run --file "$tmpdir/t10.md"
if [[ "$EC" -eq 1 ]]; then ok "prose-Expected PASS w/ nonzero exit caught"; else bad "expected 1, got $EC; out: $(cat "$tmpdir/out")"; fi

# ---------- Test 11: --cwd runs commands in the given directory ----------
say "Test 11: --cwd <dir> runs commands relative to that directory -> exit 0"
mkdir -p "$tmpdir/work"
printf 'marker' > "$tmpdir/work/sentinel.txt"
cat > "$tmpdir/t11.md" <<'EOF'
| # | Assertion | Command | Expected | Verdict | Evidence |
|---|---|---|---|---|---|
| 1 | sentinel exists in cwd | `cat sentinel.txt` | exit 0 / `marker` | PASS | ran it -> marker |
EOF
run --file "$tmpdir/t11.md" --cwd "$tmpdir/work"
if [[ "$EC" -eq 0 ]]; then ok "--cwd honored (relative path resolved)"; else bad "expected 0, got $EC; out: $(cat "$tmpdir/out")"; fi

# ---------- Test 12: no/garbled header -> exit 2 ----------
say "Test 12: body with NO contract table -> exit 2 (parse error)"
cat > "$tmpdir/t12.md" <<'EOF'
# Validation contract — #42

Just prose, no table at all.
EOF
run --file "$tmpdir/t12.md"
if [[ "$EC" -eq 2 ]]; then ok "missing table -> exit 2"; else bad "expected 2, got $EC; out: $(cat "$tmpdir/out")"; fi

# ---------- Test 13: escaped pipe \| in Command (shared splitter, no shift) ----------
say "Test 13: escaped pipe \\| in Command cell -> re-runs the pipeline, exit 0"
cat > "$tmpdir/t13.md" <<'EOF'
| # | Assertion | Command | Expected | Verdict | Evidence |
|---|---|---|---|---|---|
| 1 | pipeline counts lines | `sh -c 'printf "a\nb\nc\n"' \| wc -l` | exit 0 / `3` | PASS | ran it -> 3 |
EOF
run --file "$tmpdir/t13.md"
if [[ "$EC" -eq 0 ]]; then ok "escaped-pipe command re-run, no column shift"; else bad "expected 0, got $EC; out: $(cat "$tmpdir/out")"; fi

# ---------- Test 14: --help -> exit 0 ----------
say "Test 14: --help -> exit 0"
set +e
NO_COLOR=1 bash "$CHECK" --help > "$tmpdir/out" 2>&1
EC=$?
set -e
if [[ "$EC" -eq 0 ]] && grep -qi "usage" "$tmpdir/out"; then ok "--help exits 0 with usage"; else bad "expected 0 + usage, got $EC; out: $(cat "$tmpdir/out")"; fi

# ---------- summary ----------
echo ""
echo "============================================================"
if [[ "$failed" -eq 0 ]]; then
  printf "${C_GREEN}${C_BOLD}test-revalidate-contract: OK${C_RESET} (%d passed)\n" "$passed"
  exit 0
fi
printf "${C_RED}${C_BOLD}test-revalidate-contract: FAIL${C_RESET} (%d passed, %d failed)\n" \
  "$passed" "$failed" >&2
exit 1

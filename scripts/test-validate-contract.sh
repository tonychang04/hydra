#!/usr/bin/env bash
#
# test-validate-contract.sh — regression test for scripts/validate-contract.sh
# (ticket #255, verify-first validation contract + evidence completion gate).
#
# Proves the validation-contract artifact enforces the verify-first rule: every
# assertion names the command that proves it, and no assertion gets a clean PASS
# without captured evidence. The headline assertion is the RED -> GREEN pair
# using the committed fixtures under self-test/fixtures/validation-contract/.
#
# Exercises:
#   - GREEN fixture (complete contract)                     -> exit 0
#   - RED fixture (PASS w/o evidence + missing command)     -> exit 1
#   - PASS with empty Evidence                              -> exit 1  (core rule)
#   - assertion with empty Command (any verdict)            -> exit 1  (verify-first)
#   - PASS with placeholder evidence (-, n/a, none, ``)     -> exit 1
#   - UNVERIFIED with no evidence (but a command)           -> exit 0  (allowed)
#   - FAIL with no evidence (but a command)                 -> exit 0  (allowed)
#   - illegal verdict (MAYBE)                               -> exit 1
#   - zero assertion rows                                   -> exit 1
#   - no / garbled table header                             -> exit 2
#   - --file <path> path                                    -> exit 0
#   - escaped pipe \| in cells (no column shift)            -> exit 0
#   - case-insensitive verdicts                             -> exit 0
#   - --help                                                -> exit 0
#
# Style: matches scripts/test-validate-evidence-table.sh (bash, colored output,
# pass/fail counter, no external harness). Spec:
# docs/specs/2026-06-07-validation-contract.md

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
CHECK="$SCRIPT_DIR/validate-contract.sh"
FIXDIR="$REPO_ROOT/self-test/fixtures/validation-contract"

if [[ ! -f "$CHECK" ]]; then
  echo "test-validate-contract: $CHECK not found" >&2
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

# run_stdin <fixture-file> -> sets EC + $tmpdir/out
run_stdin() {
  local fixture="$1"
  set +e
  NO_COLOR=1 bash "$CHECK" < "$fixture" > "$tmpdir/out" 2>&1
  EC=$?
  set -e
}

# A valid contract body (baseline; edited per test).
valid_contract() {
  cat <<'EOF'
# Validation contract — #42

| # | Assertion | Command | Expected | Verdict | Evidence |
|---|---|---|---|---|---|
| 1 | helper exits 0 on a complete contract | `bash scripts/validate-contract.sh --file green.md` | exit 0 | PASS | ran it -> exit 0; "every PASS carries evidence" |
| 2 | flag parses | `bash scripts/x.sh --flag` | prints value | PASS | `bash scripts/x.sh --flag` -> `value`; diff `scripts/x.sh:42` |
| 3 | migration reversible | `psql -f down.sql` | clean rollback | UNVERIFIED | no live DB in worker scope |
EOF
}

# ---------- Test 1: GREEN fixture -> exit 0 ----------
say "Test 1: GREEN fixture (complete contract) -> exit 0"
if [[ -f "$FIXDIR/green.md" ]]; then
  run_stdin "$FIXDIR/green.md"
  if [[ "$EC" -eq 0 ]]; then ok "green.md -> exit 0"; else bad "expected 0, got $EC; out: $(cat "$tmpdir/out")"; fi
else
  bad "fixture $FIXDIR/green.md missing"
fi

# ---------- Test 2: RED fixture -> exit 1 (THE core RED->GREEN proof) ----------
say "Test 2: RED fixture (PASS w/o evidence + missing command) -> exit 1"
if [[ -f "$FIXDIR/red.md" ]]; then
  run_stdin "$FIXDIR/red.md"
  if [[ "$EC" -eq 1 ]]; then ok "red.md rejected (exit 1)"; else bad "expected 1, got $EC; out: $(cat "$tmpdir/out")"; fi
  if grep -qiE "evidence|command" "$tmpdir/out"; then ok "names the violation(s)"; else bad "expected violation named; got: $(cat "$tmpdir/out")"; fi
else
  bad "fixture $FIXDIR/red.md missing"
fi

# ---------- Test 3: baseline valid contract -> exit 0 ----------
say "Test 3: inline valid contract -> exit 0"
valid_contract > "$tmpdir/t3.md"
run_stdin "$tmpdir/t3.md"
if [[ "$EC" -eq 0 ]]; then ok "exit 0"; else bad "expected 0, got $EC; out: $(cat "$tmpdir/out")"; fi

# ---------- Test 4: PASS without evidence -> exit 1 (core rule) ----------
say "Test 4: a PASS row with an EMPTY Evidence cell -> exit 1"
cat > "$tmpdir/t4.md" <<'EOF'
| # | Assertion | Command | Expected | Verdict | Evidence |
|---|---|---|---|---|---|
| 1 | does the thing | `bash run.sh` | exit 0 | PASS |  |
| 2 | also works | `bash run2.sh` | ok | PASS | ran it -> ok |
EOF
run_stdin "$tmpdir/t4.md"
if [[ "$EC" -eq 1 ]]; then ok "PASS-without-evidence rejected"; else bad "expected 1, got $EC; out: $(cat "$tmpdir/out")"; fi
if grep -qiE "row 1|assertion 1|PASS.*evidence|evidence" "$tmpdir/out"; then ok "names the offending PASS row"; else bad "expected row named; got: $(cat "$tmpdir/out")"; fi
if grep -qiE "row 2" "$tmpdir/out"; then bad "row 2 (valid PASS) should not be flagged; got: $(cat "$tmpdir/out")"; else ok "valid PASS row not flagged"; fi

# ---------- Test 5: assertion with empty Command -> exit 1 (verify-first) ----------
say "Test 5: a row with an EMPTY Command cell -> exit 1 (verify-first violated)"
for v in PASS FAIL UNVERIFIED; do
  cat > "$tmpdir/t5.md" <<EOF
| # | Assertion | Command | Expected | Verdict | Evidence |
|---|---|---|---|---|---|
| 1 | does the thing |  | exit 0 | $v | some note |
EOF
  run_stdin "$tmpdir/t5.md"
  if [[ "$EC" -eq 1 ]]; then ok "empty Command on $v rejected (exit 1)"; else bad "expected 1 for $v, got $EC; out: $(cat "$tmpdir/out")"; fi
done
if grep -qiE "command" "$tmpdir/out"; then ok "names the missing-command violation"; else bad "expected 'command' in output; got: $(cat "$tmpdir/out")"; fi

# ---------- Test 6: PASS with placeholder evidence -> exit 1 ----------
say "Test 6: PASS with placeholder evidence (-, n/a, none, backticks) -> exit 1"
for ph in "-" "n/a" "N/A" "none" "None" '``' "   "; do
  cat > "$tmpdir/t6.md" <<EOF
| # | Assertion | Command | Expected | Verdict | Evidence |
|---|---|---|---|---|---|
| 1 | some assertion | \`bash run.sh\` | exit 0 | PASS | $ph |
EOF
  run_stdin "$tmpdir/t6.md"
  if [[ "$EC" -eq 1 ]]; then ok "placeholder evidence '$ph' rejected"; else bad "expected 1 for '$ph', got $EC; out: $(cat "$tmpdir/out")"; fi
done

# ---------- Test 7: UNVERIFIED with no evidence (but a command) -> exit 0 ----------
say "Test 7: UNVERIFIED with empty Evidence (command present) -> exit 0 (allowed)"
cat > "$tmpdir/t7.md" <<'EOF'
| # | Assertion | Command | Expected | Verdict | Evidence |
|---|---|---|---|---|---|
| 1 | needs production data | `psql -f down.sql` | rollback | UNVERIFIED |  |
EOF
run_stdin "$tmpdir/t7.md"
if [[ "$EC" -eq 0 ]]; then ok "UNVERIFIED w/o evidence allowed"; else bad "expected 0, got $EC; out: $(cat "$tmpdir/out")"; fi

# ---------- Test 8: FAIL with no evidence (but a command) -> exit 0 ----------
say "Test 8: FAIL with empty Evidence (command present) -> exit 0 (allowed)"
cat > "$tmpdir/t8.md" <<'EOF'
| # | Assertion | Command | Expected | Verdict | Evidence |
|---|---|---|---|---|---|
| 1 | returns 200 | `curl localhost/health` | 200 | FAIL |  |
EOF
run_stdin "$tmpdir/t8.md"
if [[ "$EC" -eq 0 ]]; then ok "FAIL w/o evidence allowed"; else bad "expected 0, got $EC; out: $(cat "$tmpdir/out")"; fi

# ---------- Test 9: illegal verdict -> exit 1 ----------
say "Test 9: illegal verdict (MAYBE) -> exit 1"
cat > "$tmpdir/t9.md" <<'EOF'
| # | Assertion | Command | Expected | Verdict | Evidence |
|---|---|---|---|---|---|
| 1 | something | `bash run.sh` | exit 0 | MAYBE | evidence here |
EOF
run_stdin "$tmpdir/t9.md"
if [[ "$EC" -eq 1 ]]; then ok "illegal verdict rejected"; else bad "expected 1, got $EC; out: $(cat "$tmpdir/out")"; fi
if grep -qiE "MAYBE|verdict" "$tmpdir/out"; then ok "names the bad verdict"; else bad "expected verdict named; got: $(cat "$tmpdir/out")"; fi

# ---------- Test 10: zero assertion rows -> exit 1 ----------
say "Test 10: header present but zero data rows -> exit 1"
cat > "$tmpdir/t10.md" <<'EOF'
| # | Assertion | Command | Expected | Verdict | Evidence |
|---|---|---|---|---|---|

done.
EOF
run_stdin "$tmpdir/t10.md"
if [[ "$EC" -eq 1 ]]; then ok "zero-assertion table rejected"; else bad "expected 1, got $EC; out: $(cat "$tmpdir/out")"; fi

# ---------- Test 11: no/garbled header -> exit 2 ----------
say "Test 11: body with NO contract table -> exit 2 (parse error)"
cat > "$tmpdir/t11.md" <<'EOF'
# Validation contract — #42

Just prose, no table at all.
EOF
run_stdin "$tmpdir/t11.md"
if [[ "$EC" -eq 2 ]]; then ok "missing table -> exit 2"; else bad "expected 2, got $EC; out: $(cat "$tmpdir/out")"; fi

# ---------- Test 12: a 4-column evidence table is NOT a contract table -> exit 2 ----------
say "Test 12: the #196 4-column evidence table is NOT a contract table -> exit 2"
cat > "$tmpdir/t12.md" <<'EOF'
| # | Criterion | Verdict | Evidence |
|---|---|---|---|
| 1 | does the thing | PASS | ran it |
EOF
run_stdin "$tmpdir/t12.md"
if [[ "$EC" -eq 2 ]]; then ok "4-column table not mistaken for a contract"; else bad "expected 2, got $EC; out: $(cat "$tmpdir/out")"; fi

# ---------- Test 13: --file <path> path ----------
say "Test 13: --file <path> reads the body from a file -> exit 0"
set +e
NO_COLOR=1 bash "$CHECK" --file "$tmpdir/t3.md" > "$tmpdir/out" 2>&1
EC=$?
set -e
if [[ "$EC" -eq 0 ]]; then ok "--file path works"; else bad "expected 0, got $EC; out: $(cat "$tmpdir/out")"; fi

# ---------- Test 14: escaped pipe \| in Command AND Evidence -> exit 0 (no shift) ----------
say "Test 14: escaped pipe \\| in Command + Evidence cells -> exit 0 (no column shift)"
cat > "$tmpdir/t14.md" <<'EOF'
| # | Assertion | Command | Expected | Verdict | Evidence |
|---|---|---|---|---|---|
| 1 | counts matching lines | `grep x f \| wc -l` | `3` | PASS | ran `grep x f \| wc -l` -> `3` |
EOF
run_stdin "$tmpdir/t14.md"
if [[ "$EC" -eq 0 ]]; then ok "escaped pipes kept as content; columns not shifted"; else bad "expected 0, got $EC; out: $(cat "$tmpdir/out")"; fi

# ---------- Test 15: \| in Command but EMPTY Evidence on a PASS -> exit 1 (still caught) ----------
say "Test 15: \\| in Command but EMPTY Evidence on a PASS row -> exit 1 (still caught)"
cat > "$tmpdir/t15.md" <<'EOF'
| # | Assertion | Command | Expected | Verdict | Evidence |
|---|---|---|---|---|---|
| 1 | pipeline works | `a \| b` | ok | PASS |  |
EOF
run_stdin "$tmpdir/t15.md"
if [[ "$EC" -eq 1 ]]; then ok "empty evidence caught even with escaped pipe in command"; else bad "expected 1, got $EC; out: $(cat "$tmpdir/out")"; fi

# ---------- Test 16: case-insensitive verdicts ----------
say "Test 16: lowercase verdicts (pass/fail/unverified) accepted"
cat > "$tmpdir/t16.md" <<'EOF'
| # | Assertion | Command | Expected | Verdict | Evidence |
|---|---|---|---|---|---|
| 1 | a | `cmd1` | ok | pass | `cmd1` -> ok |
| 2 | b | `cmd2` | ok | fail |  |
| 3 | c | `cmd3` | ok | unverified |  |
EOF
run_stdin "$tmpdir/t16.md"
if [[ "$EC" -eq 0 ]]; then ok "lowercase verdicts accepted"; else bad "expected 0, got $EC; out: $(cat "$tmpdir/out")"; fi

# ---------- Test 17: contract embedded in a full file with prose around it -> exit 0 ----------
say "Test 17: contract table embedded in a realistic full file -> exit 0"
cat > "$tmpdir/t17.md" <<'EOF'
# Validation contract — #255

> Written BEFORE implementation. Each assertion names the command that proves it.

Some context about the ticket here.

| # | Assertion | Command | Expected | Verdict | Evidence |
|---|---|---|---|---|---|
| 1 | helper works | `bash scripts/test-validate-contract.sh` | OK | PASS | ran it -> OK (N passed) |

Trailing notes after the table.
EOF
run_stdin "$tmpdir/t17.md"
if [[ "$EC" -eq 0 ]]; then ok "embedded contract validates"; else bad "expected 0, got $EC; out: $(cat "$tmpdir/out")"; fi

# ---------- Test 18: --help -> exit 0 ----------
say "Test 18: --help -> exit 0"
set +e
NO_COLOR=1 bash "$CHECK" --help > "$tmpdir/out" 2>&1
EC=$?
set -e
if [[ "$EC" -eq 0 ]] && grep -qi "usage" "$tmpdir/out"; then ok "--help exits 0 with usage"; else bad "expected 0 + usage, got $EC; out: $(cat "$tmpdir/out")"; fi

# ---------- summary ----------
echo ""
echo "============================================================"
if [[ "$failed" -eq 0 ]]; then
  printf "${C_GREEN}${C_BOLD}test-validate-contract: OK${C_RESET} (%d passed)\n" "$passed"
  exit 0
fi
printf "${C_RED}${C_BOLD}test-validate-contract: FAIL${C_RESET} (%d passed, %d failed)\n" \
  "$passed" "$failed" >&2
exit 1

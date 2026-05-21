#!/usr/bin/env bash
#
# test-validate-evidence-table.sh — regression test for
# scripts/validate-evidence-table.sh (ticket #196, evidence-based review gate).
#
# Proves the EVIDENCE TABLE template enforces the hard rule: no criterion gets a
# clean PASS without concrete evidence. The headline assertion (Test 2) is that a
# review marking a criterion PASS with an empty Evidence cell is REJECTED.
#
# Exercises:
#   - Valid table (every PASS has evidence)                 -> exit 0
#   - PASS with empty Evidence cell                          -> exit 1  (core rule)
#   - PASS with placeholder evidence (-, n/a, none, ``)      -> exit 1
#   - UNVERIFIED with no evidence                            -> exit 0  (allowed)
#   - FAIL with no evidence                                  -> exit 0  (allowed)
#   - Illegal verdict (MAYBE)                                -> exit 1
#   - Zero criterion rows                                    -> exit 1
#   - No / garbled table header                              -> exit 2
#   - Reads a full review-comment body (table embedded)      -> exit 0
#   - --file <path> path                                     -> exit 0
#   - trace:<id> evidence (forward-compat for #197)          -> exit 0
#   - --help                                                 -> exit 0
#
# Style: matches scripts/test-check-claude-md-size.sh (bash, colored output,
# pass/fail counter, no external test harness). Spec:
# docs/specs/2026-05-21-evidence-based-review-gate.md

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CHECK="$SCRIPT_DIR/validate-evidence-table.sh"

if [[ ! -f "$CHECK" ]]; then
  echo "test-validate-evidence-table: $CHECK not found" >&2
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

# run_stdin <fixture-file>  -> sets global EC to the checker's exit code,
# captures stdout+stderr in $tmpdir/out.
run_stdin() {
  local fixture="$1"
  set +e
  NO_COLOR=1 bash "$CHECK" < "$fixture" > "$tmpdir/out" 2>&1
  EC=$?
  set -e
}

# A valid evidence table body (used as the baseline + edited per test).
valid_table() {
  cat <<'EOF'
Commander review of PR #42

**Acceptance criteria — evidence**

| # | Criterion | Verdict | Evidence |
|---|---|---|---|
| 1 | Endpoint returns 200 on health | PASS | `curl localhost:3000/health` -> `{"ok":true}` 200 |
| 2 | New flag parses | PASS | test `parses --flag` -> `1 passed`; diff `scripts/x.sh:42` |
| 3 | Migration is reversible | UNVERIFIED | needs a live DB; no fixture in this PR |

**Blockers** (must fix before merge)
- (none)
EOF
}

# ---------- Test 1: valid table -> exit 0 ----------
say "Test 1: valid table (every PASS has evidence) -> exit 0"
valid_table > "$tmpdir/t1.md"
run_stdin "$tmpdir/t1.md"
if [[ "$EC" -eq 0 ]]; then ok "exit 0"; else bad "expected 0, got $EC; out: $(cat "$tmpdir/out")"; fi

# ---------- Test 2: PASS without evidence -> exit 1 (THE core rule) ----------
say "Test 2: a criterion marked PASS with an EMPTY Evidence cell -> exit 1 (rejected)"
cat > "$tmpdir/t2.md" <<'EOF'
Commander review of PR #42

| # | Criterion | Verdict | Evidence |
|---|---|---|---|
| 1 | Endpoint returns 200 on health | PASS |  |
| 2 | New flag parses | PASS | test `parses --flag` -> `1 passed` |
EOF
run_stdin "$tmpdir/t2.md"
if [[ "$EC" -eq 1 ]]; then
  ok "PASS-without-evidence is rejected (exit 1)"
else
  bad "expected exit 1 for PASS without evidence, got $EC; out: $(cat "$tmpdir/out")"
fi
if grep -qiE "row 1|criterion 1|PASS.*evidence|evidence.*PASS" "$tmpdir/out"; then
  ok "stderr names the offending PASS row"
else
  bad "expected the offending row named in output; got: $(cat "$tmpdir/out")"
fi
# The well-formed row 2 must NOT be flagged.
if grep -qiE "row 2" "$tmpdir/out"; then
  bad "row 2 (valid PASS w/ evidence) should not be flagged; got: $(cat "$tmpdir/out")"
else
  ok "valid PASS row is not flagged"
fi

# ---------- Test 3: PASS with placeholder evidence -> exit 1 ----------
say "Test 3: PASS rows with placeholder evidence (-, n/a, none, backticks) -> exit 1"
for ph in "-" "n/a" "N/A" "none" "None" '``' "   "; do
  cat > "$tmpdir/t3.md" <<EOF
Commander review of PR #42

| # | Criterion | Verdict | Evidence |
|---|---|---|---|
| 1 | Some criterion | PASS | $ph |
EOF
  run_stdin "$tmpdir/t3.md"
  if [[ "$EC" -eq 1 ]]; then
    ok "placeholder evidence '$ph' rejected (exit 1)"
  else
    bad "expected exit 1 for placeholder '$ph', got $EC; out: $(cat "$tmpdir/out")"
  fi
done

# ---------- Test 4: UNVERIFIED with no evidence -> exit 0 ----------
say "Test 4: UNVERIFIED row with an empty Evidence cell -> exit 0 (allowed)"
cat > "$tmpdir/t4.md" <<'EOF'
Commander review of PR #42

| # | Criterion | Verdict | Evidence |
|---|---|---|---|
| 1 | Needs production data | UNVERIFIED |  |
EOF
run_stdin "$tmpdir/t4.md"
if [[ "$EC" -eq 0 ]]; then ok "UNVERIFIED without evidence allowed"; else bad "expected 0, got $EC; out: $(cat "$tmpdir/out")"; fi

# ---------- Test 5: FAIL with no evidence -> exit 0 ----------
say "Test 5: FAIL row with an empty Evidence cell -> exit 0 (allowed)"
cat > "$tmpdir/t5.md" <<'EOF'
Commander review of PR #42

| # | Criterion | Verdict | Evidence |
|---|---|---|---|
| 1 | Returns 200 | FAIL |  |
EOF
run_stdin "$tmpdir/t5.md"
if [[ "$EC" -eq 0 ]]; then ok "FAIL without evidence allowed"; else bad "expected 0, got $EC; out: $(cat "$tmpdir/out")"; fi

# ---------- Test 6: illegal verdict -> exit 1 ----------
say "Test 6: illegal verdict (MAYBE) -> exit 1"
cat > "$tmpdir/t6.md" <<'EOF'
Commander review of PR #42

| # | Criterion | Verdict | Evidence |
|---|---|---|---|
| 1 | Something | MAYBE | some evidence here |
EOF
run_stdin "$tmpdir/t6.md"
if [[ "$EC" -eq 1 ]]; then ok "illegal verdict rejected"; else bad "expected 1, got $EC; out: $(cat "$tmpdir/out")"; fi
if grep -qiE "MAYBE|verdict" "$tmpdir/out"; then ok "names the bad verdict"; else bad "expected verdict named; got: $(cat "$tmpdir/out")"; fi

# ---------- Test 7: zero criterion rows -> exit 1 ----------
say "Test 7: header present but zero data rows -> exit 1"
cat > "$tmpdir/t7.md" <<'EOF'
Commander review of PR #42

| # | Criterion | Verdict | Evidence |
|---|---|---|---|

**Blockers**
- (none)
EOF
run_stdin "$tmpdir/t7.md"
if [[ "$EC" -eq 1 ]]; then ok "zero-criteria table rejected"; else bad "expected 1, got $EC; out: $(cat "$tmpdir/out")"; fi

# ---------- Test 8: no/garbled table header -> exit 2 ----------
say "Test 8: body with NO evidence table -> exit 2 (parse error)"
cat > "$tmpdir/t8.md" <<'EOF'
Commander review of PR #42

**Blockers**
- (none)

Just a free-form review, no evidence table at all.
EOF
run_stdin "$tmpdir/t8.md"
if [[ "$EC" -eq 2 ]]; then ok "missing table -> exit 2"; else bad "expected 2, got $EC; out: $(cat "$tmpdir/out")"; fi

# ---------- Test 9: full review-comment body with the table embedded -> exit 0 ----------
say "Test 9: realistic full comment (header + table + Blockers/Concerns/Nits) -> exit 0"
cat > "$tmpdir/t9.md" <<'EOF'
Commander review of PR #42

**Acceptance criteria — evidence**

| # | Criterion | Verdict | Evidence |
|---|---|---|---|
| 1 | digest command added | PASS | test `digest channel` -> `4 passed`; diff `scripts/build-daily-digest.sh:1` |
| 2 | composer renders sections | PASS | `bash scripts/build-daily-digest.sh --dry-run` -> non-empty digest |
| 3 | autopickup step-1.6 hook fires | UNVERIFIED | scheduler not exercised in CI |

**Blockers** (must fix before merge)
- (none)

**Concerns** (should address)
- (none)

**Nits** (optional polish)
- (none)

**Signed-off by** commander-review · skills run: /review, /codex review
EOF
run_stdin "$tmpdir/t9.md"
if [[ "$EC" -eq 0 ]]; then ok "full comment with valid table -> exit 0"; else bad "expected 0, got $EC; out: $(cat "$tmpdir/out")"; fi

# ---------- Test 10: --file <path> path ----------
say "Test 10: --file <path> reads the body from a file -> exit 0"
set +e
NO_COLOR=1 bash "$CHECK" --file "$tmpdir/t9.md" > "$tmpdir/out" 2>&1
EC=$?
set -e
if [[ "$EC" -eq 0 ]]; then ok "--file path works"; else bad "expected 0, got $EC; out: $(cat "$tmpdir/out")"; fi

# ---------- Test 11: trace:<id> evidence (forward-compat for #197) ----------
say "Test 11: a PASS whose ONLY evidence is trace:<id> -> exit 0 (#197 forward-compat)"
cat > "$tmpdir/t11.md" <<'EOF'
Commander review of PR #42

| # | Criterion | Verdict | Evidence |
|---|---|---|---|
| 1 | session does the thing | PASS | trace:abc123 |
EOF
run_stdin "$tmpdir/t11.md"
if [[ "$EC" -eq 0 ]]; then
  ok "trace:<id> counts as evidence -> no checker change needed for #197"
else
  bad "expected 0 for trace: evidence, got $EC; out: $(cat "$tmpdir/out")"
fi

# ---------- Test 12: --help -> exit 0 ----------
say "Test 12: --help -> exit 0"
set +e
NO_COLOR=1 bash "$CHECK" --help > "$tmpdir/out" 2>&1
EC=$?
set -e
if [[ "$EC" -eq 0 ]] && grep -qi "usage" "$tmpdir/out"; then ok "--help exits 0 with usage"; else bad "expected 0 + usage, got $EC; out: $(cat "$tmpdir/out")"; fi

# ---------- Test 13: case-insensitive verdicts ----------
say "Test 13: lowercase verdicts (pass/fail/unverified) accepted"
cat > "$tmpdir/t13.md" <<'EOF'
Commander review of PR #42

| # | Criterion | Verdict | Evidence |
|---|---|---|---|
| 1 | a | pass | `cmd` -> ok |
| 2 | b | fail |  |
| 3 | c | unverified |  |
EOF
run_stdin "$tmpdir/t13.md"
if [[ "$EC" -eq 0 ]]; then ok "lowercase verdicts accepted"; else bad "expected 0, got $EC; out: $(cat "$tmpdir/out")"; fi

# ---------- Test 14: escaped pipe (\|) inside a cell does NOT shift columns ----------
# A criterion or evidence cell with a shell pipeline must escape the pipe as \|
# (GitHub renders it literally). The splitter must treat \| as content, so the
# verdict column stays PASS and the row validates. Regression for the codex P2.
say "Test 14: escaped pipe \\| in Criterion AND Evidence cells -> exit 0 (no column shift)"
cat > "$tmpdir/t14.md" <<'EOF'
Commander review of PR #42

| # | Criterion | Verdict | Evidence |
|---|---|---|---|
| 1 | counts matching lines with `grep x \| wc -l` | PASS | ran `grep x f \| wc -l` -> `3` |
EOF
run_stdin "$tmpdir/t14.md"
if [[ "$EC" -eq 0 ]]; then
  ok "escaped pipes kept as content; verdict column not shifted (exit 0)"
else
  bad "expected exit 0 for escaped-pipe row, got $EC; out: $(cat "$tmpdir/out")"
fi

# ---------- Test 15: escaped pipe must NOT smuggle empty evidence past the gate ----------
# `\|` is restored as a literal pipe, which is NOT a placeholder, so a PASS whose
# evidence is only an escaped pipe is still treated as having content. But a PASS
# with a genuinely empty evidence cell that merely has \| in the CRITERION must
# still be caught.
say "Test 15: \\| in Criterion but EMPTY Evidence on a PASS row -> exit 1 (still caught)"
cat > "$tmpdir/t15.md" <<'EOF'
Commander review of PR #42

| # | Criterion | Verdict | Evidence |
|---|---|---|---|
| 1 | pipeline `a \| b` works | PASS |  |
EOF
run_stdin "$tmpdir/t15.md"
if [[ "$EC" -eq 1 ]]; then
  ok "empty evidence still caught even when criterion has an escaped pipe"
else
  bad "expected exit 1 (empty evidence), got $EC; out: $(cat "$tmpdir/out")"
fi

# ---------- summary ----------
echo ""
echo "============================================================"
if [[ "$failed" -eq 0 ]]; then
  printf "${C_GREEN}${C_BOLD}test-validate-evidence-table: OK${C_RESET} (%d passed)\n" "$passed"
  exit 0
fi
printf "${C_RED}${C_BOLD}test-validate-evidence-table: FAIL${C_RESET} (%d passed, %d failed)\n" \
  "$passed" "$failed" >&2
exit 1

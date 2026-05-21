#!/usr/bin/env bash
#
# test-validate-security-findings.sh — regression test for
# scripts/validate-security-findings.sh (ticket #199, adversarial/consensus
# review pass for security-sensitive PRs).
#
# Proves the FINDINGS TABLE enforces the load-bearing HARD RULE: unanimity is
# not confidence. A security finding is REPORTED (i.e. reaches the operator as a
# SECURITY: blocker) only if it SURVIVED the adversarial critic's kill mandate
# AND carries an empirical oracle (a PoC / failing test / reproduction). A
# finding the critic REFUTED, or one with no oracle, must be DROPPED.
#
# Headline assertion (Test 1, the ticket's "test for real"): a non-reproducible
# finding is DROPPED while a PoC-backed one is KEPT; flipping the non-reproducible
# one to REPORTED is REJECTED.
#
# Exercises:
#   - Non-reproducible DROPPED + PoC-backed REPORTED         -> exit 0 (headline)
#     ...then flip the non-reproducible one to REPORTED      -> exit 1
#   - Valid table (every REPORTED is SURVIVED + has oracle)  -> exit 0
#   - REPORTED with empty Oracle                              -> exit 1
#   - REPORTED with placeholder oracle (-, n/a, none, ``)     -> exit 1
#   - REPORTED + REFUTED (critic disproved it)               -> exit 1
#   - DROPPED + REFUTED + no oracle                           -> exit 0 (safe)
#   - DROPPED + SURVIVED + no oracle (not promoted)           -> exit 0
#   - Illegal critic verdict (MAYBE)                         -> exit 1
#   - Illegal disposition (ESCALATE)                         -> exit 1
#   - Zero finding rows                                       -> exit 1
#   - No / garbled table header                               -> exit 2
#   - --file <path> path                                      -> exit 0
#   - Oracle containing an escaped pipe (curl ... \| grep)    -> exit 0
#   - Full comment with BOTH #196 evidence + #199 findings    -> exit 0
#   - --help                                                  -> exit 0
#
# Style: matches scripts/test-validate-evidence-table.sh (bash, colored output,
# pass/fail counter, no external test harness). Spec:
# docs/specs/2026-05-21-adversarial-consensus-review.md

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CHECK="$SCRIPT_DIR/validate-security-findings.sh"

if [[ ! -f "$CHECK" ]]; then
  echo "test-validate-security-findings: $CHECK not found" >&2
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

# run_stdin <fixture-file> -> sets global EC, captures stdout+stderr in out.
run_stdin() {
  local fixture="$1"
  set +e
  NO_COLOR=1 bash "$CHECK" < "$fixture" > "$tmpdir/out" 2>&1
  EC=$?
  set -e
}

# ---------- Test 1: HEADLINE — non-reproducible DROPPED, PoC-backed KEPT ----------
say "Test 1 (headline): a non-reproducible finding is DROPPED, a PoC-backed one is KEPT -> exit 0"
cat > "$tmpdir/t1a.md" <<'EOF'
Commander review of PR #42

**Security findings — adversarial pass (kill mandate)**

| # | Finding | Critic verdict | Oracle | Disposition |
|---|---|---|---|---|
| 1 | SQL injection via `name` query param | SURVIVED | PoC `curl 'localhost/u?name=%27;DROP--'` -> 500 + SQL stacktrace | REPORTED |
| 2 | Possible timing leak on token compare | SURVIVED | (none) | DROPPED |
EOF
run_stdin "$tmpdir/t1a.md"
if [[ "$EC" -eq 0 ]]; then
  ok "PoC-backed finding KEPT (REPORTED), non-reproducible finding DROPPED -> exit 0"
else
  bad "expected 0, got $EC; out: $(cat "$tmpdir/out")"
fi

say "Test 1b (headline flip): the non-reproducible finding marked REPORTED -> exit 1 (rejected)"
cat > "$tmpdir/t1b.md" <<'EOF'
Commander review of PR #42

| # | Finding | Critic verdict | Oracle | Disposition |
|---|---|---|---|---|
| 1 | SQL injection via `name` query param | SURVIVED | PoC `curl 'localhost/u?name=%27;DROP--'` -> 500 + SQL stacktrace | REPORTED |
| 2 | Possible timing leak on token compare | SURVIVED |  | REPORTED |
EOF
run_stdin "$tmpdir/t1b.md"
if [[ "$EC" -eq 1 ]]; then
  ok "non-reproducible finding cannot be REPORTED (exit 1) — unanimity is not confidence"
else
  bad "expected 1 for REPORTED-without-oracle, got $EC; out: $(cat "$tmpdir/out")"
fi
if grep -qiE "row 2|finding 2|oracle" "$tmpdir/out"; then
  ok "stderr names the offending row / the missing oracle"
else
  bad "expected the offending row named; got: $(cat "$tmpdir/out")"
fi
if grep -qiE "row 1" "$tmpdir/out"; then
  bad "row 1 (valid REPORTED w/ PoC) should not be flagged; got: $(cat "$tmpdir/out")"
else
  ok "valid REPORTED row is not flagged"
fi

# ---------- Test 2: valid table -> exit 0 ----------
say "Test 2: valid table (every REPORTED is SURVIVED + has oracle) -> exit 0"
cat > "$tmpdir/t2.md" <<'EOF'
Commander review of PR #42

| # | Finding | Critic verdict | Oracle | Disposition |
|---|---|---|---|---|
| 1 | Auth bypass on empty JWT | SURVIVED | failing test `rejects empty jwt` -> `1 failed` pre-fix | REPORTED |
| 2 | Path traversal in upload | SURVIVED | PoC `../../etc/passwd` written outside bucket | REPORTED |
| 3 | Weak hash (md5) for password | REFUTED | critic: hash is argon2id, diff `auth/hash.ts:12` | DROPPED |
EOF
run_stdin "$tmpdir/t2.md"
if [[ "$EC" -eq 0 ]]; then ok "exit 0"; else bad "expected 0, got $EC; out: $(cat "$tmpdir/out")"; fi

# ---------- Test 3: REPORTED with empty Oracle -> exit 1 ----------
say "Test 3: a REPORTED finding with an EMPTY Oracle cell -> exit 1 (opinion is not confidence)"
cat > "$tmpdir/t3.md" <<'EOF'
Commander review of PR #42

| # | Finding | Critic verdict | Oracle | Disposition |
|---|---|---|---|---|
| 1 | Looks exploitable to me | SURVIVED |  | REPORTED |
EOF
run_stdin "$tmpdir/t3.md"
if [[ "$EC" -eq 1 ]]; then ok "REPORTED-without-oracle rejected (exit 1)"; else bad "expected 1, got $EC; out: $(cat "$tmpdir/out")"; fi
if grep -qiE "row 1|oracle" "$tmpdir/out"; then ok "names the offending row / oracle"; else bad "expected row named; got: $(cat "$tmpdir/out")"; fi

# ---------- Test 4: REPORTED with placeholder oracle -> exit 1 ----------
say "Test 4: REPORTED rows with placeholder oracle (-, n/a, none, backticks) -> exit 1"
for ph in "-" "n/a" "N/A" "none" "None" '``' "   "; do
  cat > "$tmpdir/t4.md" <<EOF
Commander review of PR #42

| # | Finding | Critic verdict | Oracle | Disposition |
|---|---|---|---|---|
| 1 | Some finding | SURVIVED | $ph | REPORTED |
EOF
  run_stdin "$tmpdir/t4.md"
  if [[ "$EC" -eq 1 ]]; then
    ok "placeholder oracle '$ph' rejected (exit 1)"
  else
    bad "expected 1 for placeholder '$ph', got $EC; out: $(cat "$tmpdir/out")"
  fi
done

# ---------- Test 5: REPORTED + REFUTED -> exit 1 ----------
say "Test 5: a REPORTED finding the critic REFUTED -> exit 1 (would page operator on a non-finding)"
cat > "$tmpdir/t5.md" <<'EOF'
Commander review of PR #42

| # | Finding | Critic verdict | Oracle | Disposition |
|---|---|---|---|---|
| 1 | XSS in render | REFUTED | critic: output is escaped, diff `view.ts:9` | REPORTED |
EOF
run_stdin "$tmpdir/t5.md"
if [[ "$EC" -eq 1 ]]; then ok "REPORTED+REFUTED rejected (exit 1)"; else bad "expected 1, got $EC; out: $(cat "$tmpdir/out")"; fi
if grep -qiE "refuted|row 1" "$tmpdir/out"; then ok "names the refuted-but-reported row"; else bad "expected row named; got: $(cat "$tmpdir/out")"; fi

# ---------- Test 6: DROPPED + REFUTED + no oracle -> exit 0 ----------
say "Test 6: DROPPED + REFUTED + no oracle -> exit 0 (the safe path)"
cat > "$tmpdir/t6.md" <<'EOF'
Commander review of PR #42

| # | Finding | Critic verdict | Oracle | Disposition |
|---|---|---|---|---|
| 1 | Suspected CSRF | REFUTED | critic: same-site cookie set, diff `app.ts:3` | DROPPED |
EOF
run_stdin "$tmpdir/t6.md"
if [[ "$EC" -eq 0 ]]; then ok "disproven + dropped allowed"; else bad "expected 0, got $EC; out: $(cat "$tmpdir/out")"; fi

# ---------- Test 7: DROPPED + SURVIVED + no oracle -> exit 0 ----------
say "Test 7: DROPPED + SURVIVED + no oracle -> exit 0 (survived critique but not promoted)"
cat > "$tmpdir/t7.md" <<'EOF'
Commander review of PR #42

| # | Finding | Critic verdict | Oracle | Disposition |
|---|---|---|---|---|
| 1 | Maybe a race on session refresh | SURVIVED |  | DROPPED |
EOF
run_stdin "$tmpdir/t7.md"
if [[ "$EC" -eq 0 ]]; then ok "survived-but-no-oracle correctly dropped"; else bad "expected 0, got $EC; out: $(cat "$tmpdir/out")"; fi

# ---------- Test 8: illegal critic verdict -> exit 1 ----------
say "Test 8: illegal critic verdict (MAYBE) -> exit 1"
cat > "$tmpdir/t8.md" <<'EOF'
Commander review of PR #42

| # | Finding | Critic verdict | Oracle | Disposition |
|---|---|---|---|---|
| 1 | Something | MAYBE | some oracle | DROPPED |
EOF
run_stdin "$tmpdir/t8.md"
if [[ "$EC" -eq 1 ]]; then ok "illegal critic verdict rejected"; else bad "expected 1, got $EC; out: $(cat "$tmpdir/out")"; fi
if grep -qiE "MAYBE|verdict" "$tmpdir/out"; then ok "names the bad verdict"; else bad "expected verdict named; got: $(cat "$tmpdir/out")"; fi

# ---------- Test 9: illegal disposition -> exit 1 ----------
say "Test 9: illegal disposition (ESCALATE) -> exit 1"
cat > "$tmpdir/t9.md" <<'EOF'
Commander review of PR #42

| # | Finding | Critic verdict | Oracle | Disposition |
|---|---|---|---|---|
| 1 | Something | SURVIVED | a real oracle | ESCALATE |
EOF
run_stdin "$tmpdir/t9.md"
if [[ "$EC" -eq 1 ]]; then ok "illegal disposition rejected"; else bad "expected 1, got $EC; out: $(cat "$tmpdir/out")"; fi
if grep -qiE "ESCALATE|disposition" "$tmpdir/out"; then ok "names the bad disposition"; else bad "expected disposition named; got: $(cat "$tmpdir/out")"; fi

# ---------- Test 10: zero finding rows -> exit 1 ----------
say "Test 10: header present but zero data rows -> exit 1"
cat > "$tmpdir/t10.md" <<'EOF'
Commander review of PR #42

| # | Finding | Critic verdict | Oracle | Disposition |
|---|---|---|---|---|

**Blockers**
- (none)
EOF
run_stdin "$tmpdir/t10.md"
if [[ "$EC" -eq 1 ]]; then ok "zero-findings table rejected"; else bad "expected 1, got $EC; out: $(cat "$tmpdir/out")"; fi

# ---------- Test 11: no/garbled header -> exit 2 ----------
say "Test 11: body with NO findings table -> exit 2 (parse error)"
cat > "$tmpdir/t11.md" <<'EOF'
Commander review of PR #42

**Blockers**
- (none)

Free-form review, no findings table at all.
EOF
run_stdin "$tmpdir/t11.md"
if [[ "$EC" -eq 2 ]]; then ok "missing table -> exit 2"; else bad "expected 2, got $EC; out: $(cat "$tmpdir/out")"; fi

# ---------- Test 12: --file <path> path ----------
say "Test 12: --file <path> reads the body from a file -> exit 0"
set +e
NO_COLOR=1 bash "$CHECK" --file "$tmpdir/t2.md" > "$tmpdir/out" 2>&1
EC=$?
set -e
if [[ "$EC" -eq 0 ]]; then ok "--file path works"; else bad "expected 0, got $EC; out: $(cat "$tmpdir/out")"; fi

# ---------- Test 13: oracle containing an escaped pipe -> exit 0 ----------
say "Test 13: REPORTED oracle with an escaped pipe (curl ... \\| grep) -> exit 0 (no column shift)"
cat > "$tmpdir/t13.md" <<'EOF'
Commander review of PR #42

| # | Finding | Critic verdict | Oracle | Disposition |
|---|---|---|---|---|
| 1 | Cmd injection via filename | SURVIVED | PoC `printf x \| sh -c 'cat /etc/passwd'` -> leaked | REPORTED |
EOF
run_stdin "$tmpdir/t13.md"
if [[ "$EC" -eq 0 ]]; then ok "escaped pipe in oracle handled (exit 0)"; else bad "expected 0, got $EC; out: $(cat "$tmpdir/out")"; fi

# ---------- Test 14: full comment with BOTH #196 + #199 tables -> exit 0 ----------
say "Test 14: full comment with #196 evidence table AND #199 findings table -> exit 0 (coexist)"
cat > "$tmpdir/t14.md" <<'EOF'
Commander review of PR #42

**Acceptance criteria — evidence**

| # | Criterion | Verdict | Evidence |
|---|---|---|---|
| 1 | auth middleware rejects empty token | PASS | test `rejects empty` -> `1 passed` |
| 2 | migration is reversible | UNVERIFIED | needs a live DB |

**Security findings — adversarial pass (kill mandate)**

| # | Finding | Critic verdict | Oracle | Disposition |
|---|---|---|---|---|
| 1 | Auth bypass on empty JWT | SURVIVED | failing test `rejects empty jwt` -> `1 failed` pre-fix | REPORTED |
| 2 | Weak hash | REFUTED | critic: argon2id, diff `auth/hash.ts:12` | DROPPED |

**Blockers** (must fix before merge)
- SECURITY: Auth bypass on empty JWT — auth/jwt.ts:30

**Signed-off by** commander-review · skills run: /review, /codex review, /cso
EOF
run_stdin "$tmpdir/t14.md"
if [[ "$EC" -eq 0 ]]; then ok "findings checker validates only its table; both tables coexist"; else bad "expected 0, got $EC; out: $(cat "$tmpdir/out")"; fi

# ---------- Test 15: --help -> exit 0 ----------
say "Test 15: --help -> exit 0"
set +e
NO_COLOR=1 bash "$CHECK" --help > "$tmpdir/out" 2>&1
EC=$?
set -e
if [[ "$EC" -eq 0 ]] && grep -qi "usage" "$tmpdir/out"; then ok "--help exits 0 with usage"; else bad "expected 0 + usage, got $EC; out: $(cat "$tmpdir/out")"; fi

# ---------- summary ----------
echo
echo "============================================================"
if [[ "$failed" -eq 0 ]]; then
  printf "${C_GREEN}${C_BOLD}test-validate-security-findings: OK${C_RESET} (%d passed)\n" "$passed"
  exit 0
else
  printf "${C_RED}${C_BOLD}test-validate-security-findings: FAIL${C_RESET} (%d passed, %d failed)\n" "$passed" "$failed"
  exit 1
fi

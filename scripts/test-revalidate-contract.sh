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
#   - #310 (a) well-formed self-contained row                        -> exit 0
#   - #310 (b) exit code in Expected PROSE (#309 repro) no false MM   -> exit 0
#   - #310 (c) non-runnable Command (#307 repro) AUTHORING-ERROR      -> exit 3
#   - #310 (d) genuine wrong exit STILL a MISMATCH (no-regression)    -> exit 1
#   - #310 over-flagging guards (bound/env/loop var, quoted markup)   -> exit 0
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

# run_utf8_ctype <args...> -> like run(), but forces a UTF-8 LC_CTYPE so the
# byte-wise-tr regression (Test 15) reproduces deterministically regardless of
# the CI runner's ambient locale. On a UTF-8 LC_CTYPE, BSD/macOS `tr` throws
# "Illegal byte sequence" on bytes that are not valid in that encoding — which
# arbitrary command output routinely contains (e.g. a multibyte char truncated
# at the head -c 200 boundary). Picks the first available UTF-8 locale; sets
# UTF8_LOCALE="" if none exists (caller skips the strict leg).
UTF8_LOCALE="$(locale -a 2>/dev/null | grep -iE '\.UTF-?8$' | head -1 || true)"
run_utf8_ctype() {
  set +e
  LC_ALL="$UTF8_LOCALE" NO_COLOR=1 bash "$CHECK" "$@" > "$tmpdir/out" 2>&1
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
# Includes one real PASS row so the contract has a re-run (>=1) and is not
# rejected by the zero-run guard (#256 review); the assertion under test is that
# the UNVERIFIED row's command is never executed and never fails the gate.
say "Test 6: UNVERIFIED row is SKIPPED (command never run) -> exit 0"
cat > "$tmpdir/t6.md" <<'EOF'
| # | Assertion | Command | Expected | Verdict | Evidence |
|---|---|---|---|---|---|
| 1 | a real check runs | `sh -c 'exit 0'` | exit 0 | PASS | ran it -> exit 0 |
| 2 | needs prod data | `sh -c 'echo SHOULD_NOT_RUN; exit 7'` | rollback | UNVERIFIED | no live DB |
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

# ---------- Test 15: UTF-8 command output does not crash the snippet capture ----------
# Regression for the LC_ALL=C / "Illegal byte sequence" bug (#256): the re-run's
# ACTUAL output is arbitrary and may contain multibyte UTF-8 (e.g. the self-test's
# ━ / ✓ glyphs). The snippet capture `head -c 200 | tr '\n' ' '` runs `tr` under
# the worker's ambient (UTF-8) LC_CTYPE; BSD/macOS `tr` then throws
# "Illegal byte sequence" on bytes invalid in that encoding — including a
# multibyte char truncated at the 200-byte boundary — and pipefail+set -e crash
# the whole gate with a false FAIL on a valid PASS row. The 19-case suite missed
# this because every fixture emits only ASCII. Fix: prefix `LC_ALL=C` so `tr`
# operates byte-wise and never errors. This test is RED before the fix, GREEN after.
say "Test 15: assertion command emits UTF-8 -> correct verdict, no 'Illegal byte sequence' crash"
# 15a: short UTF-8 line (glyphs sit well inside the 200-byte snippet window).
cat > "$tmpdir/t15a.md" <<'EOF'
| # | Assertion | Command | Expected | Verdict | Evidence |
|---|---|---|---|---|---|
| 1 | emits a utf8 banner | `printf '%s\n' '━ ✓ done'` | exit 0 | PASS | ran it -> ━ ✓ done |
EOF
run_utf8_ctype --file "$tmpdir/t15a.md" --cwd "$tmpdir"
if [[ "$EC" -eq 0 ]]; then ok "UTF-8 output (short) -> exit 0 (PASS reproduced)"; else bad "expected 0, got $EC; out: $(cat "$tmpdir/out")"; fi
if grep -qi "Illegal byte sequence" "$tmpdir/out"; then bad "tr threw 'Illegal byte sequence' on UTF-8 output"; else ok "no 'Illegal byte sequence' in output"; fi

# 15b: a multibyte char straddling the head -c 200 truncation boundary — the
# deterministic trigger. 199 'a's + '━' (3 bytes e2 94 80): head -c 200 keeps
# 199 'a's + lone 0xe2, an invalid UTF-8 sequence that makes a locale-aware `tr` error.
cat > "$tmpdir/t15b.md" <<'EOF'
| # | Assertion | Command | Expected | Verdict | Evidence |
|---|---|---|---|---|---|
| 1 | utf8 char on the 200-byte boundary | `sh -c 'for i in $(seq 1 199); do printf a; done; printf "━ done\n"'` | exit 0 | PASS | ran it -> done |
EOF
run_utf8_ctype --file "$tmpdir/t15b.md" --cwd "$tmpdir"
if [[ "$EC" -eq 0 ]]; then ok "UTF-8 char on truncation boundary -> exit 0 (no crash)"; else bad "expected 0, got $EC; out: $(cat "$tmpdir/out")"; fi
if grep -qi "Illegal byte sequence" "$tmpdir/out"; then bad "tr threw 'Illegal byte sequence' on boundary-truncated multibyte"; else ok "no 'Illegal byte sequence' on boundary-truncated multibyte"; fi

# 15c: raw non-UTF-8 byte (0xff) in output — arbitrary binary always trips a
# locale-aware tr; byte-wise tr must pass it through unharmed.
cat > "$tmpdir/t15c.md" <<'EOF'
| # | Assertion | Command | Expected | Verdict | Evidence |
|---|---|---|---|---|---|
| 1 | emits a raw non-utf8 byte | `printf 'a\377b\n'` | exit 0 | PASS | ran it |
EOF
run_utf8_ctype --file "$tmpdir/t15c.md" --cwd "$tmpdir"
if [[ "$EC" -eq 0 ]]; then ok "raw 0xff byte in output -> exit 0 (no crash)"; else bad "expected 0, got $EC; out: $(cat "$tmpdir/out")"; fi
if grep -qi "Illegal byte sequence" "$tmpdir/out"; then bad "tr threw 'Illegal byte sequence' on raw 0xff byte"; else ok "no 'Illegal byte sequence' on raw 0xff byte"; fi

# ---------- Test 16: ZERO re-runs must NOT certify (correctness hole #256 review) ----------
# A truth-checker that ran nothing must never report success. A contract whose
# rows are all UNVERIFIED / prose-only (no claimed-PASS command actually runs)
# has ran == 0. Exiting 0/VALIDATED there is a lie: nothing was verified. The
# gate must reject it (nonzero) with an explicit no-runs verdict.
say "Test 16: all-UNVERIFIED contract (zero re-runs) is NOT certified -> nonzero"
cat > "$tmpdir/t16.md" <<'EOF'
| # | Assertion | Command | Expected | Verdict | Evidence |
|---|---|---|---|---|---|
| 1 | needs prod data | `psql -f up.sql` | clean apply | UNVERIFIED | no live DB in worker scope |
| 2 | needs prod data | `psql -f down.sql` | clean rollback | UNVERIFIED | no live DB in worker scope |
EOF
run --file "$tmpdir/t16.md"
if [[ "$EC" -ne 0 ]]; then ok "zero-run contract rejected (exit $EC, not 0)"; else bad "zero-run contract WRONGLY certified (exit 0); out: $(cat "$tmpdir/out")"; fi
if grep -qiE "no.?runs?|nothing|unvalidated|zero" "$tmpdir/out"; then ok "emits an explicit no-runs verdict"; else bad "expected an explicit no-runs/UNVALIDATED verdict; out: $(cat "$tmpdir/out")"; fi

# 16b: a single prose-only row with no parseable command verdict still counts as
# zero re-runs when SKIPPED — but a normal PASS row that DID run must keep exit 0
# (guard: the zero-run rule must not regress an honest single-PASS contract).
say "Test 16b: a single real PASS row (one re-run) still certifies -> exit 0"
cat > "$tmpdir/t16b.md" <<'EOF'
| # | Assertion | Command | Expected | Verdict | Evidence |
|---|---|---|---|---|---|
| 1 | one honest run | `sh -c 'exit 0'` | exit 0 | PASS | ran it -> exit 0 |
| 2 | needs prod data | `psql -f down.sql` | rollback | UNVERIFIED | no live DB |
EOF
run --file "$tmpdir/t16b.md"
if [[ "$EC" -eq 0 ]]; then ok "one real re-run + one skip still certifies (exit 0)"; else bad "expected 0, got $EC; out: $(cat "$tmpdir/out")"; fi

# ---------- Test 17: prose Expected must NOT trigger a false MISMATCH (#256 review) ----------
# Operational-risk fix: the exit-heuristic must only treat a row as an
# exit-expectation when Expected CLEARLY names an exit code (`exit <n>` /
# `exits nonzero`). Arbitrary prose in Expected (e.g. "rejects bad input and
# returns a clean state") must NOT be read as "expects nonzero exit" — for a
# claimed-PASS row whose command legitimately exits 0, that would be a spurious
# MISMATCH that wrongly pages commander-stuck. Fall back to the verdict: PASS +
# exit 0 = reproduced.
say "Test 17: prose-Expected PASS row, command exits 0 -> NOT a false MISMATCH (exit 0)"
cat > "$tmpdir/t17.md" <<'EOF'
| # | Assertion | Command | Expected | Verdict | Evidence |
|---|---|---|---|---|---|
| 1 | validates and rejects malformed input, returns clean | `sh -c 'exit 0'` | rejects bad input and the handler fails gracefully | PASS | ran it -> exit 0; behaves |
EOF
run --file "$tmpdir/t17.md"
if [[ "$EC" -eq 0 ]]; then ok "prose with 'rejects'/'fails' words + exit 0 PASS -> exit 0 (no false mismatch)"; else bad "FALSE MISMATCH on prose Expected; expected 0, got $EC; out: $(cat "$tmpdir/out")"; fi
if grep -qiE "mismatch" "$tmpdir/out"; then bad "wrongly reported MISMATCH on prose Expected"; else ok "no spurious MISMATCH reported"; fi

# 17b: but an explicit `exits nonzero` Expected on a command that exits 0 IS still
# a real mismatch (we tightened the heuristic, we did not remove it).
say "Test 17b: explicit 'exits nonzero' Expected, command exits 0 -> still MISMATCH (exit 1)"
cat > "$tmpdir/t17b.md" <<'EOF'
| # | Assertion | Command | Expected | Verdict | Evidence |
|---|---|---|---|---|---|
| 1 | the guard exits nonzero on bad input | `sh -c 'exit 0'` | exits nonzero | PASS | claimed it rejects |
EOF
run --file "$tmpdir/t17b.md"
if [[ "$EC" -eq 1 ]]; then ok "explicit 'exits nonzero' disagreement still caught"; else bad "expected 1, got $EC; out: $(cat "$tmpdir/out")"; fi

# =============================================================================
# #310 — parser hardening: stop false-positive MISMATCHes that erode the gate.
# The four acceptance cases (a)-(d) + over-flagging guards. Committed fixtures
# under self-test/fixtures/revalidate-contract/ reconstruct #307 and #309.
# =============================================================================

# ---------- Test 18 (a): well-formed self-contained row -> PASS reproduces ----------
say "Test 18 (a): well-formed self-contained PASS row -> exit 0"
cat > "$tmpdir/t18.md" <<'EOF'
| # | Assertion | Command | Expected | Verdict | Evidence |
|---|---|---|---|---|---|
| 1 | a self-contained command reproduces | `sh -c 'exit 0'` | exit 0 | PASS | ran it -> exit 0 |
EOF
run --file "$tmpdir/t18.md"
if [[ "$EC" -eq 0 ]]; then ok "well-formed row -> exit 0"; else bad "expected 0, got $EC; out: $(cat "$tmpdir/out")"; fi

# ---------- Test 19 (b): #309 — exit code in Expected PROSE must NOT false-MISMATCH ----------
# A grep row exits 0 on a match; its Expected cell merely *mentions* `exit 1` in
# prose. The OLD parser scraped `exit 1` and demanded the pipeline exit 1 (false
# MISMATCH). The hardened parser reads the exit code only from the structured
# leading clause (absent here) and falls back to the verdict (PASS => exit 0).
say "Test 19 (b): grep row, 'exit 1' in Expected prose, command exits 0 -> NOT a false MISMATCH (exit 0)"
run --file "$FIXDIR/issue-309-grep-prose.md"
if [[ "$EC" -eq 0 ]]; then ok "#309 reconstruction -> exit 0 (no false mismatch)"; else bad "FALSE MISMATCH on Expected prose; expected 0, got $EC; out: $(cat "$tmpdir/out")"; fi
if grep -qiE "mismatch" "$tmpdir/out"; then bad "wrongly reported MISMATCH (exit code scraped from prose)"; else ok "no MISMATCH reported for prose 'exit 1'"; fi
# inline variant (not just the committed fixture) for robustness
cat > "$tmpdir/t19.md" <<'EOF'
| # | Assertion | Command | Expected | Verdict | Evidence |
|---|---|---|---|---|---|
| 1 | grep matches and exits 0 | `printf 'hay needle\n' \| grep -q needle` | matches the line; exit 1 would only mean the token was absent | PASS | ran it -> exit 0 |
EOF
run --file "$tmpdir/t19.md"
if [[ "$EC" -eq 0 ]]; then ok "inline prose-exit variant -> exit 0"; else bad "expected 0, got $EC; out: $(cat "$tmpdir/out")"; fi

# ---------- Test 20 (c): #307 — non-runnable Command -> AUTHORING-ERROR (exit 3), not MISMATCH ----------
say "Test 20 (c): placeholder + bare-unbound-var Command -> AUTHORING-ERROR, not run, exit 3"
run --file "$FIXDIR/issue-307-authoring.md"
if [[ "$EC" -eq 3 ]]; then ok "authoring errors -> exit 3 (distinct code)"; else bad "expected 3, got $EC; out: $(cat "$tmpdir/out")"; fi
if grep -qE "AUTHORING-ERROR row " "$tmpdir/out"; then ok "reports a distinct AUTHORING-ERROR status"; else bad "expected AUTHORING-ERROR in output; out: $(cat "$tmpdir/out")"; fi
if grep -qE "MISMATCH row " "$tmpdir/out"; then bad "a non-runnable Command was wrongly reported as MISMATCH"; else ok "never reported as MISMATCH (the #307 fix)"; fi
# 20a: a placeholder-only contract (no other rows) still exits 3, not the no-runs exit 1.
cat > "$tmpdir/t20a.md" <<'EOF'
| # | Assertion | Command | Expected | Verdict | Evidence |
|---|---|---|---|---|---|
| 1 | placeholder not filled in | `cat <fixture>` | exit 0 | PASS | (left a placeholder) |
EOF
run --file "$tmpdir/t20a.md"
if [[ "$EC" -eq 3 ]]; then ok "single placeholder row -> exit 3 (not no-runs exit 1)"; else bad "expected 3, got $EC; out: $(cat "$tmpdir/out")"; fi

# 20b: over-flagging GUARDS — legitimate self-contained commands must NOT be flagged.
say "Test 20b: inline-bound \$VAR and allowlisted env \$VAR are NOT authoring errors -> exit 0"
cat > "$tmpdir/t20b.md" <<'EOF'
| # | Assertion | Command | Expected | Verdict | Evidence |
|---|---|---|---|---|---|
| 1 | inline-assigned var is fine | `sh -c 'T=ok; test "$T" = ok'` | exit 0 | PASS | ran it -> exit 0 |
| 2 | allowlisted env var is fine | `sh -c 'test -n "$HOME"'` | exit 0 | PASS | ran it -> exit 0 |
| 3 | for-loop var is fine | `sh -c 'for x in a b; do printf "%s" "$x"; done'` | exit 0 | PASS | ran it -> ab |
EOF
run --file "$tmpdir/t20b.md"
if [[ "$EC" -eq 0 ]]; then ok "bound/env/loop vars not flagged -> exit 0"; else bad "over-flagged a legit command; expected 0, got $EC; out: $(cat "$tmpdir/out")"; fi
if grep -qE "AUTHORING-ERROR row " "$tmpdir/out"; then bad "wrongly flagged a self-contained command as AUTHORING-ERROR"; else ok "no false AUTHORING-ERROR on legit vars"; fi
# 20c: quoted markup like '<html>' (not a placeholder, not preceded by space/() must NOT flag.
cat > "$tmpdir/t20c.md" <<'EOF'
| # | Assertion | Command | Expected | Verdict | Evidence |
|---|---|---|---|---|---|
| 1 | quoted angle markup is not a placeholder | `sh -c "printf '<html>\n' \| grep -q '<html>'"` | exit 0 | PASS | ran it -> exit 0 |
EOF
run --file "$tmpdir/t20c.md"
if [[ "$EC" -eq 0 ]]; then ok "quoted '<html>' not flagged -> exit 0"; else bad "over-flagged quoted markup; expected 0, got $EC; out: $(cat "$tmpdir/out")"; fi

# ---------- Test 21 (d): NO-REGRESSION — a genuine wrong exit is STILL a MISMATCH ----------
# The load-bearing safety check: hardening must not silence REAL failures.
say "Test 21 (d): self-contained command genuinely exits wrong -> STILL MISMATCH (exit 1)"
run --file "$FIXDIR/genuine-mismatch.md"
if [[ "$EC" -eq 1 ]]; then ok "genuine mismatch still caught -> exit 1"; else bad "REGRESSION: genuine mismatch not caught; expected 1, got $EC; out: $(cat "$tmpdir/out")"; fi
if grep -qiE "mismatch" "$tmpdir/out"; then ok "reports MISMATCH for the real failure"; else bad "expected MISMATCH in output; out: $(cat "$tmpdir/out")"; fi
# 21b: a real MISMATCH takes precedence over an authoring error in the same contract.
say "Test 21b: real MISMATCH + an authoring-error row in one contract -> exit 1 (mismatch wins)"
cat > "$tmpdir/t21b.md" <<'EOF'
| # | Assertion | Command | Expected | Verdict | Evidence |
|---|---|---|---|---|---|
| 1 | genuinely wrong exit | `sh -c 'exit 5'` | exit 0 | PASS | claimed exit 0 |
| 2 | non-runnable placeholder | `cat <fixture>` | exit 0 | PASS | (placeholder) |
EOF
run --file "$tmpdir/t21b.md"
if [[ "$EC" -eq 1 ]]; then ok "MISMATCH takes precedence over authoring-error -> exit 1"; else bad "expected 1, got $EC; out: $(cat "$tmpdir/out")"; fi

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

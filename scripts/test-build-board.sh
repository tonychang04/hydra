#!/usr/bin/env bash
#
# test-build-board.sh — regression test for scripts/build-board.sh.
#
# Exercises (all read-only against mktemp fixtures; no git/gh/network):
#   - Grouping: one worker per lifecycle state lands in the right section
#     with the right count.
#   - Last-log rendering: a worker with a matching logs/N.json renders a
#     one-line "result (#pr, Nm)" summary.
#   - GitHub link: owner/repo#N → Markdown link; bare repo#N and LIN-123
#     stay verbatim (no link).
#   - Age: with a fixed --now, started_at 90m earlier shows "1h30m".
#   - Empty workers array → "_No active workers._", exit 0.
#   - Missing active.json → empty fleet, exit 0.
#   - File write: board.md is created and equals stdout.
#   - --no-write: nothing written, stdout still produced.
#   - Unknown status → "Other" section (nothing dropped).
#   - Usage errors exit 2.
#
# Style: matches scripts/test-promote-citations.sh — bash, colored output,
# pass/fail counter, no external test harness.
#
# Spec: docs/specs/2026-05-21-command-center-board.md (ticket #193)

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
BOARD="$SCRIPT_DIR/build-board.sh"

if [[ ! -x "$BOARD" ]]; then
  echo "test-build-board: $BOARD not found or not executable" >&2
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

say()  { printf "\n${C_BOLD}▸ %s${C_RESET}\n" "$*"; }
ok()   { printf "  ${C_GREEN}✓${C_RESET} %s\n" "$*"; passed=$((passed + 1)); }
bad()  { printf "  ${C_RED}✗${C_RESET} %s\n" "$*"; failed=$((failed + 1)); }

# --- Fixture builders ------------------------------------------------------

# Make a state/ + logs/ dir pair under a fresh root.
mk_dirs() {
  local root="$1"
  mkdir -p "$root/state" "$root/logs"
}

# Write a worker entry. Args: root, id, ticket, repo, tier, started_at,
# subagent_type, status. Appends to an array we assemble later.
# We build active.json from a here-doc per-test instead for clarity.

# Run the renderer against a root with a fixed now. Captures stdout/stderr.
# Echoes the exit code.
run_board() {
  local root="$1" stdout="$2" stderr="$3"
  shift 3
  set +e
  NO_COLOR=1 "$BOARD" \
    --state-dir "$root/state" \
    --logs-dir "$root/logs" \
    --now "2026-05-21T12:00:00Z" \
    "$@" \
    > "$stdout" 2> "$stderr"
  local ec=$?
  set -e
  echo "$ec"
}

# --- Test 1: grouping — one worker per state -------------------------------
say "Test 1: every lifecycle state lands in its own section with right count"
root1="$tmpdir/t1"
mk_dirs "$root1"
cat > "$root1/state/active.json" <<'EOF'
{
  "workers": [
    {"id":"w1","ticket":"tonychang04/hydra#10","repo":"tonychang04/hydra","tier":"T1","started_at":"2026-05-21T11:48:00Z","subagent_type":"worker-implementation","status":"running"},
    {"id":"w2","ticket":"tonychang04/hydra#11","repo":"tonychang04/hydra","tier":"T2","started_at":"2026-05-21T11:00:00Z","subagent_type":"worker-implementation","status":"paused-on-question"},
    {"id":"w3","ticket":"tonychang04/hydra#12","repo":"tonychang04/hydra","tier":"T2","started_at":"2026-05-21T10:00:00Z","subagent_type":"worker-implementation","status":"rescued"},
    {"id":"w4","ticket":"tonychang04/hydra#13","repo":"tonychang04/hydra","tier":"T1","started_at":"2026-05-21T09:00:00Z","subagent_type":"worker-review","status":"complete"},
    {"id":"w5","ticket":"tonychang04/hydra#14","repo":"tonychang04/hydra","tier":"T3","started_at":"2026-05-21T08:00:00Z","subagent_type":"worker-implementation","status":"failed"}
  ],
  "last_updated":"2026-05-21T11:50:00Z"
}
EOF

ec=$(run_board "$root1" "$tmpdir/t1.out" "$tmpdir/t1.err")
if [[ "$ec" -eq 0 ]]; then ok "exit 0"; else bad "expected exit 0, got $ec"; sed 's/^/    /' "$tmpdir/t1.err"; fi

for hdr in "## Running (1)" "## Paused-on-question (1)" "## Rescued (1)" "## Complete (1)" "## Failed (1)"; do
  if grep -qF "$hdr" "$tmpdir/t1.out"; then
    ok "section header present: $hdr"
  else
    bad "missing section header: $hdr"
    sed 's/^/    /' "$tmpdir/t1.out"
  fi
done

# Worker #11 (paused) must appear under the Paused section, not Running.
# Verify by checking ordering: the line for #11 comes after the Paused header
# and before the Rescued header.
paused_block="$(awk '/^## Paused-on-question/{f=1;next} /^## /{f=0} f' "$tmpdir/t1.out")"
if printf '%s' "$paused_block" | grep -q '#11'; then
  ok "#11 sits under Paused-on-question"
else
  bad "#11 not under Paused-on-question; block was:"
  printf '%s\n' "$paused_block" | sed 's/^/    /'
fi

# --- Test 2: last-log rendering -------------------------------------------
say "Test 2: matching logs/N.json renders 'result (#pr, Nm)'"
root2="$tmpdir/t2"
mk_dirs "$root2"
cat > "$root2/state/active.json" <<'EOF'
{
  "workers": [
    {"id":"w1","ticket":"tonychang04/hydra#102","repo":"tonychang04/hydra","tier":"T2","started_at":"2026-05-21T11:00:00Z","subagent_type":"worker-implementation","status":"complete"}
  ]
}
EOF
cat > "$root2/logs/102.json" <<'EOF'
{
  "ticket":"tonychang04/hydra#102",
  "repo":"tonychang04/hydra",
  "tier":"T2",
  "result":"merged",
  "pr_url":"https://github.com/tonychang04/hydra/pull/502",
  "wall_clock_minutes":23,
  "subagent_type":"worker-implementation"
}
EOF

ec=$(run_board "$root2" "$tmpdir/t2.out" "$tmpdir/t2.err")
if [[ "$ec" -eq 0 ]]; then ok "exit 0"; else bad "expected exit 0, got $ec"; fi
if grep -qF 'merged (#502, 23m)' "$tmpdir/t2.out"; then
  ok "last-log one-liner is 'merged (#502, 23m)'"
else
  bad "expected 'merged (#502, 23m)' in output; got:"
  sed 's/^/    /' "$tmpdir/t2.out"
fi

# --- Test 3: GitHub link resolution ---------------------------------------
say "Test 3: owner/repo#N links; bare repo#N and LIN-123 stay verbatim"
root3="$tmpdir/t3"
mk_dirs "$root3"
cat > "$root3/state/active.json" <<'EOF'
{
  "workers": [
    {"id":"w1","ticket":"tonychang04/hydra#96","repo":"tonychang04/hydra","tier":"T2","started_at":"2026-05-21T11:00:00Z","subagent_type":"worker-implementation","status":"running"},
    {"id":"w2","ticket":"hydra#77","repo":"fixture-org/hydra","tier":"T2","started_at":"2026-05-21T11:00:00Z","subagent_type":"worker-implementation","status":"running"},
    {"id":"w3","ticket":"LIN-123","repo":"tonychang04/hydra","tier":"T2","started_at":"2026-05-21T11:00:00Z","subagent_type":"worker-implementation","status":"running"}
  ]
}
EOF

ec=$(run_board "$root3" "$tmpdir/t3.out" "$tmpdir/t3.err")
if [[ "$ec" -eq 0 ]]; then ok "exit 0"; else bad "expected exit 0, got $ec"; fi
if grep -qF '[tonychang04/hydra#96](https://github.com/tonychang04/hydra/issues/96)' "$tmpdir/t3.out"; then
  ok "owner/repo#96 rendered as a GitHub issue link"
else
  bad "expected GitHub link for #96; got:"
  sed 's/^/    /' "$tmpdir/t3.out"
fi
# Bare hydra#77 should NOT become a link (no owner to build the URL).
if grep -qF 'hydra#77' "$tmpdir/t3.out" && ! grep -qF 'issues/77' "$tmpdir/t3.out"; then
  ok "bare hydra#77 left verbatim (no link)"
else
  bad "bare hydra#77 should not be linked; got:"
  sed 's/^/    /' "$tmpdir/t3.out"
fi
if grep -qF 'LIN-123' "$tmpdir/t3.out" && ! grep -q 'LIN-123.*http' "$tmpdir/t3.out"; then
  ok "LIN-123 left verbatim (no link)"
else
  bad "LIN-123 should not be linked; got:"
  sed 's/^/    /' "$tmpdir/t3.out"
fi

# --- Test 4: age math ------------------------------------------------------
say "Test 4: started 90m before --now shows 1h30m"
root4="$tmpdir/t4"
mk_dirs "$root4"
# now is 2026-05-21T12:00:00Z; 90 min earlier = 10:30:00Z
cat > "$root4/state/active.json" <<'EOF'
{
  "workers": [
    {"id":"w1","ticket":"tonychang04/hydra#1","repo":"tonychang04/hydra","tier":"T2","started_at":"2026-05-21T10:30:00Z","subagent_type":"worker-implementation","status":"running"}
  ]
}
EOF
ec=$(run_board "$root4" "$tmpdir/t4.out" "$tmpdir/t4.err")
if [[ "$ec" -eq 0 ]]; then ok "exit 0"; else bad "expected exit 0, got $ec"; fi
if grep -qF '1h30m' "$tmpdir/t4.out"; then
  ok "age renders as 1h30m"
else
  bad "expected age 1h30m; got:"
  sed 's/^/    /' "$tmpdir/t4.out"
fi

# --- Test 5: empty workers array ------------------------------------------
say "Test 5: empty workers array → '_No active workers._'"
root5="$tmpdir/t5"
mk_dirs "$root5"
echo '{"workers":[]}' > "$root5/state/active.json"
ec=$(run_board "$root5" "$tmpdir/t5.out" "$tmpdir/t5.err")
if [[ "$ec" -eq 0 ]]; then ok "exit 0"; else bad "expected exit 0, got $ec"; fi
if grep -qF '_No active workers._' "$tmpdir/t5.out"; then
  ok "empty-fleet message present"
else
  bad "expected '_No active workers._'; got:"
  sed 's/^/    /' "$tmpdir/t5.out"
fi

# --- Test 6: missing active.json ------------------------------------------
say "Test 6: missing active.json → treated as empty fleet, exit 0"
root6="$tmpdir/t6"
mk_dirs "$root6"
# no active.json written
ec=$(run_board "$root6" "$tmpdir/t6.out" "$tmpdir/t6.err")
if [[ "$ec" -eq 0 ]]; then ok "exit 0"; else bad "expected exit 0, got $ec"; sed 's/^/    /' "$tmpdir/t6.err"; fi
if grep -qF '_No active workers._' "$tmpdir/t6.out"; then
  ok "empty-fleet message on missing file"
else
  bad "expected '_No active workers._'; got:"
  sed 's/^/    /' "$tmpdir/t6.out"
fi

# --- Test 7: file write equals stdout -------------------------------------
say "Test 7: board.md is written and equals stdout"
root7="$tmpdir/t7"
mk_dirs "$root7"
cat > "$root7/state/active.json" <<'EOF'
{
  "workers": [
    {"id":"w1","ticket":"tonychang04/hydra#5","repo":"tonychang04/hydra","tier":"T1","started_at":"2026-05-21T11:00:00Z","subagent_type":"worker-implementation","status":"running"}
  ]
}
EOF
ec=$(run_board "$root7" "$tmpdir/t7.out" "$tmpdir/t7.err")
if [[ "$ec" -eq 0 ]]; then ok "exit 0"; else bad "expected exit 0, got $ec"; fi
if [[ -f "$root7/state/board.md" ]]; then
  ok "state/board.md was written"
else
  bad "expected state/board.md to exist"
fi
if diff -q "$root7/state/board.md" "$tmpdir/t7.out" >/dev/null 2>&1; then
  ok "board.md contents equal stdout"
else
  bad "board.md differs from stdout:"
  diff "$root7/state/board.md" "$tmpdir/t7.out" | sed 's/^/    /' || true
fi

# --- Test 8: --no-write ----------------------------------------------------
say "Test 8: --no-write prints to stdout but writes no file"
root8="$tmpdir/t8"
mk_dirs "$root8"
cat > "$root8/state/active.json" <<'EOF'
{"workers":[{"id":"w1","ticket":"tonychang04/hydra#9","repo":"tonychang04/hydra","tier":"T1","started_at":"2026-05-21T11:00:00Z","subagent_type":"worker-implementation","status":"running"}]}
EOF
ec=$(run_board "$root8" "$tmpdir/t8.out" "$tmpdir/t8.err" --no-write)
if [[ "$ec" -eq 0 ]]; then ok "exit 0"; else bad "expected exit 0, got $ec"; fi
if [[ ! -f "$root8/state/board.md" ]]; then
  ok "no board.md written under --no-write"
else
  bad "board.md should not exist under --no-write"
fi
if [[ -s "$tmpdir/t8.out" ]]; then
  ok "stdout still produced under --no-write"
else
  bad "expected non-empty stdout under --no-write"
fi

# --- Test 9: unknown status → Other section -------------------------------
say "Test 9: unrecognized status lands in an Other section"
root9="$tmpdir/t9"
mk_dirs "$root9"
cat > "$root9/state/active.json" <<'EOF'
{"workers":[{"id":"w1","ticket":"tonychang04/hydra#42","repo":"tonychang04/hydra","tier":"T2","started_at":"2026-05-21T11:00:00Z","subagent_type":"worker-implementation","status":"foobar"}]}
EOF
ec=$(run_board "$root9" "$tmpdir/t9.out" "$tmpdir/t9.err")
if [[ "$ec" -eq 0 ]]; then ok "exit 0"; else bad "expected exit 0, got $ec"; fi
if grep -qF '## Other (1)' "$tmpdir/t9.out" && grep -qF '#42' "$tmpdir/t9.out"; then
  ok "unknown-status worker lands in Other (1)"
else
  bad "expected '## Other (1)' with #42; got:"
  sed 's/^/    /' "$tmpdir/t9.out"
fi

# --- Test 10: usage error -------------------------------------------------
say "Test 10: unknown flag → exit 2"
set +e
NO_COLOR=1 "$BOARD" --bogus-flag > "$tmpdir/t10.out" 2> "$tmpdir/t10.err"
ec=$?
set -e
if [[ "$ec" -eq 2 ]]; then ok "exit 2 on unknown flag"; else bad "expected exit 2, got $ec"; fi

# --- Test 11: missing started_at must NOT shift columns -------------------
# (codex review: TSV empty-field collapse). A worker with no started_at should
# still render Tier and Type correctly, with Age "?".
say "Test 11: missing started_at keeps Tier/Type aligned, Age '?'"
root11="$tmpdir/t11"
mk_dirs "$root11"
cat > "$root11/state/active.json" <<'EOF'
{"workers":[{"id":"w1","ticket":"tonychang04/hydra#7","repo":"tonychang04/hydra","tier":"T2","subagent_type":"worker-implementation","status":"running"}]}
EOF
ec=$(run_board "$root11" "$tmpdir/t11.out" "$tmpdir/t11.err")
if [[ "$ec" -eq 0 ]]; then ok "exit 0"; else bad "expected exit 0, got $ec"; fi
# The row must contain "| ? | T2 | worker-implementation |" — tier and type in
# their proper cells, age "?". A column shift would put T2 in the Age cell.
row="$(grep '#7' "$tmpdir/t11.out")"
if printf '%s' "$row" | grep -qF '| ? | T2 | worker-implementation |'; then
  ok "columns aligned despite missing started_at"
else
  bad "columns shifted; row was:"
  printf '    %s\n' "$row"
fi

# --- Test 12: timezone offset is honored in age math ---------------------
# (codex review: ISO-8601 offset mishandling). 05:00 at -07:00 == 12:00 UTC.
say "Test 12: started_at with -07:00 offset → age 0m at now=12:00Z"
root12="$tmpdir/t12"
mk_dirs "$root12"
cat > "$root12/state/active.json" <<'EOF'
{"workers":[{"id":"w1","ticket":"tonychang04/hydra#8","repo":"tonychang04/hydra","tier":"T2","started_at":"2026-05-21T05:00:00-07:00","subagent_type":"worker-implementation","status":"running"}]}
EOF
ec=$(run_board "$root12" "$tmpdir/t12.out" "$tmpdir/t12.err")
if [[ "$ec" -eq 0 ]]; then ok "exit 0"; else bad "expected exit 0, got $ec"; fi
row="$(grep '#8' "$tmpdir/t12.out")"
if printf '%s' "$row" | grep -qF '| 0m |'; then
  ok "offset -07:00 resolves to UTC (age 0m)"
else
  bad "offset not honored; row was:"
  printf '    %s\n' "$row"
fi

# --- Test 13: present-but-unparseable active.json is surfaced -------------
# (codex review: malformed JSON must not masquerade as a healthy empty fleet).
say "Test 13: malformed active.json → visible notice + stderr warning"
root13="$tmpdir/t13"
mk_dirs "$root13"
printf 'not valid json {\n' > "$root13/state/active.json"
ec=$(run_board "$root13" "$tmpdir/t13.out" "$tmpdir/t13.err")
if [[ "$ec" -eq 0 ]]; then ok "exit 0 (degrade, don't crash)"; else bad "expected exit 0, got $ec"; fi
if grep -qF 'could not be parsed' "$tmpdir/t13.out"; then
  ok "board shows an unreadable-state notice"
else
  bad "expected unreadable-state notice in board; got:"
  sed 's/^/    /' "$tmpdir/t13.out"
fi
if grep -qiF 'warning' "$tmpdir/t13.err"; then
  ok "stderr carries a warning"
else
  bad "expected a stderr warning; got:"
  sed 's/^/    /' "$tmpdir/t13.err"
fi
# Crucially it must NOT claim "No active workers" (that's the healthy-empty path).
if grep -qF '_No active workers._' "$tmpdir/t13.out"; then
  bad "must not show healthy-empty message for a broken file"
else
  ok "does not masquerade as a healthy empty fleet"
fi

# --- Test 14: value-taking flag with no value → exit 2 -------------------
# (codex review: shift 2 without arg check exited 1, not the documented 2).
say "Test 14: --state-dir / --now with no value → exit 2"
for flag in --state-dir --logs-dir --out --now; do
  set +e
  NO_COLOR=1 "$BOARD" "$flag" > /dev/null 2> "$tmpdir/t14.err"
  ec=$?
  set -e
  if [[ "$ec" -eq 2 ]]; then
    ok "$flag with no value → exit 2"
  else
    bad "$flag with no value: expected exit 2, got $ec"
  fi
done

# --- Summary --------------------------------------------------------------
echo ""
echo "${C_BOLD}Total: $((passed + failed))  passed: ${C_GREEN}${passed}${C_RESET}  failed: ${C_RED}${failed}${C_RESET}"
if [[ "$failed" -gt 0 ]]; then
  exit 1
fi
exit 0

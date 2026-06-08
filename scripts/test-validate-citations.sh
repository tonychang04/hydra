#!/usr/bin/env bash
#
# test-validate-citations.sh — regression test for scripts/validate-citations.sh.
#
# validate-citations.sh is the canonical citation-liveness check: it verifies
# every key in state/memory-citations.json still points at a live quote in its
# referenced memory file (CLAUDE.md names it as memory-hygiene tooling, and it
# gates skill promotion — a stale citation that still "resolves" would keep a
# learning whose source quote no longer exists counting toward the 3-cite
# threshold). This test locks down that behavior.
#
# Cases (all fixtures under mktemp; never touches the real memory/ tree or the
# real state/memory-citations.json, and never sets HYDRA_MEMORY_BACKEND so the
# S3-sync hook stays dormant):
#   1. flat top-level JSON shape, unquoted key, live quote        → exit 0
#   2. {citations:{...}} wrapper shape, quoted key, live quote    → exit 0
#   3. a key whose quote was deleted from the file                → exit 1, stderr
#   4. case-mismatched quote (match is case-sensitive)            → exit 1, stderr
#   5. citation pointing at a nonexistent memory file             → exit 1, stderr
#   6. malformed key (no '#' separator)                           → exit 1, stderr
#   7. empty / {} citations file                                  → exit 0 (no-op)
#   8. _-prefixed keys (e.g. _schema) are skipped                 → exit 0
#   9. --memory-dir / --citations overrides are honored           → exit 0
#  10. usage errors (unknown flag, missing flag value, missing
#      citations file, missing memory dir)                        → exit 2
#
# Style: matches scripts/test-promote-citations.sh — bash, colored output,
# pass/fail counter, no external test harness.
#
# Spec: docs/specs/2026-06-08-test-validate-citations.md (ticket #300)

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
VALIDATE="$SCRIPT_DIR/validate-citations.sh"

if [[ ! -x "$VALIDATE" ]]; then
  echo "test-validate-citations: $VALIDATE not found or not executable" >&2
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

# Run the script under test with NO_COLOR, capturing stdout/stderr to files and
# returning the exit code on stdout (so callers can `ec=$(run ...)`).
run() {
  local outf="$1" errf="$2"
  shift 2
  set +e
  NO_COLOR=1 "$VALIDATE" "$@" > "$outf" 2> "$errf"
  local ec=$?
  set -e
  echo "$ec"
}

# --- Test 1: flat shape, unquoted key, live quote → exit 0 ----------------
say "Test 1: flat top-level JSON, unquoted key, live quote → exit 0"
root1="$tmpdir/t1"; mkdir -p "$root1/mem"
printf -- '- a live quote here\n' > "$root1/mem/learnings-x.md"
cat > "$root1/c.json" <<'EOF'
{ "learnings-x.md#a live quote here": {"count": 1} }
EOF
ec=$(run "$root1/out" "$root1/err" --memory-dir "$root1/mem" --citations "$root1/c.json")
if [[ "$ec" -eq 0 ]]; then
  ok "exit 0 for a live, unquoted citation (flat shape)"
else
  bad "expected exit 0, got $ec; stderr:"; sed 's/^/    /' "$root1/err"
fi
if grep -q 'OK (1 citation' "$root1/out"; then
  ok "stdout reports 1 citation checked"
else
  bad "expected OK summary; stdout:"; sed 's/^/    /' "$root1/out"
fi

# --- Test 2: {citations:{...}} wrapper, quoted key, live → exit 0 ---------
say "Test 2: {citations:{...}} wrapper, quoted key, live quote → exit 0"
root2="$tmpdir/t2"; mkdir -p "$root2/mem"
printf -- '- a live quote here\n' > "$root2/mem/learnings-x.md"
cat > "$root2/c.json" <<'EOF'
{ "citations": { "learnings-x.md#\"a live quote here\"": {"count": 2} } }
EOF
ec=$(run "$root2/out" "$root2/err" --memory-dir "$root2/mem" --citations "$root2/c.json")
if [[ "$ec" -eq 0 ]]; then
  ok "exit 0 for a live, quoted citation (wrapper shape — quotes unwrapped)"
else
  bad "expected exit 0, got $ec; stderr:"; sed 's/^/    /' "$root2/err"
fi

# --- Test 3: deleted quote → exit 1, named on stderr ----------------------
say "Test 3: key whose quote was deleted → exit 1, listed on stderr"
root3="$tmpdir/t3"; mkdir -p "$root3/mem"
printf -- '- a different surviving quote\n' > "$root3/mem/learnings-x.md"
cat > "$root3/c.json" <<'EOF'
{ "citations": { "learnings-x.md#\"this quote was deleted\"": {"count": 1} } }
EOF
ec=$(run "$root3/out" "$root3/err" --memory-dir "$root3/mem" --citations "$root3/c.json")
if [[ "$ec" -eq 1 ]]; then
  ok "exit 1 for a stale citation"
else
  bad "expected exit 1, got $ec"
fi
if grep -q 'quote not found' "$root3/err" && grep -q 'this quote was deleted' "$root3/err"; then
  ok "stale citation is named on stderr"
else
  bad "expected the stale key on stderr; stderr:"; sed 's/^/    /' "$root3/err"
fi

# --- Test 4: case-mismatched quote is stale (case-sensitive) --------------
say "Test 4: case-mismatched quote → stale, exit 1 (match is case-sensitive)"
root4="$tmpdir/t4"; mkdir -p "$root4/mem"
printf -- '- Live Quote With Caps\n' > "$root4/mem/learnings-x.md"
cat > "$root4/c.json" <<'EOF'
{ "citations": { "learnings-x.md#\"live quote with caps\"": {"count": 1} } }
EOF
ec=$(run "$root4/out" "$root4/err" --memory-dir "$root4/mem" --citations "$root4/c.json")
if [[ "$ec" -eq 1 ]]; then
  ok "exit 1 — a case-mismatched quote does not resolve"
else
  bad "expected exit 1, got $ec; stderr:"; sed 's/^/    /' "$root4/err"
fi

# --- Test 5: citation pointing at a nonexistent file → stale --------------
say "Test 5: citation referencing a missing memory file → exit 1, stderr"
root5="$tmpdir/t5"; mkdir -p "$root5/mem"
printf -- '- something\n' > "$root5/mem/learnings-x.md"
cat > "$root5/c.json" <<'EOF'
{ "citations": { "learnings-gone.md#\"anything\"": {"count": 1} } }
EOF
ec=$(run "$root5/out" "$root5/err" --memory-dir "$root5/mem" --citations "$root5/c.json")
if [[ "$ec" -eq 1 ]]; then
  ok "exit 1 — missing referenced file is stale"
else
  bad "expected exit 1, got $ec"
fi
if grep -q 'referenced file missing' "$root5/err"; then
  ok "stderr explains the file is missing"
else
  bad "expected 'referenced file missing' on stderr; stderr:"; sed 's/^/    /' "$root5/err"
fi

# --- Test 6: malformed key (no '#') → stale -------------------------------
say "Test 6: malformed key (no '#' separator) → exit 1, stderr"
root6="$tmpdir/t6"; mkdir -p "$root6/mem"
printf -- '- something\n' > "$root6/mem/learnings-x.md"
cat > "$root6/c.json" <<'EOF'
{ "citations": { "no-hash-separator-key": {"count": 1} } }
EOF
ec=$(run "$root6/out" "$root6/err" --memory-dir "$root6/mem" --citations "$root6/c.json")
if [[ "$ec" -eq 1 ]]; then
  ok "exit 1 — malformed key is flagged"
else
  bad "expected exit 1, got $ec"
fi
if grep -q "no '#' separator" "$root6/err"; then
  ok "stderr explains the missing '#' separator"
else
  bad "expected the malformed-key message; stderr:"; sed 's/^/    /' "$root6/err"
fi

# --- Test 7: empty / {} citations file → no-op exit 0 ---------------------
say "Test 7: empty {} citations file → exit 0 (nothing to check)"
root7="$tmpdir/t7"; mkdir -p "$root7/mem"
printf -- '- something\n' > "$root7/mem/learnings-x.md"
echo '{}' > "$root7/c.json"
ec=$(run "$root7/out" "$root7/err" --memory-dir "$root7/mem" --citations "$root7/c.json")
if [[ "$ec" -eq 0 ]]; then
  ok "exit 0 for an empty {} citations file"
else
  bad "expected exit 0, got $ec; stderr:"; sed 's/^/    /' "$root7/err"
fi
if grep -q '0 citation' "$root7/out"; then
  ok "stdout reports 0 citations checked"
else
  bad "expected '0 citation' in stdout; stdout:"; sed 's/^/    /' "$root7/out"
fi

# --- Test 8: _-prefixed keys (e.g. _schema) are skipped -------------------
say "Test 8: _-prefixed keys (e.g. _schema) skipped; only real keys checked"
root8="$tmpdir/t8"; mkdir -p "$root8/mem"
printf -- '- Live Quote With Caps\n' > "$root8/mem/learnings-x.md"
cat > "$root8/c.json" <<'EOF'
{ "_schema": "v1", "_meta": {"foo": "bar"}, "learnings-x.md#Live Quote With Caps": {"count": 1} }
EOF
ec=$(run "$root8/out" "$root8/err" --memory-dir "$root8/mem" --citations "$root8/c.json")
if [[ "$ec" -eq 0 ]]; then
  ok "exit 0 — _-prefixed keys did not get treated as citations"
else
  bad "expected exit 0, got $ec; stderr:"; sed 's/^/    /' "$root8/err"
fi
if grep -q 'OK (1 citation' "$root8/out"; then
  ok "exactly 1 real citation checked (the two _-keys were skipped)"
else
  bad "expected '1 citation' checked; stdout:"; sed 's/^/    /' "$root8/out"
fi

# --- Test 9: --memory-dir / --citations overrides honored -----------------
# Already exercised implicitly above, but assert explicitly that a quote which
# is live ONLY in the override memory dir resolves — proving the flag is used,
# not a hardcoded ./memory.
say "Test 9: --memory-dir override is honored (quote live only there resolves)"
root9="$tmpdir/t9"; mkdir -p "$root9/real-mem"
printf -- '- only in the override dir\n' > "$root9/real-mem/learnings-x.md"
cat > "$root9/c.json" <<'EOF'
{ "citations": { "learnings-x.md#\"only in the override dir\"": {"count": 1} } }
EOF
ec=$(run "$root9/out" "$root9/err" --memory-dir "$root9/real-mem" --citations "$root9/c.json")
if [[ "$ec" -eq 0 ]]; then
  ok "exit 0 — citation resolved against the --memory-dir override"
else
  bad "expected exit 0, got $ec; stderr:"; sed 's/^/    /' "$root9/err"
fi

# --- Test 10: usage errors → exit 2 ---------------------------------------
say "Test 10: usage errors → exit 2"
root10="$tmpdir/t10"; mkdir -p "$root10/mem"
echo '{}' > "$root10/c.json"

# 10a: unknown flag
ec=$(run "$root10/a.out" "$root10/a.err" --bogus-flag)
if [[ "$ec" -eq 2 ]]; then
  ok "exit 2 on unknown flag"
else
  bad "expected exit 2 on unknown flag, got $ec"
fi
if grep -q 'unknown option' "$root10/a.err"; then
  ok "stderr names the unknown option"
else
  bad "expected 'unknown option' on stderr; stderr:"; sed 's/^/    /' "$root10/a.err"
fi

# 10b: flag missing its value
ec=$(run "$root10/b.out" "$root10/b.err" --citations)
if [[ "$ec" -eq 2 ]]; then
  ok "exit 2 when --citations is given without a value"
else
  bad "expected exit 2 on missing flag value, got $ec"
fi

# 10c: citations file does not exist
ec=$(run "$root10/c.out" "$root10/c.err" --memory-dir "$root10/mem" --citations "$root10/missing.json")
if [[ "$ec" -eq 2 ]]; then
  ok "exit 2 when the citations file is missing"
else
  bad "expected exit 2 on missing citations file, got $ec"
fi
if grep -q 'citations file not found' "$root10/c.err"; then
  ok "stderr explains the citations file is missing"
else
  bad "expected 'citations file not found'; stderr:"; sed 's/^/    /' "$root10/c.err"
fi

# 10d: memory dir does not exist
ec=$(run "$root10/d.out" "$root10/d.err" --memory-dir "$root10/no-such-dir" --citations "$root10/c.json")
if [[ "$ec" -eq 2 ]]; then
  ok "exit 2 when the memory dir is missing"
else
  bad "expected exit 2 on missing memory dir, got $ec"
fi
if grep -q 'memory dir not found' "$root10/d.err"; then
  ok "stderr explains the memory dir is missing"
else
  bad "expected 'memory dir not found'; stderr:"; sed 's/^/    /' "$root10/d.err"
fi

# --- Summary --------------------------------------------------------------

echo ""
echo "${C_BOLD}Total: $((passed + failed))  passed: ${C_GREEN}${passed}${C_RESET}  failed: ${C_RED}${failed}${C_RESET}"
if [[ "$failed" -gt 0 ]]; then
  exit 1
fi
exit 0

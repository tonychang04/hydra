#!/usr/bin/env bash
#
# test-parse-citations.sh — regression test for scripts/parse-citations.sh.
#
# parse-citations.sh is the entry point of Hydra's learning loop: it extracts
# MEMORY_CITED: markers from a worker report and emits the JSON delta Commander
# merges into state/memory-citations.json. That citation count drives the
# 3-cite-across-3-tickets skill-promotion threshold (CLAUDE.md). A silent
# parsing bug here corrupts citation counts with nothing to catch it. This test
# locks down the documented contract.
#
# Exercises (no mutation of parse-citations.sh — it is the oracle):
#   - single marker → correct "<file>#<quote>" key + count_delta:1 + empty tickets
#   - duplicate key aggregates count; distinct keys stay separate
#   - leading TICKET: line attaches the ref to every citation (de-duped)
#   - TICKET: absent → empty tickets_added
#   - zero markers → {"citations":{}} + exit 0
#   - quoted-quote form preserved verbatim in the key
#   - stdin path == <report-file> arg path (byte-identical JSON)
#   - --ticket flag overrides the inline TICKET: line, and works alone
#   - missing cited file → stderr warning, exit still 0 (lenient by contract)
#   - usage errors (unknown flag, missing flag value, two positional args,
#     nonexistent input file) → exit 2
#   - -h/--help → exit 0 + usage banner
#   - whitespace-padded marker is extracted + trimmed to canonical key
#
# Style: matches scripts/test-promote-citations.sh — bash, colored output,
# pass/fail counter, no external harness, no fixtures outside mktemp.
#
# Spec: docs/specs/2026-06-08-test-parse-citations.md (ticket #301)

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PARSE="$SCRIPT_DIR/parse-citations.sh"

if [[ ! -x "$PARSE" ]]; then
  echo "test-parse-citations: $PARSE not found or not executable" >&2
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

# --- Fixture: a memory dir containing the cited file --------------------------
# Pointing --memory-dir at a dir that HAS the cited file suppresses the
# (non-fatal) "referenced file not found" stderr warning, keeping stderr clean
# for the cases that assert on it. The cited basename is learnings-CLI.md.
memdir="$tmpdir/memory"
mkdir -p "$memdir"
cat > "$memdir/learnings-CLI.md" <<'EOF'
---
name: cli learnings
description: test fixture
type: repo-learnings
---

## Known gotchas

- npm install strips peer markers — fixture line so the cited quote exists.
EOF

# run_parse: feed a report on stdin, capture stdout/stderr/exit separately.
# Args: <report-text> <stdout-file> <stderr-file> [extra parse args...]
run_parse() {
  local report="$1" out="$2" err="$3"
  shift 3
  set +e
  printf '%s' "$report" | "$PARSE" --memory-dir "$memdir" "$@" > "$out" 2> "$err"
  local ec=$?
  set -e
  echo "$ec"
}

# --- Test 1: single marker → correct key + count_delta:1 + empty tickets ------
say "Test 1: single marker → correct key, count_delta=1, tickets_added=[]"
report1='intro line
MEMORY_CITED: learnings-CLI.md#"npm install strips peer markers"
trailing line
'
ec=$(run_parse "$report1" "$tmpdir/t1.out" "$tmpdir/t1.err")
if [[ "$ec" -eq 0 ]]; then ok "exit 0"; else bad "expected exit 0, got $ec"; fi

key1='learnings-CLI.md#"npm install strips peer markers"'
if jq -e --arg k "$key1" '.citations | has($k)' "$tmpdir/t1.out" >/dev/null; then
  ok "citation key preserved verbatim"
else
  bad "expected key '$key1'; stdout:"; sed 's/^/    /' "$tmpdir/t1.out"
fi
if [[ "$(jq -r --arg k "$key1" '.citations[$k].count_delta' "$tmpdir/t1.out")" == "1" ]]; then
  ok "count_delta == 1"
else
  bad "expected count_delta 1"
fi
if [[ "$(jq -r --arg k "$key1" '.citations[$k].tickets_added | length' "$tmpdir/t1.out")" == "0" ]]; then
  ok "tickets_added is empty (no TICKET: / --ticket)"
else
  bad "expected empty tickets_added"
fi
# Exactly one citation key.
if [[ "$(jq -r '.citations | length' "$tmpdir/t1.out")" == "1" ]]; then
  ok "exactly one citation key"
else
  bad "expected exactly 1 citation"
fi

# --- Test 2: duplicate key aggregates; distinct key stays separate ------------
say "Test 2: duplicate key → count_delta=2; distinct key → count_delta=1"
report2='MEMORY_CITED: learnings-CLI.md#"a"
MEMORY_CITED: learnings-CLI.md#"a"
MEMORY_CITED: learnings-CLI.md#"b"
'
ec=$(run_parse "$report2" "$tmpdir/t2.out" "$tmpdir/t2.err")
if [[ "$ec" -eq 0 ]]; then ok "exit 0"; else bad "expected exit 0, got $ec"; fi
if [[ "$(jq -r '.citations["learnings-CLI.md#\"a\""].count_delta' "$tmpdir/t2.out")" == "2" ]]; then
  ok "duplicate key aggregated to count_delta=2"
else
  bad "expected count_delta 2 for key a; stdout:"; sed 's/^/    /' "$tmpdir/t2.out"
fi
if [[ "$(jq -r '.citations["learnings-CLI.md#\"b\""].count_delta' "$tmpdir/t2.out")" == "1" ]]; then
  ok "distinct key b stayed at count_delta=1"
else
  bad "expected count_delta 1 for key b"
fi
if [[ "$(jq -r '.citations | length' "$tmpdir/t2.out")" == "2" ]]; then
  ok "two distinct citation keys"
else
  bad "expected exactly 2 keys"
fi

# --- Test 3: leading TICKET: line attaches ref to every citation (de-duped) ---
say "Test 3: TICKET: line → ref attached to all citations, de-duped"
report3='TICKET: cli#50
MEMORY_CITED: learnings-CLI.md#"a"
MEMORY_CITED: learnings-CLI.md#"a"
MEMORY_CITED: learnings-CLI.md#"b"
'
ec=$(run_parse "$report3" "$tmpdir/t3.out" "$tmpdir/t3.err")
if [[ "$ec" -eq 0 ]]; then ok "exit 0"; else bad "expected exit 0, got $ec"; fi
# Every citation's tickets_added must equal exactly ["cli#50"].
if [[ "$(jq -r '[.citations[] | (.tickets_added == ["cli#50"])] | all' "$tmpdir/t3.out")" == "true" ]]; then
  ok "every citation has tickets_added == [\"cli#50\"]"
else
  bad "expected all tickets_added == [cli#50]; stdout:"; sed 's/^/    /' "$tmpdir/t3.out"
fi
# The repeated key must NOT accumulate a duplicate ticket ref.
if [[ "$(jq -r '.citations["learnings-CLI.md#\"a\""].tickets_added | length' "$tmpdir/t3.out")" == "1" ]]; then
  ok "repeated key de-dupes ticket ref (length 1)"
else
  bad "expected single de-duped ticket ref on repeated key"
fi

# --- Test 4: TICKET: absent → empty tickets_added -----------------------------
say "Test 4: no TICKET: and no --ticket → tickets_added empty for all"
report4='MEMORY_CITED: learnings-CLI.md#"a"
MEMORY_CITED: learnings-CLI.md#"b"
'
ec=$(run_parse "$report4" "$tmpdir/t4.out" "$tmpdir/t4.err")
if [[ "$ec" -eq 0 ]]; then ok "exit 0"; else bad "expected exit 0, got $ec"; fi
if [[ "$(jq -r '[.citations[] | (.tickets_added | length == 0)] | all' "$tmpdir/t4.out")" == "true" ]]; then
  ok "all tickets_added empty"
else
  bad "expected all tickets_added empty"
fi

# --- Test 5: zero markers → {"citations":{}} + exit 0 -------------------------
say "Test 5: report with no markers → empty delta, exit 0"
ec=$(run_parse $'just some prose\nno citations here\n' "$tmpdir/t5.out" "$tmpdir/t5.err")
if [[ "$ec" -eq 0 ]]; then ok "exit 0"; else bad "expected exit 0, got $ec"; fi
if [[ "$(jq -c '.' "$tmpdir/t5.out")" == '{"citations":{}}' ]]; then
  ok 'stdout is exactly {"citations":{}}'
else
  bad "expected empty citations object; stdout:"; sed 's/^/    /' "$tmpdir/t5.out"
fi

# --- Test 6: quoted-quote form preserved verbatim in the key ------------------
say "Test 6: inner-text + surrounding double quotes survive verbatim in key"
qkey='learnings-CLI.md#"labels on PRs always use the REST API"'
report6="noise
MEMORY_CITED: ${qkey}
"
ec=$(run_parse "$report6" "$tmpdir/t6.out" "$tmpdir/t6.err")
if [[ "$ec" -eq 0 ]]; then ok "exit 0"; else bad "expected exit 0, got $ec"; fi
if jq -e --arg k "$qkey" '.citations | has($k)' "$tmpdir/t6.out" >/dev/null; then
  ok "key with embedded straight double quotes preserved byte-for-byte"
else
  bad "expected verbatim quoted key; stdout:"; sed 's/^/    /' "$tmpdir/t6.out"
fi

# --- Test 7: stdin path == <report-file> arg path -----------------------------
say "Test 7: stdin and <report-file> arg produce byte-identical JSON"
report7='TICKET: cli#7
MEMORY_CITED: learnings-CLI.md#"a"
MEMORY_CITED: learnings-CLI.md#"b"
'
file7="$tmpdir/report7.txt"
printf '%s' "$report7" > "$file7"
# stdin path
printf '%s' "$report7" | "$PARSE" --memory-dir "$memdir" > "$tmpdir/t7.stdin" 2>/dev/null
# file-arg path
"$PARSE" --memory-dir "$memdir" "$file7" > "$tmpdir/t7.file" 2>/dev/null
if diff -q "$tmpdir/t7.stdin" "$tmpdir/t7.file" >/dev/null; then
  ok "stdin output == file-arg output (byte-identical)"
else
  bad "stdin and file-arg outputs differ:"; diff "$tmpdir/t7.stdin" "$tmpdir/t7.file" | sed 's/^/    /'
fi

# --- Test 8: --ticket flag overrides the inline TICKET: line ------------------
say "Test 8: --ticket flag wins over an inline TICKET: line"
report8='TICKET: from-line
MEMORY_CITED: learnings-CLI.md#"a"
'
ec=$(run_parse "$report8" "$tmpdir/t8.out" "$tmpdir/t8.err" --ticket flag-ref)
if [[ "$ec" -eq 0 ]]; then ok "exit 0"; else bad "expected exit 0, got $ec"; fi
if [[ "$(jq -r '.citations["learnings-CLI.md#\"a\""].tickets_added | @csv' "$tmpdir/t8.out")" == '"flag-ref"' ]]; then
  ok "flag value (flag-ref) won over inline TICKET: from-line"
else
  bad "expected tickets_added == [flag-ref]; stdout:"; sed 's/^/    /' "$tmpdir/t8.out"
fi

# --- Test 9: --ticket flag alone (no TICKET: line) ----------------------------
say "Test 9: --ticket flag with no TICKET: line attaches to all citations"
report9='MEMORY_CITED: learnings-CLI.md#"a"
MEMORY_CITED: learnings-CLI.md#"b"
'
ec=$(run_parse "$report9" "$tmpdir/t9.out" "$tmpdir/t9.err" --ticket solo-ref)
if [[ "$ec" -eq 0 ]]; then ok "exit 0"; else bad "expected exit 0, got $ec"; fi
if [[ "$(jq -r '[.citations[] | (.tickets_added == ["solo-ref"])] | all' "$tmpdir/t9.out")" == "true" ]]; then
  ok "all citations carry [solo-ref]"
else
  bad "expected all citations tagged solo-ref"
fi

# --- Test 10: missing cited file → stderr warning, exit still 0 ---------------
say "Test 10: cited file absent → stderr warning, JSON still emitted, exit 0"
emptydir="$tmpdir/empty-memory"
mkdir -p "$emptydir"
set +e
printf 'MEMORY_CITED: learnings-CLI.md#"a"\n' \
  | "$PARSE" --memory-dir "$emptydir" > "$tmpdir/t10.out" 2> "$tmpdir/t10.err"
ec=$?
set -e
if [[ "$ec" -eq 0 ]]; then
  ok "exit 0 (lenient — parse-citations does not fail on missing file)"
else
  bad "expected exit 0, got $ec"
fi
if grep -q 'referenced file not found' "$tmpdir/t10.err"; then
  ok "stderr carries the 'referenced file not found' warning"
else
  bad "expected file-not-found warning on stderr; stderr:"; sed 's/^/    /' "$tmpdir/t10.err"
fi
if [[ "$(jq -r '.citations | length' "$tmpdir/t10.out")" == "1" ]]; then
  ok "JSON delta still emitted on stdout despite warning"
else
  bad "expected the citation to still be emitted"
fi

# --- Test 11: usage errors → exit 2 -------------------------------------------
say "Test 11: usage errors all exit 2"
run_usage() {  # prints exit code; args passed to parse, no stdin needed
  set +e
  "$PARSE" "$@" </dev/null >/dev/null 2>&1
  local ec=$?
  set -e
  echo "$ec"
}
if [[ "$(run_usage --bogus-flag)" -eq 2 ]]; then ok "unknown flag → exit 2"; else bad "unknown flag should exit 2"; fi
if [[ "$(run_usage --ticket)" -eq 2 ]]; then ok "--ticket missing value → exit 2"; else bad "--ticket w/o value should exit 2"; fi
if [[ "$(run_usage --memory-dir)" -eq 2 ]]; then ok "--memory-dir missing value → exit 2"; else bad "--memory-dir w/o value should exit 2"; fi
if [[ "$(run_usage fileA fileB)" -eq 2 ]]; then ok "two positional args → exit 2"; else bad "two positional args should exit 2"; fi
if [[ "$(run_usage "$tmpdir/nonexistent-report.txt")" -eq 2 ]]; then ok "nonexistent input file → exit 2"; else bad "nonexistent file should exit 2"; fi

# --- Test 12: -h/--help → exit 0 + usage banner -------------------------------
say "Test 12: -h/--help → exit 0 and prints usage"
set +e
"$PARSE" --help > "$tmpdir/t12.out" 2>&1
ec=$?
set -e
if [[ "$ec" -eq 0 ]]; then ok "--help exit 0"; else bad "--help should exit 0, got $ec"; fi
if grep -q 'Usage: parse-citations.sh' "$tmpdir/t12.out"; then
  ok "usage banner printed"
else
  bad "expected usage banner; output:"; sed 's/^/    /' "$tmpdir/t12.out"
fi
set +e
"$PARSE" -h >/dev/null 2>&1
hc=$?
set -e
if [[ "$hc" -eq 0 ]]; then ok "-h exit 0"; else bad "-h should exit 0, got $hc"; fi

# --- Test 13: whitespace-padded marker extracted + trimmed --------------------
say "Test 13: indented/trailing-whitespace marker → extracted + trimmed to canonical key"
report13=$'\t   MEMORY_CITED:   learnings-CLI.md#"a"   \n'
ec=$(run_parse "$report13" "$tmpdir/t13.out" "$tmpdir/t13.err")
if [[ "$ec" -eq 0 ]]; then ok "exit 0"; else bad "expected exit 0, got $ec"; fi
if jq -e '.citations | has("learnings-CLI.md#\"a\"")' "$tmpdir/t13.out" >/dev/null; then
  ok "leading/trailing whitespace trimmed to canonical key"
else
  bad "expected trimmed key learnings-CLI.md#\"a\"; stdout:"; sed 's/^/    /' "$tmpdir/t13.out"
fi

# --- Summary ------------------------------------------------------------------
echo ""
echo "${C_BOLD}Total: $((passed + failed))  passed: ${C_GREEN}${passed}${C_RESET}  failed: ${C_RED}${failed}${C_RESET}"
if [[ "$failed" -gt 0 ]]; then
  exit 1
fi
exit 0

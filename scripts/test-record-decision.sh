#!/usr/bin/env bash
#
# test-record-decision.sh — regression test for the Decision Record writer:
#   scripts/record-decision.sh   (append one validated decision entry)
#
# Exercises (all offline, bash + jq, no network/docker):
#   FLAGS MODE
#     - writes exactly one valid-JSON line with the five required keys
#     - ts is auto-generated (ISO-8601 UTC, second precision) when absent
#     - --date seam controls the target daily file
#     - optional fields land: confidence, what_would_reverse, approval_ref,
#       repeatable --alternative '<opt>::<why>'
#   JSON-STDIN MODE
#     - --json reads a complete entry object from stdin and appends it
#     - ts is injected when the stdin object omits it
#   RED -> GREEN (the malformed-entry gate)
#     - missing --why            -> exit 1, NOTHING written
#     - bad --type (not in enum) -> exit 1, NOTHING written
#     - empty --subject          -> exit 1, NOTHING written
#     - then a corrected entry   -> exit 0, exactly one line
#   USAGE
#     - missing required flag with no --json -> exit 2
#
# Style: matches scripts/test-trace.sh — bash, colored output, pass/fail
# counter, mktemp fixtures, no external harness.
#
# Spec: docs/specs/2026-06-08-decision-record.md (ticket #267)

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
RECORD="$SCRIPT_DIR/record-decision.sh"

[[ -x "$RECORD" ]] || { echo "test-record-decision: $RECORD not found or not executable" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "test-record-decision: jq required" >&2; exit 2; }

if [[ -t 1 ]] && [[ "${NO_COLOR:-}" != "1" ]]; then
  C_GREEN=$'\033[32m'; C_RED=$'\033[31m'; C_BOLD=$'\033[1m'; C_RESET=$'\033[0m'
else
  C_GREEN=""; C_RED=""; C_BOLD=""; C_RESET=""
fi

passed=0
failed=0
say() { printf "\n${C_BOLD}▸ %s${C_RESET}\n" "$*"; }
ok()  { printf "  ${C_GREEN}✓${C_RESET} %s\n" "$*"; passed=$((passed + 1)); }
bad() { printf "  ${C_RED}✗${C_RESET} %s\n" "$*"; failed=$((failed + 1)); }

assert_eq() {
  if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1 (expected [$2], got [$3])"; fi
}

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
DDIR="$TMP/decisions"
DATE="2026-06-08"
FILE="$DDIR/$DATE.jsonl"

# count lines in the daily file (0 if absent)
nlines() { [[ -f "$FILE" ]] && grep -c . "$FILE" 2>/dev/null || echo 0; }

# ---------------------------------------------------------------------------
say "FLAGS MODE — append a valid entry"
rm -rf "$DDIR"
rc=0
"$RECORD" --decisions-dir "$DDIR" --date "$DATE" \
  --type merge-surface --subject "tonychang04/hydra#501" \
  --decided "surface-for-human" \
  --why "t3-never: T3 is never auto-merge-eligible (safety rail)" >/dev/null 2>&1 || rc=$?
assert_eq "exit 0 on a valid entry" "0" "$rc"
assert_eq "exactly one line written" "1" "$(nlines)"

if [[ -f "$FILE" ]]; then
  line="$(tail -n1 "$FILE")"
  printf '%s' "$line" | jq -e . >/dev/null 2>&1 && ok "line is valid JSON" || bad "line is NOT valid JSON: $line"
  assert_eq "decision_type" "merge-surface" "$(printf '%s' "$line" | jq -r '.decision_type')"
  assert_eq "subject"       "tonychang04/hydra#501" "$(printf '%s' "$line" | jq -r '.subject')"
  assert_eq "decided"       "surface-for-human" "$(printf '%s' "$line" | jq -r '.decided')"
  # ts auto-generated, ISO-8601 UTC second precision
  ts="$(printf '%s' "$line" | jq -r '.ts')"
  if [[ "$ts" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]; then
    ok "ts auto-generated (ISO-8601 UTC second precision): $ts"
  else
    bad "ts not ISO-8601 UTC second precision: $ts"
  fi
else
  bad "daily file not created"
fi

# ---------------------------------------------------------------------------
say "FLAGS MODE — optional fields land"
rm -rf "$DDIR"
"$RECORD" --decisions-dir "$DDIR" --date "$DATE" \
  --type tier-classify --subject "#312" --decided "T2" \
  --why "policy.md T2: touches >1 module" \
  --confidence high \
  --what-would-reverse "if scope shrinks to a single file" \
  --approval-ref "approvals#7" \
  --alternative "T1::touches more than one module" \
  --alternative "T3::no auth/infra/migration touched" >/dev/null 2>&1
line="$(tail -n1 "$FILE")"
assert_eq "confidence"         "high" "$(printf '%s' "$line" | jq -r '.confidence')"
assert_eq "what_would_reverse" "if scope shrinks to a single file" "$(printf '%s' "$line" | jq -r '.what_would_reverse')"
assert_eq "approval_ref"       "approvals#7" "$(printf '%s' "$line" | jq -r '.approval_ref')"
assert_eq "alternatives count" "2" "$(printf '%s' "$line" | jq -r '.alternatives | length')"
assert_eq "alternative[0].option" "T1" "$(printf '%s' "$line" | jq -r '.alternatives[0].option')"
assert_eq "alternative[0].why_rejected" "touches more than one module" "$(printf '%s' "$line" | jq -r '.alternatives[0].why_rejected')"

# ---------------------------------------------------------------------------
say "JSON-STDIN MODE — append a complete object"
rm -rf "$DDIR"
printf '%s' '{"decision_type":"escalate","subject":"#312","decided":"escalate-to-supervisor","why":"unmatched QUESTION: not in escalation-faq","approval_ref":null}' \
  | "$RECORD" --decisions-dir "$DDIR" --date "$DATE" --json >/dev/null 2>&1
assert_eq "stdin entry written" "1" "$(nlines)"
line="$(tail -n1 "$FILE")"
assert_eq "decision_type (stdin)" "escalate" "$(printf '%s' "$line" | jq -r '.decision_type')"
# ts injected even when stdin omits it
ts="$(printf '%s' "$line" | jq -r '.ts')"
[[ "$ts" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T ]] && ok "ts injected into stdin entry: $ts" || bad "ts not injected into stdin entry: $ts"
# jq's `// ` treats null as absent, so read the raw type to prove null is stored.
assert_eq "approval_ref null preserved (stdin)" "null" "$(printf '%s' "$line" | jq -r '.approval_ref | if . == null then "null" else . end')"

# ---------------------------------------------------------------------------
say "RED -> GREEN — malformed entries are REJECTED, nothing written"

# RED #1: missing --why
rm -rf "$DDIR"
rc=0
"$RECORD" --decisions-dir "$DDIR" --date "$DATE" \
  --type merge-surface --subject "#9" --decided "x" >/dev/null 2>&1 || rc=$?
assert_eq "missing --why -> exit 1" "1" "$rc"
assert_eq "missing --why -> nothing written" "0" "$(nlines)"

# RED #2: bad --type (not in enum)
rc=0
"$RECORD" --decisions-dir "$DDIR" --date "$DATE" \
  --type not-a-real-type --subject "#9" --decided "x" --why "y" >/dev/null 2>&1 || rc=$?
assert_eq "bad --type -> exit 1" "1" "$rc"
assert_eq "bad --type -> nothing written" "0" "$(nlines)"

# RED #3: empty --subject
rc=0
"$RECORD" --decisions-dir "$DDIR" --date "$DATE" \
  --type merge-surface --subject "" --decided "x" --why "y" >/dev/null 2>&1 || rc=$?
assert_eq "empty --subject -> exit 1" "1" "$rc"
assert_eq "empty --subject -> nothing written" "0" "$(nlines)"

# RED #4 (stdin): bad enum via --json
rc=0
printf '%s' '{"decision_type":"bogus","subject":"#9","decided":"x","why":"y"}' \
  | "$RECORD" --decisions-dir "$DDIR" --date "$DATE" --json >/dev/null 2>&1 || rc=$?
assert_eq "stdin bad enum -> exit 1" "1" "$rc"
assert_eq "stdin bad enum -> nothing written" "0" "$(nlines)"

# GREEN: the corrected entry is accepted
rc=0
"$RECORD" --decisions-dir "$DDIR" --date "$DATE" \
  --type merge-surface --subject "#9" --decided "surface-for-human" \
  --why "policy-human: tier requires human" >/dev/null 2>&1 || rc=$?
assert_eq "corrected entry -> exit 0" "0" "$rc"
assert_eq "corrected entry -> exactly one line" "1" "$(nlines)"

# ---------------------------------------------------------------------------
say "USAGE — CLI misuse -> exit 2"
# Unknown flag is a genuine usage error (distinct from an invalid entry).
rc=0
"$RECORD" --decisions-dir "$DDIR" --not-a-flag >/dev/null 2>&1 || rc=$?
assert_eq "unknown flag -> exit 2" "2" "$rc"
# --type without a value is a usage error too.
rc=0
"$RECORD" --decisions-dir "$DDIR" --type >/dev/null 2>&1 || rc=$?
assert_eq "flag missing its value -> exit 2" "2" "$rc"
# Missing required content (flags mode, nothing passed) is an INVALID entry (1).
rc=0
"$RECORD" --decisions-dir "$DDIR" --date "$DATE" --type merge-surface >/dev/null 2>&1 || rc=$?
assert_eq "missing subject/decided/why -> exit 1 (invalid entry)" "1" "$rc"

# ---------------------------------------------------------------------------
printf "\n${C_BOLD}%s passed · %s failed${C_RESET}\n" "$passed" "$failed"
[[ "$failed" -eq 0 ]]

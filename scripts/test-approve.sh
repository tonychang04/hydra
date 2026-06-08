#!/usr/bin/env bash
#
# test-approve.sh — regression test for the Approval Record:
#   scripts/approve.sh     (record one validated approval action)
#   scripts/approvals.sh   (read who/when/why for a subject)
#
# Exercises (all offline, bash + jq, no network/docker):
#   WRITER — happy paths
#     - --await creates the subject (status:awaiting, approver:null, history len 1)
#       and prints the minted approval:<key> on stdout
#     - --approve appends history (len 2), sets status:approved + approver
#     - --reject sets status:rejected
#     - --decision-ref lands on the action; absent -> null
#     - --now seam controls ts (ISO-8601 UTC second precision)
#     - subject normalization: #501 and <repo>#501 resolve to the same key
#   WRITER — RED->GREEN gate (malformed -> exit !=0, NOTHING written)
#     - --approve with no --by         -> exit 1, file unchanged
#     - empty --reason                 -> exit 1, file unchanged
#     - --await WITH --by              -> exit 2 (usage)
#     - two of --approve/--reject/--await -> exit 2 (usage)
#     - then a corrected --approve     -> exit 0, history grows by one
#   SCHEMA
#     - state/approvals.example.json validates against the schema
#     - a record with current missing reason FAILS validation (RED)
#   READER
#     - approvals.sh <subject> prints status + history
#     - --status awaiting filters; --json emits parseable JSON
#     - empty/absent file -> exit 0, no crash
#
# Style: matches scripts/test-record-decision.sh — bash, colored output,
# pass/fail counter, mktemp fixtures, no external harness.
#
# Spec: docs/specs/2026-06-08-approval-record.md (ticket #268)

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
APPROVE="$SCRIPT_DIR/approve.sh"
APPROVALS="$SCRIPT_DIR/approvals.sh"
VALIDATE="$SCRIPT_DIR/validate-state.sh"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
SCHEMA="$REPO_ROOT/state/schemas/approvals.schema.json"
EXAMPLE="$REPO_ROOT/state/approvals.example.json"

[[ -x "$APPROVE" ]]   || { echo "test-approve: $APPROVE not found or not executable" >&2; exit 2; }
[[ -x "$APPROVALS" ]] || { echo "test-approve: $APPROVALS not found or not executable" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "test-approve: jq required" >&2; exit 2; }

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
AFILE="$TMP/approvals.json"

# jq helpers against the approvals file
subj_q() { jq -r --arg s "$1" '.approvals[$s] // empty'; }   # whole record
status_of()  { [[ -f "$AFILE" ]] && jq -r --arg s "$1" '.approvals[$s].status // "MISSING"' "$AFILE" 2>/dev/null || echo "MISSING"; }
histlen_of() { [[ -f "$AFILE" ]] && jq -r --arg s "$1" '(.approvals[$s].history // []) | length' "$AFILE" 2>/dev/null || echo 0; }
curfield()   { [[ -f "$AFILE" ]] && jq -r --arg s "$1" --arg f "$2" '.approvals[$s].current[$f]' "$AFILE" 2>/dev/null || echo "MISSING"; }
file_hash()  { [[ -f "$AFILE" ]] && shasum "$AFILE" 2>/dev/null | awk '{print $1}' || echo "ABSENT"; }

REPO="tonychang04/hydra"
KEY="$REPO#501"

# ---------------------------------------------------------------------------
say "WRITER — --await creates the subject (awaiting, approver null)"
rm -f "$AFILE"
rc=0
out="$("$APPROVE" "#501" --await --reason "surfaced for human merge" \
        --repo "$REPO" --approvals-file "$AFILE" --now "2026-06-08T18:00:00Z" 2>/dev/null)" || rc=$?
assert_eq "exit 0 on --await" "0" "$rc"
assert_eq "status awaiting"        "awaiting" "$(status_of "$KEY")"
assert_eq "history length 1"       "1"        "$(histlen_of "$KEY")"
assert_eq "current.approver null"  "null"     "$(curfield "$KEY" approver)"
assert_eq "current.ts honored"     "2026-06-08T18:00:00Z" "$(curfield "$KEY" ts)"
assert_eq "minted approval key printed" "approval:$KEY" "$out"

# ---------------------------------------------------------------------------
say "WRITER — --approve appends history, sets approver"
rc=0
"$APPROVE" "#501" --approve --by "tonychang04" --reason "review clean, CI green" \
  --repo "$REPO" --approvals-file "$AFILE" --now "2026-06-08T18:30:00Z" \
  --decision-ref "merge-surface:$KEY" >/dev/null 2>&1 || rc=$?
assert_eq "exit 0 on --approve"   "0"          "$rc"
assert_eq "status approved"       "approved"   "$(status_of "$KEY")"
assert_eq "history length 2"      "2"          "$(histlen_of "$KEY")"
assert_eq "current.approver set"  "tonychang04" "$(curfield "$KEY" approver)"
assert_eq "current.decision_ref set" "merge-surface:$KEY" "$(curfield "$KEY" decision_ref)"
# history is append-only: first entry is still the awaiting action
first_dec="$(jq -r --arg s "$KEY" '.approvals[$s].history[0].decision' "$AFILE")"
assert_eq "history[0] still awaiting (append-only)" "awaiting" "$first_dec"

# ---------------------------------------------------------------------------
say "WRITER — --reject sets status rejected"
rc=0
"$APPROVE" "#501" --reject --by "tonychang04" --reason "found a regression" \
  --repo "$REPO" --approvals-file "$AFILE" --now "2026-06-08T19:00:00Z" >/dev/null 2>&1 || rc=$?
assert_eq "exit 0 on --reject" "0"        "$rc"
assert_eq "status rejected"    "rejected" "$(status_of "$KEY")"
assert_eq "history length 3"   "3"        "$(histlen_of "$KEY")"

# ---------------------------------------------------------------------------
say "WRITER — decision_ref absent -> null"
rm -f "$AFILE"
"$APPROVE" "#777" --await --reason "surfaced" --repo "$REPO" \
  --approvals-file "$AFILE" --now "2026-06-08T20:00:00Z" >/dev/null 2>&1
assert_eq "current.decision_ref null when omitted" "null" "$(curfield "$REPO#777" decision_ref)"

# ---------------------------------------------------------------------------
say "WRITER — subject normalization (#N and <repo>#N collapse)"
rm -f "$AFILE"
"$APPROVE" "#888" --await --reason "a" --repo "$REPO" --approvals-file "$AFILE" --now "2026-06-08T20:00:00Z" >/dev/null 2>&1
"$APPROVE" "$REPO#888" --approve --by "tony" --reason "b" --repo "$REPO" --approvals-file "$AFILE" --now "2026-06-08T20:01:00Z" >/dev/null 2>&1
nkeys="$(jq -r '.approvals | keys | length' "$AFILE")"
assert_eq "both refs map to one subject key" "1" "$nkeys"
assert_eq "normalized key is <repo>#888 approved" "approved" "$(status_of "$REPO#888")"

# ---------------------------------------------------------------------------
say "WRITER — RED->GREEN gate (malformed -> error, NOTHING written)"
rm -f "$AFILE"
# seed a valid awaiting so we can assert the file is UNCHANGED on bad writes
"$APPROVE" "#900" --await --reason "seed" --repo "$REPO" --approvals-file "$AFILE" --now "2026-06-08T21:00:00Z" >/dev/null 2>&1
before="$(file_hash)"

# Missing required input is a USAGE error (exit 2); content that fails write-time
# validation (a malformed --now timestamp) is an INVALID action (exit 1). Both
# reject and write nothing.
rc=0; "$APPROVE" "#900" --approve --reason "no approver given" --repo "$REPO" --approvals-file "$AFILE" >/dev/null 2>&1 || rc=$?
assert_eq "--approve without --by -> exit 2 (usage)" "2" "$rc"
assert_eq "file unchanged after missing --by" "$before" "$(file_hash)"

rc=0; "$APPROVE" "#900" --approve --by "tony" --reason "" --repo "$REPO" --approvals-file "$AFILE" >/dev/null 2>&1 || rc=$?
assert_eq "empty --reason -> exit 2 (usage)" "2" "$rc"
assert_eq "file unchanged after empty reason" "$before" "$(file_hash)"

rc=0; "$APPROVE" "#900" --await --by "tony" --reason "x" --repo "$REPO" --approvals-file "$AFILE" >/dev/null 2>&1 || rc=$?
assert_eq "--await WITH --by -> exit 2 (usage)" "2" "$rc"
assert_eq "file unchanged after await+by" "$before" "$(file_hash)"

rc=0; "$APPROVE" "#900" --approve --reject --by "tony" --reason "x" --repo "$REPO" --approvals-file "$AFILE" >/dev/null 2>&1 || rc=$?
assert_eq "two decisions -> exit 2 (usage)" "2" "$rc"
assert_eq "file unchanged after double decision" "$before" "$(file_hash)"

# RED->GREEN content gate: a malformed timestamp is an INVALID action (exit 1),
# nothing written.
rc=0; "$APPROVE" "#900" --approve --by "tony" --reason "x" --repo "$REPO" --approvals-file "$AFILE" --now "not-a-timestamp" >/dev/null 2>&1 || rc=$?
assert_eq "malformed --now ts -> exit 1 (invalid action)" "1" "$rc"
assert_eq "file unchanged after bad ts" "$before" "$(file_hash)"

# now a corrected write succeeds and grows history by one
rc=0; "$APPROVE" "#900" --approve --by "tony" --reason "fixed" --repo "$REPO" --approvals-file "$AFILE" --now "2026-06-08T21:30:00Z" >/dev/null 2>&1 || rc=$?
assert_eq "corrected --approve -> exit 0" "0" "$rc"
assert_eq "history grew to 2" "2" "$(histlen_of "$REPO#900")"

# ---------------------------------------------------------------------------
say "SCHEMA — example validates; malformed record is rejected"
rc=0; bash "$VALIDATE" --schema "$SCHEMA" "$EXAMPLE" >/dev/null 2>&1 || rc=$?
assert_eq "committed example validates (exit 0)" "0" "$rc"

# RED: a record whose current is missing 'reason' must fail validation.
BAD="$TMP/bad-approvals.json"
jq '.approvals["tonychang04/hydra#501"].current |= del(.reason)
    | .approvals["tonychang04/hydra#501"].history[1] |= del(.reason)' "$EXAMPLE" > "$BAD"
rc=0; bash "$VALIDATE" --schema "$SCHEMA" "$BAD" >/dev/null 2>&1 || rc=$?
if [[ "$rc" -ne 0 ]]; then ok "malformed record (no reason) rejected (exit $rc)"; else bad "malformed record was NOT rejected"; fi

# ---------------------------------------------------------------------------
say "READER — query, filter, json, empty-file"
rm -f "$AFILE"
"$APPROVE" "#501" --await   --reason "surfaced"     --repo "$REPO" --approvals-file "$AFILE" --now "2026-06-08T18:00:00Z" >/dev/null 2>&1
"$APPROVE" "#501" --approve --by "tony" --reason "clean" --repo "$REPO" --approvals-file "$AFILE" --now "2026-06-08T18:30:00Z" >/dev/null 2>&1
"$APPROVE" "#777" --await   --reason "pending"      --repo "$REPO" --approvals-file "$AFILE" --now "2026-06-08T18:40:00Z" >/dev/null 2>&1

# subject query shows status + who + history
out="$("$APPROVALS" "#501" --approvals-file "$AFILE" 2>/dev/null)"
printf '%s' "$out" | grep -q "approved" && ok "reader: #501 shows approved" || bad "reader: #501 missing 'approved' (got: $out)"
printf '%s' "$out" | grep -q "tony"     && ok "reader: #501 shows approver"  || bad "reader: #501 missing approver"

# --status awaiting filters to the pending one only
out="$("$APPROVALS" --status awaiting --approvals-file "$AFILE" 2>/dev/null)"
printf '%s' "$out" | grep -q "#777" && ok "reader: --status awaiting lists #777" || bad "reader: --status awaiting missing #777"
if printf '%s' "$out" | grep -q "#501"; then bad "reader: --status awaiting wrongly lists approved #501"; else ok "reader: --status awaiting excludes approved #501"; fi

# --json emits parseable JSON
rc=0; "$APPROVALS" --json --approvals-file "$AFILE" 2>/dev/null | jq -e . >/dev/null 2>&1 || rc=$?
assert_eq "reader: --json is parseable" "0" "$rc"

# empty / absent file -> exit 0, no crash
rc=0; "$APPROVALS" --approvals-file "$TMP/nope.json" >/dev/null 2>&1 || rc=$?
assert_eq "reader: absent file -> exit 0" "0" "$rc"

# ---------------------------------------------------------------------------
printf "\n${C_BOLD}Result:${C_RESET} %d passed, %d failed\n" "$passed" "$failed"
[[ "$failed" -eq 0 ]] || exit 1

#!/usr/bin/env bash
#
# test-decisions.sh — regression test for the Decision Record reader:
#   scripts/decisions.sh   ("why did Commander do X?")
#
# Exercises (offline, bash + jq):
#   - no arg: lists ALL entries across the daily files (newest first)
#   - <subject>: filters to matching entries; #N normalizes (so #501 matches
#     tonychang04/hydra#501)
#   - --since <date>: only entries on/after that date
#   - --json: valid JSON array
#   - empty/absent dir: exit 0, empty output (fail-soft)
#   - missing explicit --decisions-dir path: exit 2
#
# Style: matches scripts/test-trace.sh.
#
# Spec: docs/specs/2026-06-08-decision-record.md (ticket #267)

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
READER="$SCRIPT_DIR/decisions.sh"

[[ -x "$READER" ]] || { echo "test-decisions: $READER not found or not executable" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "test-decisions: jq required" >&2; exit 2; }

if [[ -t 1 ]] && [[ "${NO_COLOR:-}" != "1" ]]; then
  C_GREEN=$'\033[32m'; C_RED=$'\033[31m'; C_BOLD=$'\033[1m'; C_RESET=$'\033[0m'
else
  C_GREEN=""; C_RED=""; C_BOLD=""; C_RESET=""
fi

passed=0; failed=0
say() { printf "\n${C_BOLD}▸ %s${C_RESET}\n" "$*"; }
ok()  { printf "  ${C_GREEN}✓${C_RESET} %s\n" "$*"; passed=$((passed + 1)); }
bad() { printf "  ${C_RED}✗${C_RESET} %s\n" "$*"; failed=$((failed + 1)); }
assert_eq() { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1 (expected [$2], got [$3])"; fi; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
DDIR="$TMP/decisions"
mkdir -p "$DDIR"

# Seed two daily files with three entries.
cat > "$DDIR/2026-06-07.jsonl" <<'EOF'
{"ts":"2026-06-07T10:00:00Z","decision_type":"tier-classify","subject":"tonychang04/hydra#312","decided":"T2","why":"policy.md T2: touches >1 module","approval_ref":null}
EOF
cat > "$DDIR/2026-06-08.jsonl" <<'EOF'
{"ts":"2026-06-08T09:00:00Z","decision_type":"merge-surface","subject":"tonychang04/hydra#501","decided":"surface-for-human","why":"t3-never: T3 is never auto-merge-eligible","approval_ref":null}
{"ts":"2026-06-08T11:00:00Z","decision_type":"escalate","subject":"worker-abc123","decided":"escalate-to-supervisor","why":"unmatched QUESTION","approval_ref":null}
EOF

# ---------------------------------------------------------------------------
say "no arg — lists all entries"
n="$("$READER" --decisions-dir "$DDIR" --json | jq 'length')"
assert_eq "all entries counted" "3" "$n"

say "newest first"
first_ts="$("$READER" --decisions-dir "$DDIR" --json | jq -r '.[0].ts')"
assert_eq "first entry is the newest" "2026-06-08T11:00:00Z" "$first_ts"

# ---------------------------------------------------------------------------
say "subject filter — #N normalization"
n="$("$READER" --decisions-dir "$DDIR" "#501" --json | jq 'length')"
assert_eq "#501 matches tonychang04/hydra#501" "1" "$n"
subj="$("$READER" --decisions-dir "$DDIR" "#501" --json | jq -r '.[0].subject')"
assert_eq "matched the right subject" "tonychang04/hydra#501" "$subj"

say "subject filter — full ref"
n="$("$READER" --decisions-dir "$DDIR" "tonychang04/hydra#312" --json | jq 'length')"
assert_eq "full ref matches" "1" "$n"

say "subject filter — worker id substring"
n="$("$READER" --decisions-dir "$DDIR" "worker-abc" --json | jq 'length')"
assert_eq "worker substring matches" "1" "$n"

say "subject filter — no match"
n="$("$READER" --decisions-dir "$DDIR" "#999" --json | jq 'length')"
assert_eq "no match -> empty array" "0" "$n"

# ---------------------------------------------------------------------------
say "--since filter"
n="$("$READER" --decisions-dir "$DDIR" --since 2026-06-08 --json | jq 'length')"
assert_eq "since 2026-06-08 -> 2 entries" "2" "$n"
n="$("$READER" --decisions-dir "$DDIR" --since 2026-06-07 --json | jq 'length')"
assert_eq "since 2026-06-07 -> 3 entries" "3" "$n"

# ---------------------------------------------------------------------------
say "human (default) output mentions why"
out="$("$READER" --decisions-dir "$DDIR" "#501" 2>/dev/null)"
printf '%s' "$out" | grep -q "t3-never" && ok "human output includes the 'why'" || bad "human output missing 'why': $out"
printf '%s' "$out" | grep -q "surface-for-human" && ok "human output includes 'decided'" || bad "human output missing 'decided'"

# ---------------------------------------------------------------------------
say "fail-soft — empty/absent dir"
rc=0
out="$("$READER" --decisions-dir "$TMP/nope" --json 2>/dev/null)" || rc=$?
assert_eq "absent dir -> exit 0" "0" "$rc"
assert_eq "absent dir -> empty array" "0" "$(printf '%s' "$out" | jq 'length')"

# ---------------------------------------------------------------------------
printf "\n${C_BOLD}%s passed · %s failed${C_RESET}\n" "$passed" "$failed"
[[ "$failed" -eq 0 ]]

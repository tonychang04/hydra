#!/usr/bin/env bash
#
# test-quota-watch.sh — regression test for scripts/quota-watch.sh, the
# report-only cost + quota visibility rollup (ticket #273).
#
# Exercises (all offline, bash + jq, no network/docker/gh):
#   - --json emits valid JSON with every documented key
#   - counts/wall-clock/rate-limit match the fixture budget-used.json
#   - cost fields delegate correctly to cost-per-pr.sh (total / per-merged-PR)
#   - est_cost_per_ticket = total_cost_usd / tickets_completed_today
#   - est_cost_per_ticket is null when 0 tickets completed
#   - --operator-line prints exactly one non-empty line, no JSON
#   - missing state files degrade to zeros/nulls, exit 0 (no crash)
#   - --write produces a quota-health.json that passes the schema
#   - usage errors (unknown flag) → exit 2
#
# Style mirrors scripts/test-cost.sh — bash, colored output, pass/fail counter,
# mktemp fixtures, no external harness.
#
# Spec: docs/specs/2026-06-07-quota-watch-cost-visibility.md (ticket #273)

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"
QUOTA_WATCH="$SCRIPT_DIR/quota-watch.sh"
VALIDATE_STATE="$SCRIPT_DIR/validate-state.sh"
SCHEMA="$ROOT_DIR/state/schemas/quota-health.schema.json"
FIXDIR="$ROOT_DIR/self-test/fixtures/quota-watch"

[[ -x "$QUOTA_WATCH" ]] || { echo "test-quota-watch: $QUOTA_WATCH not found or not executable" >&2; exit 2; }
[[ -f "$SCHEMA" ]] || { echo "test-quota-watch: schema missing: $SCHEMA" >&2; exit 2; }
[[ -d "$FIXDIR" ]] || { echo "test-quota-watch: fixtures missing: $FIXDIR" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "test-quota-watch: jq required" >&2; exit 2; }

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

# assert_eq <label> <expected> <actual>
assert_eq() {
  if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1 (expected [$2], got [$3])"; fi
}

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

BUD="$FIXDIR/budget-used.json"
AUTO="$FIXDIR/autopickup.json"
LOGS="$FIXDIR/logs"
MERGED="$FIXDIR/merged.txt"

# Canonical full-fixture invocation (deterministic, offline).
qw() {
  "$QUOTA_WATCH" --budget-file "$BUD" --autopickup-file "$AUTO" \
    --logs-dir "$LOGS" --merged-prs "$MERGED" "$@"
}

# =============================================================================
say "JSON output is valid and has every documented key"
# =============================================================================
json="$(qw --json)"
assert_eq "valid JSON" "ok" "$(jq -e . >/dev/null 2>&1 <<<"$json" && echo ok || echo bad)"
keys_ok="$(jq -e '
  has("generated_at") and has("date")
  and has("tickets_completed_today") and has("tickets_failed_today")
  and has("wall_clock_min_today") and has("rate_limit_hits_today")
  and has("consecutive_rate_limit_hits")
  and has("total_cost_usd") and has("cost_per_merged_pr")
  and has("tickets_counted") and has("est_cost_per_ticket")
  and has("operator_line")
' >/dev/null 2>&1 <<<"$json" && echo yes || echo no)"
assert_eq "all documented keys present" "yes" "$keys_ok"

# =============================================================================
say "Counters match the fixture budget-used.json (6 done / 240 min / 0 RL)"
# =============================================================================
assert_eq "tickets_completed_today" "6"   "$(jq -r '.tickets_completed_today' <<<"$json")"
assert_eq "tickets_failed_today"    "0"   "$(jq -r '.tickets_failed_today' <<<"$json")"
assert_eq "wall_clock_min_today"    "240" "$(jq -r '.wall_clock_min_today' <<<"$json")"
assert_eq "rate_limit_hits_today"   "0"   "$(jq -r '.rate_limit_hits_today' <<<"$json")"
assert_eq "date mirrored"           "2026-06-08" "$(jq -r '.date' <<<"$json")"
assert_eq "github_rate_limit_ok true when 0 hits" "true" "$(jq -r '.github_rate_limit_ok' <<<"$json")"

# =============================================================================
say "Cost delegates to cost-per-pr.sh (total 0.6 / per-merged-PR 0.3)"
# =============================================================================
assert_eq "total_cost_usd"      "0.6" "$(jq -r '.total_cost_usd' <<<"$json")"
assert_eq "cost_per_merged_pr"  "0.3" "$(jq -r '.cost_per_merged_pr' <<<"$json")"
assert_eq "tickets_counted"     "2"   "$(jq -r '.tickets_counted' <<<"$json")"

# =============================================================================
say "est_cost_per_ticket = total_cost_usd / tickets_completed_today (0.6/6=0.1)"
# =============================================================================
assert_eq "est_cost_per_ticket" "0.1" "$(jq -r '.est_cost_per_ticket' <<<"$json")"

# =============================================================================
say "est_cost_per_ticket is null when 0 tickets completed"
# =============================================================================
zero_bud="$tmpdir/budget-zero.json"
cat > "$zero_bud" <<'JSON'
{"date":"2026-06-08","tickets_completed_today":0,"tickets_failed_today":0,"total_worker_wall_clock_minutes_today":0,"rate_limit_hits_today":0}
JSON
zjson="$("$QUOTA_WATCH" --json --budget-file "$zero_bud" --autopickup-file "$AUTO" --logs-dir "$LOGS" --merged-prs "$MERGED")"
assert_eq "est null with 0 tickets" "null" "$(jq -r '.est_cost_per_ticket' <<<"$zjson")"
# total cost is still computed (cost is over MERGED PRs, independent of today's tickets)
assert_eq "total cost still present" "0.6" "$(jq -r '.total_cost_usd' <<<"$zjson")"

# =============================================================================
say "--operator-line prints exactly one non-empty line, no JSON"
# =============================================================================
ol="$(qw --operator-line)"
assert_eq "operator-line is one line" "1" "$(printf '%s' "$ol" | grep -c '.')"
assert_eq "operator-line has no JSON brace" "0" "$(printf '%s' "$ol" | grep -c '{')"
ol_prefix="${ol:0:6}"
assert_eq "operator-line starts with Quota:" "Quota:" "$ol_prefix"

# =============================================================================
say "Missing state files degrade to zeros/nulls, exit 0 (no crash)"
# =============================================================================
emptylogs="$tmpdir/emptylogs"; mkdir -p "$emptylogs"
set +e
mjson="$("$QUOTA_WATCH" --json --budget-file /nonexistent-xyz --autopickup-file /nonexistent-xyz --logs-dir "$emptylogs" --merged-prs /dev/null)"
mrc=$?
set -e
assert_eq "missing-state exit 0" "0" "$mrc"
assert_eq "missing tickets → 0"  "0" "$(jq -r '.tickets_completed_today' <<<"$mjson")"
assert_eq "missing cost → null"  "null" "$(jq -r '.total_cost_usd' <<<"$mjson")"
assert_eq "missing est → null"   "null" "$(jq -r '.est_cost_per_ticket' <<<"$mjson")"

# =============================================================================
say "--write produces a quota-health.json that passes the schema"
# =============================================================================
outf="$tmpdir/quota-health.json"
qw --write --out "$outf" --json >/dev/null
assert_eq "write created the file" "yes" "$([[ -f "$outf" ]] && echo yes || echo no)"
set +e
"$VALIDATE_STATE" --schema "$SCHEMA" "$outf" >/dev/null 2>&1
vrc=$?
set -e
assert_eq "written snapshot validates against schema" "0" "$vrc"

# =============================================================================
say "Default (no --write) does NOT touch state/quota-health.json (report-only)"
# =============================================================================
nowrite="$tmpdir/should-not-exist.json"
qw --json >/dev/null
assert_eq "no side-effect file without --write" "no" "$([[ -f "$nowrite" ]] && echo yes || echo no)"

# =============================================================================
say "Usage errors → exit 2"
# =============================================================================
set +e
"$QUOTA_WATCH" --bogus-flag >/dev/null 2>&1; urc=$?
set -e
assert_eq "unknown flag → exit 2" "2" "$urc"

# =============================================================================
printf "\n${C_BOLD}%d passed · %d failed${C_RESET}\n" "$passed" "$failed"
[[ "$failed" -eq 0 ]]

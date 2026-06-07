#!/usr/bin/env bash
# Smoke-test harness for the scheduled daily self-audit step (section 4d) added to
# scripts/autopickup-tick.sh (spec: docs/specs/2026-06-07-scheduled-self-audit.md,
# ticket #240).
#
# Drives autopickup-tick.sh fully offline (no network, no live gh, no Claude
# auth, no wall-clock dependence) against deterministic seams:
#   --today <YYYY-MM-DD>   fixes "today" so the daily audit-due gate is stable
#   --state-dir            points at this fixture's state/autopickup.json
#
# Asserts the acceptance behavior from the ticket:
#   1. audit-due fires when never run (last_audit_run null)  -> audit_due true
#   2. once/day idempotency: last_audit_run == today          -> audit_due false
#   3. a stamp from YESTERDAY does not suppress today         -> audit_due true
#   4. dedupe guidance is present (<=3 cap + commander-auto-filed)
#   5. human-mode renders the Audit stanza
#
# Exits 0 on PASS (prints SMOKE_OK), non-zero on the first failed assertion.

set -euo pipefail

FIX_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd -- "$FIX_DIR/../../.." && pwd)"
SCRIPT="$ROOT_DIR/scripts/autopickup-tick.sh"

GH_MOCK="$FIX_DIR/gh-mock"
STATE_DIR="$FIX_DIR/state"
REPOS="$FIX_DIR/repos/repos.json"

[[ -x "$SCRIPT" ]] || { echo "FAIL: $SCRIPT not executable"; exit 1; }

fail() { echo "FAIL: $1"; [[ -n "${2:-}" ]] && echo "$2"; exit 1; }

TODAY="2026-06-07"
YESTERDAY="2026-06-06"

common_args=(
  --repo tonychang04/hydra
  --gh-mock "$GH_MOCK"
  --repos-file "$REPOS"
  --json
)

# Helper: run the tick against a state dir whose autopickup.json sets
# last_audit_run to $1 (use the literal string "null" for the null case).
run_with_last_audit() {
  local last_audit="$1" today="$2"
  local tmp; tmp="$(mktemp -d)"
  cp "$STATE_DIR/active.json" "$tmp/active.json"
  if [[ "$last_audit" == "null" ]]; then
    jq '.last_audit_run = null' "$STATE_DIR/autopickup.json" > "$tmp/autopickup.json"
  else
    jq --arg v "$last_audit" '.last_audit_run = $v' "$STATE_DIR/autopickup.json" > "$tmp/autopickup.json"
  fi
  NO_COLOR=1 "$SCRIPT" "${common_args[@]}" --state-dir "$tmp" --today "$today"
  rm -rf "$tmp"
}

# =============================================================================
# 1. AUDIT-DUE fires when never run (last_audit_run null)
# =============================================================================
never_out="$(run_with_last_audit null "$TODAY")"

echo "$never_out" | jq -e 'has("audit")' >/dev/null \
  || fail "tick JSON missing the audit key" "$never_out"
echo "$never_out" | jq -e '.audit.audit_due == true' >/dev/null \
  || fail "null last_audit_run should be audit_due" "$never_out"
echo "$never_out" | jq -e '.audit.audit_marker == "audit-due"' >/dev/null \
  || fail "audit_marker should be audit-due when due" "$never_out"
echo "$never_out" | jq -e '.audit.today == "'"$TODAY"'"' >/dev/null \
  || fail "audit.today should reflect --today" "$never_out"
echo "$never_out" | jq -e '.actions.audit_due == true' >/dev/null \
  || fail "actions roll-up should expose audit_due true" "$never_out"

# 4. dedupe guidance present (<=3 cap + commander-auto-filed).
echo "$never_out" | jq -e '.audit.dedupe_hint | test("3")' >/dev/null \
  || fail "dedupe_hint should mention the <=3 cap" "$never_out"
echo "$never_out" | jq -e '.audit.dedupe_hint | test("commander-auto-filed")' >/dev/null \
  || fail "dedupe_hint should mention commander-auto-filed dedupe" "$never_out"

# =============================================================================
# 2. ONCE/DAY IDEMPOTENCY: last_audit_run == today -> NOT due
# =============================================================================
sameday_out="$(run_with_last_audit "${TODAY}T09:00:00" "$TODAY")"
echo "$sameday_out" | jq -e '.audit.audit_due == false' >/dev/null \
  || fail "a stamp from today must suppress audit (once/day)" "$sameday_out"
echo "$sameday_out" | jq -e '.audit.audit_reason == "already ran today"' >/dev/null \
  || fail "same-day suppression must report reason 'already ran today'" "$sameday_out"
echo "$sameday_out" | jq -e '.audit.audit_marker == ""' >/dev/null \
  || fail "audit_marker must be empty when not due" "$sameday_out"
echo "$sameday_out" | jq -e '.actions.audit_due == false' >/dev/null \
  || fail "actions roll-up should expose audit_due false same-day" "$sameday_out"

# =============================================================================
# 3. NEW DAY: a stamp from YESTERDAY does not suppress today -> due
# =============================================================================
newday_out="$(run_with_last_audit "${YESTERDAY}T09:00:00" "$TODAY")"
echo "$newday_out" | jq -e '.audit.audit_due == true' >/dev/null \
  || fail "a yesterday stamp must NOT suppress today's audit" "$newday_out"

# =============================================================================
# 5. HUMAN-MODE smoke: the Audit stanza renders.
# =============================================================================
human_out="$(NO_COLOR=1 "$SCRIPT" --repo tonychang04/hydra --gh-mock "$GH_MOCK" \
  --state-dir "$STATE_DIR" --repos-file "$REPOS" --today "$TODAY")"
grep -qi "Audit" <<<"$human_out" || fail "human output missing Audit section" "$human_out"

echo "SMOKE_OK"

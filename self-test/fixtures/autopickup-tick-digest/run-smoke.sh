#!/usr/bin/env bash
# Smoke-test harness for the daily-digest tick step (section 4f) added to
# scripts/autopickup-tick.sh (spec: docs/specs/2026-06-08-digest-tick-step.md,
# ticket #266).
#
# Drives autopickup-tick.sh fully offline (no network, no live gh, no Claude
# auth, no wall-clock dependence) against deterministic seams:
#   --today <YYYY-MM-DD>   fixes "today" so the daily digest-due date gate is stable
#   --hour <0-23>          fixes "now" hour for the time-of-day gate
#   --minute <0-59>        fixes "now" minute for the time-of-day gate
#   --state-dir            points at the fixture state dir (incl. state/digests.json)
#
# The digest scheduler state (enabled / time / last_digest_run) lives on the
# CANONICAL state/digests.json (written by ./hydra connect digest) — the tick's
# section-4f digest step reads it FROM THERE, not from autopickup.json. The
# run_with helper therefore drives digests.json.
#
# Asserts the acceptance behavior from the ticket:
#   0. ENABLED gate: digests.json:.enabled == false           -> digest_due false
#   1. digest-due fires when enabled + never run (last_digest_run null) AND now >= time
#   2. once/day idempotency: last_digest_run == today         -> digest_due false
#   3. a stamp from YESTERDAY does not suppress today         -> digest_due true
#   4. before configured time (now < time)                    -> digest_due false
#   5. human-mode renders the Digest stanza
#   6. run_hint mentions build-daily-digest.sh + last_digest_run (Commander actuates)
#   7. MUTATION PROOF: stripping the time-of-day gate clause from a copy of the
#      tick makes assertion 4 (before-time should be NOT due) flip to due -> the
#      test would fail, proving the time gate is actually constrained.
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

TODAY="2026-06-08"
YESTERDAY="2026-06-07"

common_args=(
  --repo tonychang04/hydra
  --gh-mock "$GH_MOCK"
  --repos-file "$REPOS"
  --json
)

# Helper: run a given tick SCRIPT against a state dir whose CANONICAL
# state/digests.json sets last_digest_run to $1 (literal string "null" for the
# null case), at the given today/hour/minute. $5 is the script path (so the
# mutation test can pass a patched copy). $6 (optional, default "true") sets
# digests.json:.enabled so the enabled-gate case can flip it off. autopickup.json
# is copied through unchanged — the digest step does not read it.
run_with() {
  local last_digest="$1" today="$2" hour="$3" minute="$4" script="${5:-$SCRIPT}" enabled="${6:-true}"
  local tmp; tmp="$(mktemp -d)"
  cp "$STATE_DIR/active.json"     "$tmp/active.json"
  cp "$STATE_DIR/autopickup.json" "$tmp/autopickup.json"
  if [[ "$last_digest" == "null" ]]; then
    jq --argjson en "$enabled" '.enabled = $en | .last_digest_run = null' \
      "$STATE_DIR/digests.json" > "$tmp/digests.json"
  else
    jq --argjson en "$enabled" --arg v "$last_digest" '.enabled = $en | .last_digest_run = $v' \
      "$STATE_DIR/digests.json" > "$tmp/digests.json"
  fi
  NO_COLOR=1 "$script" --repo tonychang04/hydra --gh-mock "$GH_MOCK" \
    --repos-file "$REPOS" --state-dir "$tmp" \
    --today "$today" --hour "$hour" --minute "$minute" --json
  rm -rf "$tmp"
}

# =============================================================================
# 0. ENABLED GATE: digests.json:.enabled == false -> NOT due (un-wired digest).
#    Even with last_digest_run null and now after the configured time, an
#    un-subscribed digest must never report due — a fresh clone is inert.
# =============================================================================
disabled_out="$(run_with null "$TODAY" 10 0 "$SCRIPT" false)"
echo "$disabled_out" | jq -e '.digest.digest_due == false' >/dev/null \
  || fail "a disabled digest (enabled=false) must NOT be due" "$disabled_out"
echo "$disabled_out" | jq -e '.digest.digest_reason | test("not enabled")' >/dev/null \
  || fail "disabled digest must report a 'not enabled' reason" "$disabled_out"
echo "$disabled_out" | jq -e '.digest.digest_marker == ""' >/dev/null \
  || fail "digest_marker must be empty when not enabled" "$disabled_out"
echo "$disabled_out" | jq -e '.actions.digest_due == false' >/dev/null \
  || fail "actions roll-up should expose digest_due false when not enabled" "$disabled_out"

# =============================================================================
# 1. DIGEST-DUE fires when enabled + never run (last_digest_run null) and now >= time
# =============================================================================
# digest time fixture default is 09:00; place "now" at 10:00 (after).
never_out="$(run_with null "$TODAY" 10 0)"

echo "$never_out" | jq -e 'has("digest")' >/dev/null \
  || fail "tick JSON missing the digest key" "$never_out"
echo "$never_out" | jq -e '.digest.digest_due == true' >/dev/null \
  || fail "null last_digest_run after digest_time should be digest_due" "$never_out"
echo "$never_out" | jq -e '.digest.digest_marker == "digest-due"' >/dev/null \
  || fail "digest_marker should be digest-due when due" "$never_out"
echo "$never_out" | jq -e '.digest.today == "'"$TODAY"'"' >/dev/null \
  || fail "digest.today should reflect --today" "$never_out"
echo "$never_out" | jq -e '.digest.digest_time == "09:00"' >/dev/null \
  || fail "digest.digest_time should reflect the fixture default 09:00" "$never_out"
echo "$never_out" | jq -e '.actions.digest_due == true' >/dev/null \
  || fail "actions roll-up should expose digest_due true" "$never_out"

# 6. run_hint present, points Commander at the composer + stamping.
echo "$never_out" | jq -e '.digest.run_hint | test("build-daily-digest")' >/dev/null \
  || fail "run_hint should mention build-daily-digest.sh" "$never_out"
echo "$never_out" | jq -e '.digest.run_hint | test("last_digest_run")' >/dev/null \
  || fail "run_hint should mention stamping last_digest_run" "$never_out"

# =============================================================================
# 2. ONCE/DAY IDEMPOTENCY: last_digest_run == today -> NOT due
# =============================================================================
sameday_out="$(run_with "${TODAY}T09:00:00" "$TODAY" 10 0)"
echo "$sameday_out" | jq -e '.digest.digest_due == false' >/dev/null \
  || fail "a stamp from today must suppress the digest (once/day)" "$sameday_out"
echo "$sameday_out" | jq -e '.digest.digest_reason == "already ran today"' >/dev/null \
  || fail "same-day suppression must report reason 'already ran today'" "$sameday_out"
echo "$sameday_out" | jq -e '.digest.digest_marker == ""' >/dev/null \
  || fail "digest_marker must be empty when not due" "$sameday_out"
echo "$sameday_out" | jq -e '.actions.digest_due == false' >/dev/null \
  || fail "actions roll-up should expose digest_due false same-day" "$sameday_out"

# =============================================================================
# 3. NEW DAY: a stamp from YESTERDAY does not suppress today -> due
# =============================================================================
newday_out="$(run_with "${YESTERDAY}T09:00:00" "$TODAY" 10 0)"
echo "$newday_out" | jq -e '.digest.digest_due == true' >/dev/null \
  || fail "a yesterday stamp must NOT suppress today's digest" "$newday_out"

# =============================================================================
# 4. BEFORE CONFIGURED TIME: never-run but now (08:59) < digest_time (09:00) -> NOT due
# =============================================================================
before_out="$(run_with null "$TODAY" 8 59)"
echo "$before_out" | jq -e '.digest.digest_due == false' >/dev/null \
  || fail "before digest_time the digest must NOT be due" "$before_out"
echo "$before_out" | jq -e '.digest.digest_reason | test("before configured time")' >/dev/null \
  || fail "before-time suppression must report a 'before configured time' reason" "$before_out"
echo "$before_out" | jq -e '.digest.digest_marker == ""' >/dev/null \
  || fail "digest_marker must be empty before configured time" "$before_out"

# Boundary: exactly AT digest_time (09:00) -> due (>= is inclusive).
at_out="$(run_with null "$TODAY" 9 0)"
echo "$at_out" | jq -e '.digest.digest_due == true' >/dev/null \
  || fail "exactly at digest_time (09:00) the digest must be due (>= inclusive)" "$at_out"

# =============================================================================
# 5. HUMAN-MODE smoke: the Digest stanza renders.
# =============================================================================
human_out="$(NO_COLOR=1 "$SCRIPT" --repo tonychang04/hydra --gh-mock "$GH_MOCK" \
  --state-dir "$STATE_DIR" --repos-file "$REPOS" --today "$TODAY" --hour 10 --minute 0)"
grep -qi "Digest" <<<"$human_out" || fail "human output missing Digest section" "$human_out"

# =============================================================================
# 7. MUTATION PROOF: strip the time-of-day gate so before-time would become due.
# Build a patched copy of the tick that drops the `now_hm < digest_time` clause
# (replace the guard's comparison with one that never trips). Re-run the
# before-time case; it should now (wrongly) be due — confirming the real test
# actually constrains the time gate. We assert the MUTANT misbehaves.
# =============================================================================
# The mutant must live INSIDE scripts/ so its $BASH_SOURCE-relative ROOT_DIR
# resolution still finds the sibling scripts (pr-shepherd.sh etc.); a /tmp copy
# would resolve ROOT_DIR to /tmp and abort before reaching the digest block.
mutant="$ROOT_DIR/scripts/.autopickup-tick.digest-mutant.$$.sh"
cleanup_mutant() { rm -f "$mutant"; }
trap cleanup_mutant EXIT
# Neutralize the time-gate: turn the `digest_now_hm < digest_time` comparison
# into one that is always false (X < "" is false for any non-empty HH:MM), so
# the time clause can never suppress. Matches the canonical guard line shape in
# scripts/autopickup-tick.sh section 4f.
sed -E 's/\[\[ "\$digest_now_hm" < "\$digest_time" \]\]/[[ "$digest_now_hm" < "" ]]/' "$SCRIPT" > "$mutant"
chmod +x "$mutant"
if ! grep -q '"\$digest_now_hm" < ""' "$mutant"; then
  fail "mutation proof could not patch the time-gate clause (guard line shape changed?)"
fi
mut_before_out="$(run_with null "$TODAY" 8 59 "$mutant")"
cleanup_mutant; trap - EXIT
echo "$mut_before_out" | jq -e '.digest.digest_due == true' >/dev/null \
  || fail "MUTATION PROOF FAILED: removing the time gate did NOT make before-time due — the time gate is not actually exercised by assertion 4" "$mut_before_out"

echo "SMOKE_OK"

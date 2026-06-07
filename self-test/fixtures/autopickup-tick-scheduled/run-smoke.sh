#!/usr/bin/env bash
# Smoke-test harness for the scheduled-checks + memory-hygiene steps added to
# scripts/autopickup-tick.sh (spec: docs/specs/2026-06-06-autopickup-tick-orchestrator.md,
# ticket #239).
#
# Drives autopickup-tick.sh fully offline (no network, no live gh, no Claude
# auth, no wall-clock dependence) against deterministic test seams:
#   --weekday/--hour/--week  fix "now" so Monday-09:00 retro detection is stable
#   --tickets-total/--hygiene-threshold  drive the memory-hygiene counter
#   --retros-dir/--retro-file-cmd        stub retro file presence + the filer
#   --rescue-mock                        stand in for rescue-worker --probe
#
# Asserts the three acceptance behaviors from the ticket:
#   1. Monday >=09:00 retro-due detection (idempotent via last_retro_run)
#   2. memory-hygiene counter trips at the threshold (10)
#   3. rescue-probe is invoked for a stale fixture worker
# plus promotion-due delegation to promote-citations.sh --check-due.
#
# Exits 0 on PASS (prints SMOKE_OK), non-zero on the first failed assertion.

set -euo pipefail

FIX_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd -- "$FIX_DIR/../../.." && pwd)"
SCRIPT="$ROOT_DIR/scripts/autopickup-tick.sh"

GH_MOCK="$FIX_DIR/gh-mock"
STATE_DIR="$FIX_DIR/state"
REPOS="$FIX_DIR/repos/repos.json"
RESCUE_MOCK="$FIX_DIR/rescue-mock.jsonl"

[[ -x "$SCRIPT" ]] || { echo "FAIL: $SCRIPT not executable"; exit 1; }

fail() { echo "FAIL: $1"; [[ -n "${2:-}" ]] && echo "$2"; exit 1; }

common_args=(
  --repo tonychang04/hydra
  --gh-mock "$GH_MOCK"
  --state-dir "$STATE_DIR"
  --repos-file "$REPOS"
  --rescue-mock "$RESCUE_MOCK"
  --json
)

# A retros dir containing the current-week retro file, and a stub filer that
# just echoes a deterministic FILED line (no gh calls).
RETROS_DIR="$(mktemp -d)"
trap 'rm -rf "$RETROS_DIR"' EXIT
RETRO_WEEK="2026-23"
: > "$RETROS_DIR/${RETRO_WEEK}.md"
RETRO_STUB='echo "FILED: https://example/issue/1"'

# =============================================================================
# 1. MONDAY >=09:00 RETRO-DUE DETECTION + idempotency
# =============================================================================
# Monday (ISO weekday 1) at 09:00, last_retro_run is a prior week -> due.
mon_out="$(NO_COLOR=1 "$SCRIPT" "${common_args[@]}" \
  --weekday 1 --hour 9 --week "$RETRO_WEEK" \
  --retros-dir "$RETROS_DIR" --retro-file-cmd "$RETRO_STUB")"

echo "$mon_out" | jq -e 'has("scheduled") and has("hygiene")' >/dev/null \
  || fail "tick JSON missing scheduled/hygiene keys" "$mon_out"
echo "$mon_out" | jq -e '.scheduled.retro_due == true' >/dev/null \
  || fail "Monday 09:00 with stale last_retro_run should be retro_due" "$mon_out"
# retro file present -> the filer was invoked and its result captured.
echo "$mon_out" | jq -e '.scheduled.retro_file_present == true' >/dev/null \
  || fail "retro_file_present should be true (fixture retro file exists)" "$mon_out"
echo "$mon_out" | jq -e '.scheduled.retro_marker == "retro-filed"' >/dev/null \
  || fail "retro_marker should be retro-filed when the retro file exists" "$mon_out"
echo "$mon_out" | jq -e '.scheduled.retro_file_result | test("FILED")' >/dev/null \
  || fail "retro_file_result should carry the filer output" "$mon_out"

# Monday 09:00 but NO retro file yet -> due, but marker tells Commander to write
# the retro first (filing cannot happen without a retro file).
nofile_out="$(NO_COLOR=1 "$SCRIPT" "${common_args[@]}" \
  --weekday 1 --hour 9 --week 2026-99 \
  --retros-dir "$RETROS_DIR" --retro-file-cmd "$RETRO_STUB")"
echo "$nofile_out" | jq -e '.scheduled.retro_due == true and .scheduled.retro_file_present == false' >/dev/null \
  || fail "missing retro file should be retro_due with retro_file_present false" "$nofile_out"
echo "$nofile_out" | jq -e '.scheduled.retro_marker == "retro-due-write-first"' >/dev/null \
  || fail "no retro file -> marker retro-due-write-first" "$nofile_out"

# Tuesday -> not due regardless of last_retro_run.
tue_out="$(NO_COLOR=1 "$SCRIPT" "${common_args[@]}" \
  --weekday 2 --hour 9 --week "$RETRO_WEEK" \
  --retros-dir "$RETROS_DIR" --retro-file-cmd "$RETRO_STUB")"
echo "$tue_out" | jq -e '.scheduled.retro_due == false' >/dev/null \
  || fail "Tuesday should never be retro_due" "$tue_out"

# Monday before 09:00 -> not due.
early_out="$(NO_COLOR=1 "$SCRIPT" "${common_args[@]}" \
  --weekday 1 --hour 8 --week "$RETRO_WEEK" \
  --retros-dir "$RETROS_DIR" --retro-file-cmd "$RETRO_STUB")"
echo "$early_out" | jq -e '.scheduled.retro_due == false' >/dev/null \
  || fail "Monday before 09:00 should not be retro_due" "$early_out"

# Idempotency: last_retro_run already in the CURRENT week -> not due even Monday.
IDEM_STATE="$(mktemp -d)"
cp "$STATE_DIR/active.json" "$IDEM_STATE/active.json"
jq --arg wk "$RETRO_WEEK" '.last_retro_run = "2026-06-01T09:00:00" | .tickets_at_last_hygiene = 0' \
  "$STATE_DIR/autopickup.json" > "$IDEM_STATE/autopickup.json"
# 2026-W23 spans 2026-06-01..06-07, so a 06-01 stamp is in-week.
idem_out="$(NO_COLOR=1 "$SCRIPT" --repo tonychang04/hydra --gh-mock "$GH_MOCK" \
  --state-dir "$IDEM_STATE" --repos-file "$REPOS" --rescue-mock "$RESCUE_MOCK" --json \
  --weekday 1 --hour 9 --week "$RETRO_WEEK" \
  --retros-dir "$RETROS_DIR" --retro-file-cmd "$RETRO_STUB")"
rm -rf "$IDEM_STATE"
echo "$idem_out" | jq -e '.scheduled.retro_due == false' >/dev/null \
  || fail "retro already run this week must NOT be due (idempotency)" "$idem_out"

# =============================================================================
# 2. MEMORY-HYGIENE COUNTER trips at threshold
# =============================================================================
# baseline tickets_at_last_hygiene=0; total 10, threshold 10 -> due.
hy_due="$(NO_COLOR=1 "$SCRIPT" "${common_args[@]}" \
  --weekday 2 --hour 9 --week "$RETRO_WEEK" \
  --tickets-total 10 --hygiene-threshold 10)"
echo "$hy_due" | jq -e '.hygiene.tickets_since == 10' >/dev/null \
  || fail "tickets_since should be 10 (total 10 - baseline 0)" "$hy_due"
echo "$hy_due" | jq -e '.hygiene.hygiene_due == true' >/dev/null \
  || fail "hygiene should trip at threshold 10" "$hy_due"
echo "$hy_due" | jq -e '.hygiene.hygiene_marker == "compact-memory"' >/dev/null \
  || fail "hygiene_marker should be compact-memory when due" "$hy_due"

# total 9 -> not due.
hy_not="$(NO_COLOR=1 "$SCRIPT" "${common_args[@]}" \
  --weekday 2 --hour 9 --week "$RETRO_WEEK" \
  --tickets-total 9 --hygiene-threshold 10)"
echo "$hy_not" | jq -e '.hygiene.hygiene_due == false' >/dev/null \
  || fail "9 tickets should NOT trip the threshold of 10" "$hy_not"
echo "$hy_not" | jq -e '.hygiene.hygiene_marker == ""' >/dev/null \
  || fail "hygiene_marker should be empty when not due" "$hy_not"

# =============================================================================
# 3. RESCUE-PROBE invoked for a stale fixture worker
# =============================================================================
# The single fixture worker (#401) has a rescue-commits mock verdict -> the tick
# must drive the probe and classify it needs-rescue.
echo "$mon_out" | jq -e '
  .rescue[] | select(.branch == "hydra/commander/401")
  | .verdict == "rescue-commits" and .action == "needs-rescue"
' >/dev/null || fail "rescue-probe should classify the stale worker #401 as needs-rescue" "$mon_out"
echo "$mon_out" | jq -e '[.rescue[] | select(.action == "needs-rescue")] | length == 1' >/dev/null \
  || fail "expected exactly 1 needs-rescue worker in the scheduled fixture" "$mon_out"

# =============================================================================
# 4. PROMOTION-DUE delegation to promote-citations.sh --check-due
# =============================================================================
# Fixture last_promotion_run is null -> due.
echo "$mon_out" | jq -e '.scheduled.promotion_due == true' >/dev/null \
  || fail "promotion should be due when last_promotion_run is null" "$mon_out"

# last_promotion_run == today -> not due.
PROMO_STATE="$(mktemp -d)"
cp "$STATE_DIR/active.json" "$PROMO_STATE/active.json"
TODAY="$(date +%F)"
jq --arg t "$TODAY" '.last_promotion_run = $t | .tickets_at_last_hygiene = 0' \
  "$STATE_DIR/autopickup.json" > "$PROMO_STATE/autopickup.json"
promo_out="$(NO_COLOR=1 "$SCRIPT" --repo tonychang04/hydra --gh-mock "$GH_MOCK" \
  --state-dir "$PROMO_STATE" --repos-file "$REPOS" --rescue-mock "$RESCUE_MOCK" --json \
  --weekday 2 --hour 9 --week "$RETRO_WEEK" --today "$TODAY")"
rm -rf "$PROMO_STATE"
echo "$promo_out" | jq -e '.scheduled.promotion_due == false' >/dev/null \
  || fail "promotion should NOT be due when last_promotion_run is today" "$promo_out"

# =============================================================================
# 5. HUMAN-MODE smoke: new sections render.
# =============================================================================
human_out="$(NO_COLOR=1 "$SCRIPT" --repo tonychang04/hydra --gh-mock "$GH_MOCK" \
  --state-dir "$STATE_DIR" --repos-file "$REPOS" --rescue-mock "$RESCUE_MOCK" \
  --weekday 1 --hour 9 --week "$RETRO_WEEK" \
  --retros-dir "$RETROS_DIR" --retro-file-cmd "$RETRO_STUB" \
  --tickets-total 10 --hygiene-threshold 10)"
grep -qi "Scheduled" <<<"$human_out" || fail "human output missing Scheduled section" "$human_out"
grep -qi "Hygiene" <<<"$human_out" || fail "human output missing Hygiene section" "$human_out"

echo "SMOKE_OK"

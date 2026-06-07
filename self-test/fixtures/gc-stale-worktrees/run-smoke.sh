#!/usr/bin/env bash
# Smoke-test harness for scripts/gc-stale-worktrees.sh AND the autopickup-tick
# interval-guard + gc-reporting additions (spec:
# docs/specs/2026-06-07-tick-stall-robustness.md, ticket #242).
#
# Fully offline (no network, no live gh, no Claude auth, no live worktrees beyond
# a throwaway tempdir tree this harness builds). Deterministic seams:
#   gc:   --root/--state-dir/--worktrees-dir/--max-age-s point at the fixture
#   tick: --worktrees-dir points the gc step at the fixture tree;
#         --state-dir selects the autopickup.json whose interval_min is asserted.
#
# Asserts the acceptance behavior from the ticket:
#   1. gc dry-run lists ONLY the stale non-active dir (fresh + active are spared)
#   2. gc --apply removes ONLY the stale non-active dir
#   3. gc fails closed when active.json is missing (--apply exits 1, removes nothing)
#   4. interval-guard WARN fires for interval_min=30, not for interval_min=10
#   5. the tick gc section reports the stale candidate (+ human stanza renders)
#
# Exits 0 on PASS (prints SMOKE_OK), non-zero on the first failed assertion.

set -euo pipefail

FIX_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd -- "$FIX_DIR/../../.." && pwd)"
GC="$ROOT_DIR/scripts/gc-stale-worktrees.sh"
TICK="$ROOT_DIR/scripts/autopickup-tick.sh"

[[ -x "$GC" ]]   || { echo "FAIL: $GC not executable"; exit 1; }
[[ -x "$TICK" ]] || { echo "FAIL: $TICK not executable"; exit 1; }

fail() { echo "FAIL: $1"; [[ -n "${2:-}" ]] && echo "$2"; exit 1; }

# -----------------------------------------------------------------------------
# Build a throwaway worktrees tree + state in a tempdir.
#   agent-STALE   25h old, NOT in active.json   -> candidate
#   agent-FRESH   just created, not in active    -> spared (too young)
#   agent-ACTIVE  25h old but listed in active   -> spared (active)
# -----------------------------------------------------------------------------
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT INT TERM

WT_DIR="$TMP/.claude/worktrees"
STATE_DIR="$TMP/state"
mkdir -p "$WT_DIR" "$STATE_DIR"

mk_dir() { mkdir -p "$WT_DIR/$1"; : > "$WT_DIR/$1/marker"; }
mk_dir agent-STALE
mk_dir agent-FRESH
mk_dir agent-ACTIVE

# Age agent-STALE and agent-ACTIVE to 25h old; leave agent-FRESH at "now".
# touch -t needs YYYYMMDDhhmm; compute "25h ago" portably (BSD vs GNU date).
old_ts="$(date -v-25H +%Y%m%d%H%M 2>/dev/null || date -d '25 hours ago' +%Y%m%d%H%M)"
touch -t "$old_ts" "$WT_DIR/agent-STALE" "$WT_DIR/agent-ACTIVE"

# active.json lists ONLY agent-ACTIVE (absolute path).
cat > "$STATE_DIR/active.json" <<JSON
{
  "workers": [
    { "id": "w-active", "ticket": "999", "repo": "tonychang04/hydra",
      "tier": "T2", "started_at": "2026-06-06T00:00:00Z",
      "subagent_type": "worker-implementation", "status": "running",
      "worktree": "$WT_DIR/agent-ACTIVE", "branch": "hydra/commander/999" }
  ],
  "last_updated": "2026-06-06T00:00:00Z"
}
JSON

gc_common=(--root "$TMP" --state-dir "$STATE_DIR" --worktrees-dir "$WT_DIR" --json)

# =============================================================================
# 1. DRY-RUN lists ONLY agent-STALE
# =============================================================================
dry_out="$("$GC" "${gc_common[@]}" --dry-run)"
echo "$dry_out" | jq -e '.dry_run == true' >/dev/null \
  || fail "dry-run should report dry_run=true" "$dry_out"
echo "$dry_out" | jq -e '.fail_closed == false' >/dev/null \
  || fail "dry-run should not be fail-closed (active.json present)" "$dry_out"
echo "$dry_out" | jq -e '[.candidates[].path | endswith("/agent-STALE")] | any' >/dev/null \
  || fail "agent-STALE should be a candidate" "$dry_out"
echo "$dry_out" | jq -e '[.candidates[].path | endswith("/agent-FRESH")] | any | not' >/dev/null \
  || fail "agent-FRESH (too young) must NOT be a candidate" "$dry_out"
echo "$dry_out" | jq -e '[.candidates[].path | endswith("/agent-ACTIVE")] | any | not' >/dev/null \
  || fail "agent-ACTIVE (in active.json) must NOT be a candidate" "$dry_out"
echo "$dry_out" | jq -e '.candidates | length == 1' >/dev/null \
  || fail "exactly one candidate expected" "$dry_out"
echo "$dry_out" | jq -e '.removed == []' >/dev/null \
  || fail "dry-run must remove nothing" "$dry_out"
[[ -d "$WT_DIR/agent-STALE" ]] || fail "dry-run must not delete agent-STALE from disk"

# =============================================================================
# 2. --apply removes ONLY agent-STALE
# =============================================================================
apply_out="$("$GC" "${gc_common[@]}" --apply)"
echo "$apply_out" | jq -e '[.removed[] | endswith("/agent-STALE")] | any' >/dev/null \
  || fail "apply should remove agent-STALE" "$apply_out"
echo "$apply_out" | jq -e '.removed | length == 1' >/dev/null \
  || fail "apply should remove exactly one dir" "$apply_out"
[[ ! -d "$WT_DIR/agent-STALE" ]]  || fail "agent-STALE should be gone after --apply"
[[ -d "$WT_DIR/agent-FRESH" ]]    || fail "agent-FRESH must survive --apply"
[[ -d "$WT_DIR/agent-ACTIVE" ]]   || fail "agent-ACTIVE must survive --apply"

# =============================================================================
# 3. FAIL-CLOSED when active.json is missing
# =============================================================================
EMPTY_STATE="$TMP/empty-state"
mkdir -p "$EMPTY_STATE"
# re-create a stale dir to prove it is NOT removed under fail-closed
mk_dir agent-STALE2
touch -t "$old_ts" "$WT_DIR/agent-STALE2"

fc_dry="$("$GC" --root "$TMP" --state-dir "$EMPTY_STATE" --worktrees-dir "$WT_DIR" --json --dry-run)"
echo "$fc_dry" | jq -e '.fail_closed == true' >/dev/null \
  || fail "missing active.json should report fail_closed=true" "$fc_dry"
echo "$fc_dry" | jq -e '.candidates == []' >/dev/null \
  || fail "fail-closed dry-run must report zero candidates" "$fc_dry"

set +e
"$GC" --root "$TMP" --state-dir "$EMPTY_STATE" --worktrees-dir "$WT_DIR" --apply >/dev/null 2>&1
fc_rc=$?
set -e
[[ "$fc_rc" -eq 1 ]] || fail "fail-closed --apply must exit 1 (got $fc_rc)"
[[ -d "$WT_DIR/agent-STALE2" ]] || fail "fail-closed --apply must remove nothing"

# =============================================================================
# 4. INTERVAL GUARD: WARN for interval_min=30, none for interval_min=10
# =============================================================================
# Build two autopickup.json states differing only in interval_min, reusing the
# fixture state dir (active.json must validate; we add the autopickup file).
mk_autopickup() {
  local interval="$1" dst="$2"
  cat > "$dst/autopickup.json" <<JSON
{
  "enabled": true,
  "interval_min": $interval,
  "auto_enable_on_session_start": true,
  "last_run": "2026-06-07T08:00:00Z",
  "last_picked_count": 0,
  "consecutive_rate_limit_hits": 0,
  "last_retro_run": "2026-06-07T09:00:00",
  "last_promotion_run": "2026-06-07",
  "last_audit_run": "2026-06-07T09:00:00",
  "tickets_at_last_hygiene": 0
}
JSON
}

WARN_STATE="$TMP/warn-state"; mkdir -p "$WARN_STATE"
cp "$STATE_DIR/active.json" "$WARN_STATE/active.json"
mk_autopickup 30 "$WARN_STATE"

OK_STATE="$TMP/ok-state"; mkdir -p "$OK_STATE"
cp "$STATE_DIR/active.json" "$OK_STATE/active.json"
mk_autopickup 10 "$OK_STATE"

REPOS="$ROOT_DIR/self-test/fixtures/autopickup-tick-audit/repos/repos.json"
GH_MOCK="$ROOT_DIR/self-test/fixtures/autopickup-tick-audit/gh-mock"

tick_common=(--repo tonychang04/hydra --gh-mock "$GH_MOCK" --repos-file "$REPOS"
  --worktrees-dir "$WT_DIR" --today "2026-06-07" --json)

warn_tick="$(NO_COLOR=1 "$TICK" "${tick_common[@]}" --state-dir "$WARN_STATE")"
echo "$warn_tick" | jq -e '.preflight.interval_warn == true' >/dev/null \
  || fail "interval_min=30 should set preflight.interval_warn=true" "$warn_tick"
echo "$warn_tick" | jq -e '.preflight.interval_warn_text | test("18")' >/dev/null \
  || fail "interval warn text should mention the 18min ceiling" "$warn_tick"
echo "$warn_tick" | jq -e '.preflight.interval_warn_text | test("15")' >/dev/null \
  || fail "interval warn text should recommend setting <15" "$warn_tick"

ok_tick="$(NO_COLOR=1 "$TICK" "${tick_common[@]}" --state-dir "$OK_STATE")"
echo "$ok_tick" | jq -e '.preflight.interval_warn == false' >/dev/null \
  || fail "interval_min=10 should NOT warn" "$ok_tick"

# =============================================================================
# 5. TICK gc SECTION reports the stale candidate (+ human stanza renders)
# =============================================================================
# agent-STALE2 is still on disk (fail-closed apply did not remove it) and the
# fixture state's active.json lists only agent-ACTIVE -> agent-STALE2 is a candidate.
gc_tick="$(NO_COLOR=1 "$TICK" "${tick_common[@]}" --state-dir "$WARN_STATE")"
echo "$gc_tick" | jq -e 'has("gc")' >/dev/null \
  || fail "tick JSON missing the gc key" "$gc_tick"
echo "$gc_tick" | jq -e '.gc.candidates_count >= 1' >/dev/null \
  || fail "tick gc should report >=1 stale candidate" "$gc_tick"
echo "$gc_tick" | jq -e '.actions.gc_stale_worktrees >= 1' >/dev/null \
  || fail "actions roll-up should expose gc_stale_worktrees >=1" "$gc_tick"

human_tick="$(NO_COLOR=1 "$TICK" --repo tonychang04/hydra --gh-mock "$GH_MOCK" \
  --repos-file "$REPOS" --worktrees-dir "$WT_DIR" --today "2026-06-07" \
  --state-dir "$WARN_STATE")"
grep -qi "Stale worktrees" <<<"$human_tick" || fail "human output missing Stale worktrees section" "$human_tick"
grep -qi "interval" <<<"$human_tick" || fail "human output missing interval WARN line" "$human_tick"

# =============================================================================
# 6. FAIL-CLOSED when active.json is PRESENT but CORRUPT/TRUNCATED (#254 review)
# =============================================================================
# Data-loss blocker: a mid-write crash can leave active.json present + readable
# but unparseable. Without parse validation, the active set comes back empty,
# fail_closed stays false, and every >24h agent-* dir — INCLUDING live workers —
# becomes a deletion candidate. The script MUST treat a corrupt active.json the
# same as a missing one: fail closed, delete nothing.
CORRUPT_STATE="$TMP/corrupt-state"
mkdir -p "$CORRUPT_STATE"
# Truncated/partial JSON — exactly what a crash mid-rewrite leaves behind.
printf '%s' '{ "workers": [ { "id": "w-live", "worktree": "' > "$CORRUPT_STATE/active.json"

# Re-create a stale dir that a VALID file would have protected as a live worker,
# proving the corrupt file does NOT expose it to deletion.
mk_dir agent-STALE3
touch -t "$old_ts" "$WT_DIR/agent-STALE3"

corrupt_dry="$("$GC" --root "$TMP" --state-dir "$CORRUPT_STATE" --worktrees-dir "$WT_DIR" --json --dry-run)"
echo "$corrupt_dry" | jq -e '.fail_closed == true' >/dev/null \
  || fail "corrupt active.json should report fail_closed=true" "$corrupt_dry"
echo "$corrupt_dry" | jq -e '.candidates == []' >/dev/null \
  || fail "corrupt active.json dry-run must report ZERO candidates" "$corrupt_dry"

set +e
"$GC" --root "$TMP" --state-dir "$CORRUPT_STATE" --worktrees-dir "$WT_DIR" --apply >/dev/null 2>&1
corrupt_rc=$?
set -e
[[ "$corrupt_rc" -eq 1 ]] || fail "corrupt active.json --apply must exit 1 (got $corrupt_rc)"
[[ -d "$WT_DIR/agent-STALE3" ]] || fail "corrupt active.json --apply must delete NOTHING"

# =============================================================================
# 7. TICK SURFACES a failed gc safety scan (never reports it as "(none)")
# =============================================================================
# Concern #2: a failed gc scan must be VISIBLE, never look like "clean". With a
# corrupt active.json the gc script reports fail_closed=true (exit 0), so the tick
# must surface the fail-closed state in both JSON and human output rather than
# printing "(none)".
CORRUPT_TICK_STATE="$TMP/corrupt-tick-state"
mkdir -p "$CORRUPT_TICK_STATE"
cp "$CORRUPT_STATE/active.json" "$CORRUPT_TICK_STATE/active.json"
mk_autopickup 10 "$CORRUPT_TICK_STATE"

corrupt_tick="$(NO_COLOR=1 "$TICK" "${tick_common[@]}" --state-dir "$CORRUPT_TICK_STATE")"
echo "$corrupt_tick" | jq -e '.gc.fail_closed == true' >/dev/null \
  || fail "tick gc must surface fail_closed=true on corrupt active.json" "$corrupt_tick"
echo "$corrupt_tick" | jq -e '.gc.scan_ok == true' >/dev/null \
  || fail "tick gc.scan_ok should be true when the script ran (even fail-closed)" "$corrupt_tick"

corrupt_human="$(NO_COLOR=1 "$TICK" --repo tonychang04/hydra --gh-mock "$GH_MOCK" \
  --repos-file "$REPOS" --worktrees-dir "$WT_DIR" --today "2026-06-07" \
  --state-dir "$CORRUPT_TICK_STATE")"
grep -qi "fail-closed\|scan-skipped" <<<"$corrupt_human" \
  || fail "human output must surface gc fail-closed/scan-skipped, not (none)" "$corrupt_human"
# The gc section itself must NOT print "(none)" when fail-closed.
gc_section="$(awk '/Stale worktrees/{f=1;next} f&&/^$/{exit} f' <<<"$corrupt_human")"
grep -qi "(none)" <<<"$gc_section" \
  && fail "gc section must NOT print (none) when the safety scan is fail-closed" "$corrupt_human"

# 7b. Tick surfaces a gc scan that could NOT run at all (binary missing) as
# scan_ok=false — distinct from a clean "(none)".
UNRUN_TICK_STATE="$TMP/unrun-tick-state"
mkdir -p "$UNRUN_TICK_STATE"
cp "$WARN_STATE/active.json" "$UNRUN_TICK_STATE/active.json"
mk_autopickup 10 "$UNRUN_TICK_STATE"
# Point the tick at a gc script path that does not exist / is not executable.
unrun_tick="$(NO_COLOR=1 "$TICK" "${tick_common[@]}" --state-dir "$UNRUN_TICK_STATE" \
  --gc-script "$TMP/no-such-gc.sh")"
echo "$unrun_tick" | jq -e '.gc.scan_ok == false' >/dev/null \
  || fail "tick gc.scan_ok must be false when the gc script could not run" "$unrun_tick"

echo "SMOKE_OK"

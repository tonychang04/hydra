#!/usr/bin/env bash
# Smoke-test harness for scripts/autopickup-tick.sh
# (spec: docs/specs/2026-05-24-self-driving-autopickup-tick.md, ticket #228).
#
# Drives autopickup-tick.sh fully offline (no network, no live gh, no Claude auth)
# against:
#   - a --gh-mock fixture (one open PR per shepherd classification + an orphan +
#     a fail-closed no-file PR), reused by the embedded pr-shepherd call;
#   - a fixture state/active.json whose worker branches match all but the orphan;
#   - a --rescue-mock JSONL standing in for rescue-worker --probe verdicts
#     (no real git worktrees to probe in CI);
#   - a fixture repos.json with mixed merge policies.
#
# It asserts the integrated tick's --json shape and — critically — the auto-merge
# SAFETY RAILS: T3 is never auto-merge-eligible; only review-CLEAN, non-safety-rail
# PRs on an auto* policy are eligible; rail-touching + fail-closed PRs surface for
# human merge.
#
# Classification matrix (merge-ready PRs only — others are excluded by shepherd):
#   #301  hydra      T2 policy=human                 → surface-for-human (policy-human)
#   #302  team-repo  T2 policy=auto_if_review_clean  → auto-merge-eligible
#   #303  team-repo  T2 policy=auto* but touches policy.md → surface-for-human (safety-rail)
#   #304  human-repo T2 policy=human                 → surface-for-human (policy-human)
#   #307  team-repo  T2 policy=auto* (orphaned)      → auto-merge-eligible (orphan flagged)
#   #308  team-repo  T2 policy=auto* but NO file data → surface-for-human (safety-rail, fail-closed)
#   (#305 ci-red, #306 needs-review-gate — not merge-ready, excluded from merge surfacing)
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

common_args=(
  --repo tonychang04/hydra
  --gh-mock "$GH_MOCK"
  --state-dir "$STATE_DIR"
  --repos-file "$REPOS"
  --rescue-mock "$RESCUE_MOCK"
)

fail() { echo "FAIL: $1"; [[ -n "${2:-}" ]] && echo "$2"; exit 1; }

# -----------------------------------------------------------------------------
# Full tick, --json mode.
# -----------------------------------------------------------------------------
json_out="$(NO_COLOR=1 "$SCRIPT" "${common_args[@]}" --json)"

echo "$json_out" | jq -e '
  has("generated_at") and has("repo") and has("preflight")
  and has("shepherd") and has("rescue") and has("merge_surface") and has("actions")
' >/dev/null || fail "json envelope missing top-level keys" "$json_out"

# --- Preflight: PAUSE absent, validation clean, headroom math is HONEST.
# The default fixture runs the fleet at capacity (active >= max_concurrent_workers),
# which is the common steady state: spawn is correctly blocked, but the read-only
# shepherd + rescue scans below still run. (A dedicated headroom-OK sub-test
# further down proves spawn_blocked flips to false when active < max.)
echo "$json_out" | jq -e '.preflight.pause_present == false' >/dev/null \
  || fail "preflight.pause_present should be false (no PAUSE marker)" "$json_out"
echo "$json_out" | jq -e '.preflight.state_valid == true' >/dev/null \
  || fail "preflight.state_valid should be true on the fixture state-dir" "$json_out"
echo "$json_out" | jq -e '.preflight | has("concurrency_headroom") and has("max_workers") and has("active_workers")' >/dev/null \
  || fail "preflight headroom fields missing" "$json_out"
# spawn_blocked must equal (headroom <= 0) when PAUSE absent + state valid.
echo "$json_out" | jq -e '
  (.preflight.concurrency_headroom <= 0) == .preflight.spawn_blocked
' >/dev/null || fail "preflight.spawn_blocked must track headroom honestly" "$json_out"

# --- Shepherd summary carried through (8 PRs total from the mock).
echo "$json_out" | jq -e '.shepherd.summary.total == 8' >/dev/null \
  || fail "shepherd.summary.total != 8" "$json_out"
echo "$json_out" | jq -e '.shepherd.summary.merge_ready == 6' >/dev/null \
  || fail "shepherd.summary.merge_ready != 6 (#301-304,307,308)" "$json_out"

# --- Rescue scan: rescuable verdicts → needs-rescue; healthy → ok; live → surfaced.
rescue_for() { echo "$json_out" | jq -r --arg b "$1" '.rescue[] | select(.branch == $b)'; }

# #305 worker → rescue-commits → action needs-rescue.
echo "$(rescue_for hydra/commander/305)" | jq -e '.verdict == "rescue-commits" and .action == "needs-rescue"' >/dev/null \
  || fail "rescue #305 should classify as needs-rescue (rescue-commits)" "$json_out"
# #302 worker → rescue-uncommitted → needs-rescue.
echo "$(rescue_for hydra/commander/302)" | jq -e '.verdict == "rescue-uncommitted" and .action == "needs-rescue"' >/dev/null \
  || fail "rescue #302 should classify as needs-rescue (rescue-uncommitted)" "$json_out"
# #306 worker → nothing-to-rescue → ok.
echo "$(rescue_for hydra/commander/306)" | jq -e '.verdict == "nothing-to-rescue" and .action == "ok"' >/dev/null \
  || fail "rescue #306 should classify as ok (nothing-to-rescue)" "$json_out"
# #303 worker → worker-mid-tool-call (live) → surfaced verbatim, action live-wait (NOT needs-rescue).
echo "$(rescue_for hydra/commander/303)" | jq -e '.verdict == "worker-mid-tool-call" and .action == "live-wait"' >/dev/null \
  || fail "rescue #303 (live worker) must NOT be needs-rescue; expect action live-wait" "$json_out"
# Exactly 2 needs-rescue.
echo "$json_out" | jq -e '[.rescue[] | select(.action == "needs-rescue")] | length == 2' >/dev/null \
  || fail "expected exactly 2 needs-rescue workers" "$json_out"

# -----------------------------------------------------------------------------
# Merge surfacing — the safety-rail core. Only merge-ready PRs appear here.
# -----------------------------------------------------------------------------
ms_for() { echo "$json_out" | jq -r --argjson n "$1" '.merge_surface[] | select(.number == $n)'; }
assert_ms() {
  local n="$1" want_class="$2" want_reason="${3:-}"
  local row got_class got_reason
  row="$(ms_for "$n")"
  [[ -n "$row" ]] || fail "merge_surface missing PR #$n" "$json_out"
  got_class="$(echo "$row" | jq -r '.classification')"
  [[ "$got_class" == "$want_class" ]] \
    || fail "PR #$n expected classification '$want_class', got '$got_class'" "$json_out"
  if [[ -n "$want_reason" ]]; then
    got_reason="$(echo "$row" | jq -r '.reason')"
    [[ "$got_reason" == "$want_reason" ]] \
      || fail "PR #$n expected reason '$want_reason', got '$got_reason'" "$json_out"
  fi
}

assert_ms 301 surface-for-human   policy-human
assert_ms 302 auto-merge-eligible
assert_ms 303 surface-for-human   safety-rail
assert_ms 304 surface-for-human   policy-human
assert_ms 307 auto-merge-eligible
assert_ms 308 surface-for-human   safety-rail

# Only the merge-ready PRs are surfaced (6 rows).
echo "$json_out" | jq -e '.merge_surface | length == 6' >/dev/null \
  || fail "merge_surface should have exactly 6 rows (the merge-ready PRs)" "$json_out"
# Exactly 2 auto-merge-eligible (#302, #307); the rest surface.
echo "$json_out" | jq -e '[.merge_surface[] | select(.classification == "auto-merge-eligible")] | length == 2' >/dev/null \
  || fail "expected exactly 2 auto-merge-eligible PRs" "$json_out"
# NO merge-ready PR is ever auto-eligible when it touches a rail or has no file data.
echo "$json_out" | jq -e '
  .merge_surface[] | select(.reason == "safety-rail") | .classification == "surface-for-human"
' >/dev/null || fail "a safety-rail PR was NOT surfaced for human" "$json_out"

# actions roll-up present.
echo "$json_out" | jq -e '.actions | has("needs_rescue") and has("auto_merge_eligible") and has("surface_for_human")' >/dev/null \
  || fail "actions roll-up missing keys" "$json_out"
echo "$json_out" | jq -e '.actions.auto_merge_eligible == 2 and .actions.surface_for_human == 4 and .actions.needs_rescue == 2' >/dev/null \
  || fail "actions roll-up counts wrong" "$json_out"

# -----------------------------------------------------------------------------
# T3-NEVER RULE: force tier T3 → every merge-ready PR surfaces, none auto-eligible.
# -----------------------------------------------------------------------------
t3_out="$(NO_COLOR=1 "$SCRIPT" "${common_args[@]}" --tier T3 --json)"
echo "$t3_out" | jq -e '[.merge_surface[] | select(.classification == "auto-merge-eligible")] | length == 0' >/dev/null \
  || fail "T3 must yield ZERO auto-merge-eligible PRs" "$t3_out"
echo "$t3_out" | jq -e 'all(.merge_surface[]; .reason == "t3-never")' >/dev/null \
  || fail "every T3 merge-ready PR must carry reason t3-never" "$t3_out"

# -----------------------------------------------------------------------------
# PREFLIGHT-FAIL PATH: a commander/PAUSE marker blocks spawn but read-only scans
# (shepherd + rescue) still run.
# -----------------------------------------------------------------------------
PAUSE_STATE="$(mktemp -d)"
trap 'rm -rf "$PAUSE_STATE"' EXIT
cp "$STATE_DIR/active.json" "$PAUSE_STATE/active.json"
touch "$PAUSE_STATE/PAUSE"
pause_out="$(NO_COLOR=1 "$SCRIPT" --repo tonychang04/hydra --gh-mock "$GH_MOCK" \
  --state-dir "$PAUSE_STATE" --repos-file "$REPOS" --rescue-mock "$RESCUE_MOCK" --json)"
echo "$pause_out" | jq -e '.preflight.pause_present == true and .preflight.spawn_blocked == true' >/dev/null \
  || fail "PAUSE marker should set pause_present + spawn_blocked true" "$pause_out"
# Read-only scans still ran.
echo "$pause_out" | jq -e '.shepherd.summary.total == 8' >/dev/null \
  || fail "shepherd scan must still run under PAUSE" "$pause_out"
echo "$pause_out" | jq -e '.rescue | length >= 1' >/dev/null \
  || fail "rescue scan must still run under PAUSE" "$pause_out"

# -----------------------------------------------------------------------------
# HEADROOM-OK PATH: with active workers < max_concurrent_workers, preflight is
# clean and spawn is NOT blocked (PAUSE absent, state valid, headroom > 0).
# -----------------------------------------------------------------------------
HEADROOM_STATE="$(mktemp -d)"
# One worker → headroom = max - 1 > 0 for any sane budget (max >= 2).
printf '{"workers":[{"id":"w-302","ticket":"tonychang04/hydra#302","repo":"tonychang04/hydra","tier":"T2","started_at":"2026-05-24T10:00:00Z","subagent_type":"worker-implementation","status":"running","worktree":"/fixture/wt-302","branch":"hydra/commander/302"}],"last_updated":"2026-05-24T10:00:00Z"}' > "$HEADROOM_STATE/active.json"
headroom_out="$(NO_COLOR=1 "$SCRIPT" --repo tonychang04/hydra --gh-mock "$GH_MOCK" \
  --state-dir "$HEADROOM_STATE" --repos-file "$REPOS" --rescue-mock "$RESCUE_MOCK" --json)"
rm -rf "$HEADROOM_STATE"
echo "$headroom_out" | jq -e '.preflight.concurrency_headroom > 0' >/dev/null \
  || fail "headroom should be > 0 with a single active worker" "$headroom_out"
echo "$headroom_out" | jq -e '.preflight.spawn_blocked == false' >/dev/null \
  || fail "spawn should NOT be blocked when headroom > 0 + PAUSE absent + state valid" "$headroom_out"

# -----------------------------------------------------------------------------
# Human-mode smoke: banner + every section header present.
# -----------------------------------------------------------------------------
human_out="$(NO_COLOR=1 "$SCRIPT" "${common_args[@]}")"
grep -q "Autopickup Tick" <<<"$human_out" || fail "banner missing from human output" "$human_out"
for section in Preflight Shepherd Rescue "Merge surfacing"; do
  grep -q "$section" <<<"$human_out" || fail "human output missing section '$section'" "$human_out"
done
grep -q "auto-merge-eligible" <<<"$human_out" || fail "human output missing auto-merge-eligible" "$human_out"
grep -q "surface-for-human" <<<"$human_out" || fail "human output missing surface-for-human" "$human_out"

# -----------------------------------------------------------------------------
# Error paths.
# -----------------------------------------------------------------------------
set +e
NO_COLOR=1 "$SCRIPT" --bogus >/dev/null 2>&1; ec=$?
set -e
[[ "$ec" -eq 2 ]] || fail "--bogus should exit 2, got $ec"

echo "SMOKE_OK"

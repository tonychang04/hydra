#!/usr/bin/env bash
# Smoke-test harness for scripts/pr-shepherd.sh (spec: docs/specs/2026-05-23-pr-shepherd.md, ticket #198).
#
# Drives pr-shepherd.sh against an offline --gh-mock fixture (no network, no live
# gh, no Claude auth) that contains one open PR per classification branch plus an
# orphan, and a fixture state/active.json whose worker branches match all but the
# orphan. Asserts both human-mode substrings and --json-mode shape.
#
# Classification matrix exercised (pr-list.json / threads-*.json):
#   #101  CI red                              → needs-fix          (ci-red)
#   #102  CI pending                          → ci-pending         (ci-pending)
#   #103  green, no commander-reviewed label  → needs-review-gate
#   #104  green, reviewed, isDraft            → ready-to-surface
#   #105  green, reviewed, not draft          → merge-ready
#   #106  green, no worker in active.json     → needs-review-gate + orphaned=true
#   #107  green, reviewed, unresolved thread  → needs-fix          (unresolved-threads)
#
# Intended to be invoked by self-test/run.sh via the pr-shepherd-script golden case.
# Exits 0 on PASS (prints SMOKE_OK), non-zero on the first failed assertion.

set -euo pipefail

FIX_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd -- "$FIX_DIR/../../.." && pwd)"
SCRIPT="$ROOT_DIR/scripts/pr-shepherd.sh"

GH_MOCK="$FIX_DIR/gh-mock"
STATE_DIR="$FIX_DIR/state"

[[ -x "$SCRIPT" ]] || { echo "FAIL: $SCRIPT not executable"; exit 1; }

# --repo is passed explicitly: v1.1 requires strict one-repo-per-invocation for
# orphan matching (no global "$repo == "" admits all workers" path, no loose
# basename match — ticket #221). The default fixture workers are all on the
# tonychang04/hydra slug, so matching resolves the same as before but now via the
# strict exact-slug rule.
common_args=(
  --gh-mock "$GH_MOCK"
  --state-dir "$STATE_DIR"
  --repo tonychang04/hydra
)

# -----------------------------------------------------------------------------
# --json mode checks (exact classification per PR + summary counts)
# -----------------------------------------------------------------------------
json_out="$(NO_COLOR=1 "$SCRIPT" "${common_args[@]}" --json)"

echo "$json_out" | jq -e 'has("generated_at") and has("repo") and has("author") and has("prs") and has("summary")' >/dev/null \
  || { echo "FAIL: json envelope missing top-level keys"; echo "$json_out"; exit 1; }

# Per-PR state assertion helper: assert PR #N has the given state (and optionally reason).
assert_state() {
  local n="$1" want_state="$2" want_reason="${3:-}"
  local got_state got_reason
  got_state="$(echo "$json_out" | jq -r --argjson n "$n" '.prs[] | select(.number == $n) | .state')"
  if [[ "$got_state" != "$want_state" ]]; then
    echo "FAIL: PR #$n expected state '$want_state', got '$got_state'"; echo "$json_out"; exit 1
  fi
  if [[ -n "$want_reason" ]]; then
    got_reason="$(echo "$json_out" | jq -r --argjson n "$n" '.prs[] | select(.number == $n) | .reason')"
    if [[ "$got_reason" != "$want_reason" ]]; then
      echo "FAIL: PR #$n expected reason '$want_reason', got '$got_reason'"; echo "$json_out"; exit 1
    fi
  fi
}

assert_state 101 "needs-fix"         "ci-red"
assert_state 102 "ci-pending"        "ci-pending"
assert_state 103 "needs-review-gate"
assert_state 104 "ready-to-surface"  "reviewed-still-draft"
assert_state 105 "merge-ready"       "reviewed-undrafted"
assert_state 106 "needs-review-gate"
assert_state 107 "needs-fix"         "changes-requested"
# #108: green + reviewed + APPROVED (no CHANGES_REQUESTED) but an unresolved
# review thread → needs-fix via the secondary thread-count signal.
assert_state 108 "needs-fix"         "changes-requested"

# Orphan boolean: only #106 is orphaned (its branch is absent from active.json).
echo "$json_out" | jq -e '.prs[] | select(.number == 106) | .orphaned == true' >/dev/null \
  || { echo "FAIL: PR #106 should be orphaned=true"; echo "$json_out"; exit 1; }
echo "$json_out" | jq -e '[.prs[] | select(.orphaned == true)] | length == 1' >/dev/null \
  || { echo "FAIL: exactly one PR should be orphaned"; echo "$json_out"; exit 1; }
echo "$json_out" | jq -e '.prs[] | select(.number == 101) | .orphaned == false' >/dev/null \
  || { echo "FAIL: PR #101 should be orphaned=false (worker tracks its branch)"; echo "$json_out"; exit 1; }

# A recommended_action must be present and non-empty on every row.
echo "$json_out" | jq -e 'all(.prs[]; (.recommended_action | type == "string") and (.recommended_action | length > 0))' >/dev/null \
  || { echo "FAIL: every PR must carry a non-empty recommended_action"; echo "$json_out"; exit 1; }

# Summary counts.
echo "$json_out" | jq -e '.summary.total == 8' >/dev/null \
  || { echo "FAIL: summary.total != 8"; echo "$json_out"; exit 1; }
echo "$json_out" | jq -e '.summary.needs_fix == 3' >/dev/null \
  || { echo "FAIL: summary.needs_fix != 3 (#101 ci-red + #107 changes-requested + #108 unresolved-thread)"; echo "$json_out"; exit 1; }
echo "$json_out" | jq -e '.summary.ci_pending == 1' >/dev/null \
  || { echo "FAIL: summary.ci_pending != 1"; echo "$json_out"; exit 1; }
echo "$json_out" | jq -e '.summary.needs_review_gate == 2' >/dev/null \
  || { echo "FAIL: summary.needs_review_gate != 2 (#103 + #106 orphan)"; echo "$json_out"; exit 1; }
echo "$json_out" | jq -e '.summary.ready_to_surface == 1' >/dev/null \
  || { echo "FAIL: summary.ready_to_surface != 1"; echo "$json_out"; exit 1; }
echo "$json_out" | jq -e '.summary.merge_ready == 1' >/dev/null \
  || { echo "FAIL: summary.merge_ready != 1"; echo "$json_out"; exit 1; }
echo "$json_out" | jq -e '.summary.orphaned == 1' >/dev/null \
  || { echo "FAIL: summary.orphaned != 1"; echo "$json_out"; exit 1; }

# -----------------------------------------------------------------------------
# Human-mode checks
# -----------------------------------------------------------------------------
human_out="$(NO_COLOR=1 "$SCRIPT" "${common_args[@]}")"

grep -q "PR Shepherd" <<<"$human_out" \
  || { echo "FAIL: banner missing from human output"; printf '%s\n' "$human_out"; exit 1; }
for state in needs-fix ci-pending needs-review-gate ready-to-surface merge-ready; do
  grep -q "$state" <<<"$human_out" \
    || { echo "FAIL: human output missing state '$state'"; printf '%s\n' "$human_out"; exit 1; }
done
grep -q "orphaned" <<<"$human_out" \
  || { echo "FAIL: human output missing orphaned warning"; printf '%s\n' "$human_out"; exit 1; }

# -----------------------------------------------------------------------------
# Empty-fleet path: no active.json at all → every PR is an orphan, no crash.
# (Reproduces the #215/#216/#217 incident where state/active.json was empty.)
# -----------------------------------------------------------------------------
EMPTY_STATE="$(mktemp -d)"
trap 'rm -rf "$EMPTY_STATE"' EXIT
empty_out="$(NO_COLOR=1 "$SCRIPT" --gh-mock "$GH_MOCK" --state-dir "$EMPTY_STATE" --repo tonychang04/hydra --json)"
echo "$empty_out" | jq -e '.summary.orphaned == 8' >/dev/null \
  || { echo "FAIL: with empty state-dir, all 8 PRs should be orphaned"; echo "$empty_out"; exit 1; }

# -----------------------------------------------------------------------------
# Linear-ticket worker (LIN-123, no branch) must NOT break ticket extraction.
# The default state fixture includes a w-lin worker with ticket "LIN-123" and no
# branch. A throwing jq capture would drop the whole ticket set and falsely
# orphan branchless workers (Codex review finding). Verify the run still
# classifies all 8 PRs and only the true orphan (#106) is flagged.
echo "$json_out" | jq -e '[.prs[] | select(.orphaned == true)] | length == 1' >/dev/null \
  || { echo "FAIL: LIN-123 worker broke ticket extraction (orphan count != 1)"; echo "$json_out"; exit 1; }

# -----------------------------------------------------------------------------
# Repo scoping: a worker for a DIFFERENT repo must not claim this repo's PR.
# active.json is global; with --repo set, only same-repo workers count for orphan
# detection (Codex review finding). Build a state where the only worker tracking
# branch hydra/commander/103 belongs to other/repo — with --repo tonychang04/hydra,
# #103 must become orphaned.
SCOPE_STATE="$(mktemp -d)"
printf '{"workers":[{"id":"w-other","ticket":"other/repo#103","repo":"other/repo","tier":"T2","started_at":"2026-05-23T10:00:00Z","subagent_type":"worker-implementation","status":"running","branch":"hydra/commander/103"}],"last_updated":"2026-05-23T10:00:00Z"}' > "$SCOPE_STATE/active.json"
scope_out="$(NO_COLOR=1 "$SCRIPT" --gh-mock "$GH_MOCK" --state-dir "$SCOPE_STATE" --repo tonychang04/hydra --json)"
rm -rf "$SCOPE_STATE"
echo "$scope_out" | jq -e '.prs[] | select(.number == 103) | .orphaned == true' >/dev/null \
  || { echo "FAIL: cross-repo worker falsely claimed PR #103 (repo scoping broken)"; echo "$scope_out"; exit 1; }

# -----------------------------------------------------------------------------
# v1.1 #221 — Bug 1: cross-repo orphan FALSE-NEGATIVE.
# -----------------------------------------------------------------------------
# Bug 1b: SAME-NAME, DIFFERENT-OWNER repo (basename collision). active.json is
# global; the v1 loose basename match ((.repo|split("/")|last) == repo_name)
# admitted a worker on otherowner/hydra to claim tonychang04/hydra's PR because
# both basenames are "hydra". A genuinely orphaned PR was thus silently missed.
# Strict matching (exact slug or local_path tail == owner/name) must reject it.
COLL_STATE="$(mktemp -d)"
printf '{"workers":[{"id":"w-coll","ticket":"otherowner/hydra#103","repo":"otherowner/hydra","tier":"T2","started_at":"2026-05-23T10:00:00Z","subagent_type":"worker-implementation","status":"running","branch":"hydra/commander/103"}],"last_updated":"2026-05-23T10:00:00Z"}' > "$COLL_STATE/active.json"
coll_out="$(NO_COLOR=1 "$SCRIPT" --gh-mock "$GH_MOCK" --state-dir "$COLL_STATE" --repo tonychang04/hydra --json)"
rm -rf "$COLL_STATE"
echo "$coll_out" | jq -e '.prs[] | select(.number == 103) | .orphaned == true' >/dev/null \
  || { echo "FAIL: same-name/diff-owner worker (otherowner/hydra) falsely claimed PR #103 via basename collision"; echo "$coll_out"; exit 1; }

# Bug 1a: --repo UNSET must NOT admit all workers globally. Build a state whose
# ONLY worker is on a DIFFERENT repo but tracks branch hydra/commander/106. The
# v1 `$repo == ""` admission kept all workers, so #106 was falsely non-orphan.
# With v1.1, an unresolvable repo (mock mode, no --repo) matches NO workers →
# every PR is an orphan (safe false-positive direction, never a false-negative).
NOREPO_STATE="$(mktemp -d)"
printf '{"workers":[{"id":"w-x","ticket":"otherowner/hydra#106","repo":"otherowner/hydra","tier":"T2","started_at":"2026-05-23T10:00:00Z","subagent_type":"worker-implementation","status":"running","branch":"hydra/commander/106"}],"last_updated":"2026-05-23T10:00:00Z"}' > "$NOREPO_STATE/active.json"
norepo_out="$(NO_COLOR=1 "$SCRIPT" --gh-mock "$GH_MOCK" --state-dir "$NOREPO_STATE" --json 2>/dev/null)"
rm -rf "$NOREPO_STATE"
echo "$norepo_out" | jq -e '.prs[] | select(.number == 106) | .orphaned == true' >/dev/null \
  || { echo "FAIL: --repo unset admitted a cross-repo worker globally (PR #106 false-negative)"; echo "$norepo_out"; exit 1; }
echo "$norepo_out" | jq -e '.summary.orphaned == 8' >/dev/null \
  || { echo "FAIL: --repo unset must not match any worker (expected all 8 orphaned)"; echo "$norepo_out"; exit 1; }

# Local_path tail still matches (no regression): a worker whose repo is a local
# checkout path ending in the exact owner/name slug must still claim its PR.
LP_STATE="$(mktemp -d)"
printf '{"workers":[{"id":"w-lp","ticket":"tonychang04/hydra#103","repo":"/Users/x/repos/tonychang04/hydra","tier":"T2","started_at":"2026-05-23T10:00:00Z","subagent_type":"worker-implementation","status":"running","branch":"hydra/commander/103"}],"last_updated":"2026-05-23T10:00:00Z"}' > "$LP_STATE/active.json"
lp_out="$(NO_COLOR=1 "$SCRIPT" --gh-mock "$GH_MOCK" --state-dir "$LP_STATE" --repo tonychang04/hydra --json)"
rm -rf "$LP_STATE"
echo "$lp_out" | jq -e '.prs[] | select(.number == 103) | .orphaned == false' >/dev/null \
  || { echo "FAIL: local_path tail (.../tonychang04/hydra) should match its PR #103"; echo "$lp_out"; exit 1; }

# -----------------------------------------------------------------------------
# v1.1 #221 — Bug 2: fallback ticket-join must use the branch→issue mapping, NOT
# the PR number (PR# ≠ issue# for real Hydra PRs). Branchless workers only.
# -----------------------------------------------------------------------------
# Bug 2 false-positive: a branchless worker tracks ISSUE #999. A PR numbered 999
# whose branch is hydra/commander/42 (i.e. it closes issue 42, NOT 999) must be
# orphaned. The v1 join compared the PR number (999) to worker tickets (999) and
# falsely "claimed" it.
B2FP_MOCK="$(mktemp -d)"
B2FP_STATE="$(mktemp -d)"
jq -n '[{number:999,title:"PR number 999 but branch closes issue 42",url:"https://x/999",headRefName:"hydra/commander/42",isDraft:true,labels:[],statusCheckRollup:[{conclusion:"SUCCESS"}],reviewDecision:""}]' > "$B2FP_MOCK/pr-list.json"
printf '{"workers":[{"id":"w-bl","ticket":"tonychang04/hydra#999","repo":"tonychang04/hydra","tier":"T2","started_at":"2026-05-23T10:00:00Z","subagent_type":"worker-implementation","status":"running"}],"last_updated":"2026-05-23T10:00:00Z"}' > "$B2FP_STATE/active.json"
b2fp_out="$(NO_COLOR=1 "$SCRIPT" --gh-mock "$B2FP_MOCK" --state-dir "$B2FP_STATE" --repo tonychang04/hydra --json)"
rm -rf "$B2FP_MOCK" "$B2FP_STATE"
echo "$b2fp_out" | jq -e '.prs[] | select(.number == 999) | .orphaned == true' >/dev/null \
  || { echo "FAIL: fallback join matched PR# 999 against worker ISSUE# 999 (Bug 2 false-positive)"; echo "$b2fp_out"; exit 1; }

# Bug 2 true-positive: a branchless worker tracks ISSUE #42. A PR numbered 777
# whose branch is hydra/commander/42 (closes issue 42) must be NON-orphan —
# matched via the branch→issue mapping. The v1 join used PR# 777 (≠ 42) and
# falsely orphaned it.
B2TP_MOCK="$(mktemp -d)"
B2TP_STATE="$(mktemp -d)"
jq -n '[{number:777,title:"PR 777 closes issue 42",url:"https://x/777",headRefName:"hydra/commander/42",isDraft:true,labels:[],statusCheckRollup:[{conclusion:"SUCCESS"}],reviewDecision:""}]' > "$B2TP_MOCK/pr-list.json"
printf '{"workers":[{"id":"w-bl","ticket":"tonychang04/hydra#42","repo":"tonychang04/hydra","tier":"T2","started_at":"2026-05-23T10:00:00Z","subagent_type":"worker-implementation","status":"running"}],"last_updated":"2026-05-23T10:00:00Z"}' > "$B2TP_STATE/active.json"
b2tp_out="$(NO_COLOR=1 "$SCRIPT" --gh-mock "$B2TP_MOCK" --state-dir "$B2TP_STATE" --repo tonychang04/hydra --json)"
rm -rf "$B2TP_MOCK" "$B2TP_STATE"
echo "$b2tp_out" | jq -e '.prs[] | select(.number == 777) | .orphaned == false' >/dev/null \
  || { echo "FAIL: branchless worker (issue 42) did not match PR #777 via branch→issue mapping (Bug 2 true-positive)"; echo "$b2tp_out"; exit 1; }

# -----------------------------------------------------------------------------
# Error paths.
# -----------------------------------------------------------------------------
# Unknown flag → exit 2.
set +e
NO_COLOR=1 "$SCRIPT" --bogus >/dev/null 2>&1; ec=$?
set -e
[[ "$ec" -eq 2 ]] || { echo "FAIL: --bogus should exit 2, got $ec"; exit 1; }

# Missing gh-mock pr-list.json → exit 1.
MISSING_MOCK="$(mktemp -d)"
set +e
NO_COLOR=1 "$SCRIPT" --gh-mock "$MISSING_MOCK" >/dev/null 2>&1; ec=$?
set -e
rm -rf "$MISSING_MOCK"
[[ "$ec" -eq 1 ]] || { echo "FAIL: missing pr-list.json mock should exit 1, got $ec"; exit 1; }

# -----------------------------------------------------------------------------
# Adversarial title: a PR title containing a literal tab + newline must NOT
# inject a phantom PR row (json) or shift columns (human). Title is flattened.
# -----------------------------------------------------------------------------
ADV_MOCK="$(mktemp -d)"
ADV_STATE="$(mktemp -d)"
printf '{"workers":[{"id":"w-adv","ticket":"tonychang04/hydra#501","repo":"tonychang04/hydra","tier":"T2","started_at":"2026-05-23T10:00:00Z","subagent_type":"worker-implementation","status":"running","branch":"hydra/commander/501"}],"last_updated":"2026-05-23T10:00:00Z"}' > "$ADV_STATE/active.json"
jq -n '[{number:501,title:"evil\ttitle\nwith newline",url:"https://x/501",headRefName:"hydra/commander/501",isDraft:true,labels:[],statusCheckRollup:[{conclusion:"SUCCESS"}],reviewDecision:""}]' > "$ADV_MOCK/pr-list.json"
adv_json="$(NO_COLOR=1 "$SCRIPT" --gh-mock "$ADV_MOCK" --state-dir "$ADV_STATE" --json)"
echo "$adv_json" | jq -e '.prs | length == 1' >/dev/null \
  || { echo "FAIL: adversarial tab/newline title injected a phantom PR row"; echo "$adv_json"; rm -rf "$ADV_MOCK" "$ADV_STATE"; exit 1; }
echo "$adv_json" | jq -e '.prs[0].title | (contains("\t") or contains("\n")) | not' >/dev/null \
  || { echo "FAIL: adversarial title not flattened in JSON output"; echo "$adv_json"; rm -rf "$ADV_MOCK" "$ADV_STATE"; exit 1; }
adv_rows="$(NO_COLOR=1 "$SCRIPT" --gh-mock "$ADV_MOCK" --state-dir "$ADV_STATE" | grep -cE '^[[:space:]]+#501' || true)"
rm -rf "$ADV_MOCK" "$ADV_STATE"
[[ "$adv_rows" -eq 1 ]] || { echo "FAIL: adversarial title produced $adv_rows '#501' rows in human report (want 1)"; exit 1; }

echo "SMOKE_OK"

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

common_args=(
  --gh-mock "$GH_MOCK"
  --state-dir "$STATE_DIR"
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
assert_state 107 "needs-fix"         "unresolved-threads"

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
echo "$json_out" | jq -e '.summary.total == 7' >/dev/null \
  || { echo "FAIL: summary.total != 7"; echo "$json_out"; exit 1; }
echo "$json_out" | jq -e '.summary.needs_fix == 2' >/dev/null \
  || { echo "FAIL: summary.needs_fix != 2 (#101 ci-red + #107 unresolved-threads)"; echo "$json_out"; exit 1; }
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
empty_out="$(NO_COLOR=1 "$SCRIPT" --gh-mock "$GH_MOCK" --state-dir "$EMPTY_STATE" --json)"
echo "$empty_out" | jq -e '.summary.orphaned == 7' >/dev/null \
  || { echo "FAIL: with empty state-dir, all 7 PRs should be orphaned"; echo "$empty_out"; exit 1; }

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

echo "SMOKE_OK"

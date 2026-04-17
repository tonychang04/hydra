#!/usr/bin/env bash
#
# enable-merge-queue.sh — one-shot operator tool to configure GitHub merge queue
# on a repo's main branch.
#
# Applies (in order):
#   1. Branch protection on main: required_linear_history, no force-pushes,
#      no required PR reviews (Commander reviews via label, not GitHub).
#   2. A merge_queue ruleset: squash-only, min-group 1, max-group 5,
#      wait-timeout 10 min (configurable).
#
# This is NOT invoked by Commander or by CI. The operator runs it once per
# repo during the rollout of ticket #154, AFTER the PR lands that adds
# `merge_queue_enabled: true` to state/repos.json.
#
# --dry-run is the DEFAULT. Actually applying requires --apply.
#
# Usage:
#   scripts/enable-merge-queue.sh <owner>/<name> [--apply]
#                                 [--max-group-size N]     (default 5)
#                                 [--wait-timeout M]       (default 10 min)
#                                 [--ruleset-name NAME]    (default "hydra-main-merge-queue")
#                                 [--branch <branch>]      (default "main")
#
# Exit codes:
#   0  dry-run completed OR --apply succeeded
#   1  gh unavailable / auth failure / repo not found
#   2  branch protection already exists (operator must reconcile manually)
#   3  no active CI workflows discoverable on the repo
#   4  usage error
#
# Spec: docs/specs/2026-04-17-merge-queue.md (ticket #154)

set -euo pipefail

usage() {
  cat <<'EOF'
Usage: enable-merge-queue.sh <owner>/<name> [options]

Arguments:
  <owner>/<name>          Repo slug, e.g. tonychang04/hydra.

Options:
  --apply                 Actually perform the PUT/POST calls. Default is dry-run.
  --max-group-size N      Max entries merged in a single queue batch (default 5).
  --wait-timeout M        min_entries_to_merge_wait_minutes (default 10).
  --ruleset-name NAME     Ruleset display name (default "hydra-main-merge-queue").
  --branch <branch>       Target branch (default "main").
  -h, --help              Show this help.

Exit codes:
  0 dry-run OK or --apply succeeded
  1 gh / auth / repo error
  2 branch protection already exists
  3 no active CI workflows found
  4 usage error
EOF
}

slug=""
apply=0
max_group_size=5
wait_timeout=10
ruleset_name="hydra-main-merge-queue"
branch="main"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --apply) apply=1; shift ;;
    --max-group-size)
      [[ $# -ge 2 ]] || { echo "enable-merge-queue: --max-group-size needs a value" >&2; exit 4; }
      max_group_size="$2"; shift 2 ;;
    --max-group-size=*) max_group_size="${1#--max-group-size=}"; shift ;;
    --wait-timeout)
      [[ $# -ge 2 ]] || { echo "enable-merge-queue: --wait-timeout needs a value" >&2; exit 4; }
      wait_timeout="$2"; shift 2 ;;
    --wait-timeout=*) wait_timeout="${1#--wait-timeout=}"; shift ;;
    --ruleset-name)
      [[ $# -ge 2 ]] || { echo "enable-merge-queue: --ruleset-name needs a value" >&2; exit 4; }
      ruleset_name="$2"; shift 2 ;;
    --ruleset-name=*) ruleset_name="${1#--ruleset-name=}"; shift ;;
    --branch)
      [[ $# -ge 2 ]] || { echo "enable-merge-queue: --branch needs a value" >&2; exit 4; }
      branch="$2"; shift 2 ;;
    --branch=*) branch="${1#--branch=}"; shift ;;
    -h|--help) usage; exit 0 ;;
    --) shift; break ;;
    -*) echo "enable-merge-queue: unknown option: $1" >&2; usage >&2; exit 4 ;;
    *)
      if [[ -z "$slug" ]]; then
        slug="$1"
      else
        echo "enable-merge-queue: too many positional args" >&2
        exit 4
      fi
      shift
      ;;
  esac
done

if [[ -z "$slug" ]]; then
  echo "enable-merge-queue: <owner>/<name> is required" >&2
  usage >&2
  exit 4
fi

if [[ "$slug" != */* ]]; then
  echo "enable-merge-queue: slug must be <owner>/<name> (got '$slug')" >&2
  exit 4
fi

# Numeric sanity on the ints (prevents shell injection into the JSON payload).
if ! [[ "$max_group_size" =~ ^[0-9]+$ ]] || (( max_group_size < 1 || max_group_size > 20 )); then
  echo "enable-merge-queue: --max-group-size must be an int in [1,20] (got '$max_group_size')" >&2
  exit 4
fi
if ! [[ "$wait_timeout" =~ ^[0-9]+$ ]] || (( wait_timeout < 1 || wait_timeout > 60 )); then
  echo "enable-merge-queue: --wait-timeout must be an int minutes in [1,60] (got '$wait_timeout')" >&2
  exit 4
fi

command -v gh >/dev/null 2>&1 || {
  echo "enable-merge-queue: gh CLI not on PATH" >&2
  exit 1
}
command -v jq >/dev/null 2>&1 || {
  echo "enable-merge-queue: jq not on PATH" >&2
  exit 1
}

# ---- safety check 1: the repo exists and gh is authenticated -----------------
if ! gh api "/repos/$slug" --silent >/dev/null 2>&1; then
  echo "enable-merge-queue: repo not accessible (gh auth? repo exists?): $slug" >&2
  exit 1
fi

# ---- safety check 2: no existing branch protection on $branch ----------------
# We refuse to overwrite an existing protection block — the operator must
# reconcile manually. Rationale: someone may have tuned protection by hand,
# and silently replacing it would be destructive.
if gh api "/repos/$slug/branches/$branch/protection" --silent >/dev/null 2>&1; then
  echo "enable-merge-queue: branch protection ALREADY exists on $slug ($branch)." >&2
  echo "  Review with: gh api /repos/$slug/branches/$branch/protection" >&2
  echo "  Then either delete it first, or configure the merge queue manually." >&2
  exit 2
fi

# ---- safety check 3: at least one CI workflow exists -------------------------
# Merge queue needs required status checks to actually gate anything. If there
# are zero active workflows, exit 3 so the operator knows to land a CI workflow
# before enabling the queue.
wf_count="$(gh api "/repos/$slug/actions/workflows" --jq '.workflows | map(select(.state=="active")) | length' 2>/dev/null || echo 0)"
if [[ -z "$wf_count" || "$wf_count" == "0" ]]; then
  echo "enable-merge-queue: no active CI workflows on $slug — merge queue would gate on nothing." >&2
  echo "  Land a workflow first, then re-run with --apply." >&2
  exit 3
fi

# ---- build the payloads ------------------------------------------------------
protection_payload="$(jq -n '{
  required_status_checks: {strict: true, contexts: []},
  enforce_admins: false,
  required_pull_request_reviews: null,
  restrictions: null,
  allow_force_pushes: false,
  allow_deletions: false,
  required_conversation_resolution: false,
  required_linear_history: true,
  lock_branch: false,
  allow_fork_syncing: false
}')"

ruleset_payload="$(jq -n \
  --arg name "$ruleset_name" \
  --arg branch_ref "refs/heads/$branch" \
  --argjson max_group "$max_group_size" \
  --argjson wait_min "$wait_timeout" \
  '{
    name: $name,
    target: "branch",
    enforcement: "active",
    conditions: {ref_name: {include: [$branch_ref], exclude: []}},
    rules: [
      {
        type: "merge_queue",
        parameters: {
          check_response_timeout_minutes: 60,
          grouping_strategy: "ALLGREEN",
          max_entries_to_build: $max_group,
          max_entries_to_merge: $max_group,
          merge_method: "SQUASH",
          min_entries_to_merge: 1,
          min_entries_to_merge_wait_minutes: $wait_min
        }
      }
    ]
  }')"

# ---- dry-run: print everything; do nothing -----------------------------------
if [[ "$apply" == "0" ]]; then
  cat <<EOF
enable-merge-queue: DRY RUN (no changes made). Pass --apply to execute.

repo:            $slug
branch:          $branch
max_group_size:  $max_group_size
wait_timeout:    $wait_timeout minutes
ruleset_name:    $ruleset_name
ci_workflows:    $wf_count active

--- step 1/2: PUT /repos/$slug/branches/$branch/protection ---
$protection_payload

--- step 2/2: POST /repos/$slug/rulesets ---
$ruleset_payload

To apply: re-run with --apply.
EOF
  exit 0
fi

# ---- apply: do it ------------------------------------------------------------
echo "enable-merge-queue: applying branch protection on $slug:$branch..." >&2
printf '%s' "$protection_payload" | gh api --method PUT "/repos/$slug/branches/$branch/protection" --input - >/dev/null
echo "  ✓ branch protection configured" >&2

echo "enable-merge-queue: creating merge_queue ruleset '$ruleset_name' on $slug..." >&2
printf '%s' "$ruleset_payload" | gh api --method POST "/repos/$slug/rulesets" --input - >/dev/null
echo "  ✓ ruleset created" >&2

cat <<EOF

enable-merge-queue: SUCCESS.

Next steps:
  1. Edit state/repos.json and set "merge_queue_enabled": true on the $slug entry.
  2. Verify: scripts/validate-state.sh state/repos.json
  3. Verify: scripts/merge-policy-lookup.sh $slug T1 --queue
     Should print: queue:<policy> if merge_queue_enabled was flipped on.
  4. Test on a throwaway PR: gh pr merge <N> --merge-queue --squash

Spec: docs/specs/2026-04-17-merge-queue.md
EOF

exit 0

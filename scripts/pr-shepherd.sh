#!/usr/bin/env bash
#
# pr-shepherd.sh — classify Commander-authored open PRs into actionable states.
#
# Read-only follow-through for the Commander loop: after a PR opens, this script
# tells Commander what to do next with it (fix CI, run the review gate, surface
# for merge) and — critically — re-attaches PRs that have been ORPHANED across a
# session boundary (open PR with no matching worker in state/active.json). It
# does NOT merge, push, comment, or change draft state. It reports + recommends.
#
# Extends the watchdog/rescue plumbing (scripts/rescue-worker.sh) and the live
# board (scripts/build-board.sh, #193) — a sibling single-purpose observability
# tool, not a daemon.
#
# Usage:
#   scripts/pr-shepherd.sh [--repo <owner>/<name>] [--author <login>] [--json]
#   scripts/pr-shepherd.sh --gh-mock <dir> [--state-dir <path>] [--json]
#
# Classification (precedence; first match wins). `orphaned` is an independent
# boolean carried on every row, not a state.
#   1. CI red    (FAILURE/ERROR/TIMED_OUT/CANCELLED)  → needs-fix   (ci-red)
#   2. CI pending (IN_PROGRESS/QUEUED/PENDING/...)     → ci-pending  (ci-pending)
#   3. CI green:
#      a. unresolved review thread                     → needs-fix   (unresolved-threads)
#      b. no `commander-reviewed` label                → needs-review-gate
#      c. `commander-reviewed` + isDraft               → ready-to-surface
#      d. `commander-reviewed` + not draft             → merge-ready
#
# Output:
#   default     compact grouped human report (one line per PR + recommended action)
#   --json      {generated_at, repo, author, prs:[...], summary:{...}}  (stable, additive-only)
#
# Test seam:
#   --gh-mock <dir>   read mocked gh responses from <dir>/pr-list.json and
#                     <dir>/threads-<n>.json instead of shelling out to gh.
#                     Also honored via env HYDRA_PR_SHEPHERD_GH_MOCK. Used by the
#                     self-test fixture so CI runs offline (mirrors rescue-worker.sh).
#
# Exit codes:
#   0   classified (any number of PRs, including zero)
#   1   I/O error (gh unavailable/unauth'd, mock file missing, malformed JSON)
#   2   usage error (unknown flag / missing value)
#
# Spec: docs/specs/2026-05-23-pr-shepherd.md (ticket #198)
# Style mirrors scripts/build-board.sh and scripts/rescue-worker.sh.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"

usage() {
  cat <<'EOF'
Usage: pr-shepherd.sh [options]

Classify Commander-authored open PRs into actionable states (read-only). Reports
what to do next with each PR and flags orphans (open PRs with no matching worker
in state/active.json). Never merges, pushes, comments, or changes draft state.

Options:
  --repo <owner>/<name>  Target repo (default: the gh-detected current repo).
  --author <login>       PR author to filter on (default: @me — the Commander).
  --state-dir <path>     Override state/ dir (default $ROOT/state) — for orphan
                         detection against active.json.
  --json                 Emit machine-readable JSON instead of the human report.
  --gh-mock <dir>        Test-only: read mocked gh responses from
                         <dir>/pr-list.json and <dir>/threads-<n>.json instead of
                         shelling out to gh. Also honored via env
                         HYDRA_PR_SHEPHERD_GH_MOCK.
  -h, --help             Show this help.

States (precedence order; orphaned is an independent boolean, not a state):
  needs-fix          CI red OR unresolved review threads → re-spawn / address
  ci-pending         CI still running → wait, re-check next tick
  needs-review-gate  CI green, no commander-reviewed label → spawn worker-review
  ready-to-surface   CI green + reviewed + still draft → surface "ready for merge"
  merge-ready        CI green + reviewed + not draft → terminal healthy (no action)

Exit codes:
  0 classified · 1 I/O error · 2 usage error

Spec: docs/specs/2026-05-23-pr-shepherd.md (ticket #198)
EOF
}

# -----------------------------------------------------------------------------
# argument parsing
# -----------------------------------------------------------------------------
repo=""
author="@me"
state_dir_override=""
json_mode=0
gh_mock="${HYDRA_PR_SHEPHERD_GH_MOCK:-}"

need_val() {
  if [[ $# -lt 2 ]]; then
    echo "pr-shepherd: option '$1' requires a value" >&2
    usage >&2
    exit 2
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)      usage; exit 0 ;;
    --repo)         need_val "$@"; repo="$2"; shift 2 ;;
    --repo=*)       repo="${1#--repo=}"; shift ;;
    --author)       need_val "$@"; author="$2"; shift 2 ;;
    --author=*)     author="${1#--author=}"; shift ;;
    --state-dir)    need_val "$@"; state_dir_override="$2"; shift 2 ;;
    --state-dir=*)  state_dir_override="${1#--state-dir=}"; shift ;;
    --gh-mock)      need_val "$@"; gh_mock="$2"; shift 2 ;;
    --gh-mock=*)    gh_mock="${1#--gh-mock=}"; shift ;;
    --json)         json_mode=1; shift ;;
    *) echo "pr-shepherd: unknown arg '$1'" >&2; usage >&2; exit 2 ;;
  esac
done

# jq is a hard dep across Hydra scripts.
if ! command -v jq >/dev/null 2>&1; then
  echo "pr-shepherd: jq not found on PATH" >&2
  exit 1
fi

STATE_DIR="${state_dir_override:-$ROOT_DIR/state}"
ACTIVE_FILE="$STATE_DIR/active.json"

# -----------------------------------------------------------------------------
# gh shims — read mocked JSON from $gh_mock when set, else shell out to gh.
# Mirrors rescue-worker.sh's --gh-mock seam so the self-test runs offline.
# -----------------------------------------------------------------------------

# Print the PR list JSON (array). Fields: number, title, headRefName, isDraft,
# labels, statusCheckRollup, reviewDecision, url.
gh_pr_list_json() {
  if [[ -n "$gh_mock" ]]; then
    local f="$gh_mock/pr-list.json"
    if [[ ! -r "$f" ]]; then
      echo "pr-shepherd: gh-mock file missing or unreadable: $f" >&2
      exit 1
    fi
    cat "$f"
    return 0
  fi
  if ! command -v gh >/dev/null 2>&1; then
    echo "pr-shepherd: gh not found on PATH; cannot list PRs" >&2
    exit 1
  fi
  local repo_args=()
  [[ -n "$repo" ]] && repo_args=(--repo "$repo")
  if ! gh pr list "${repo_args[@]}" \
        --author "$author" --state open --limit 100 \
        --json number,title,headRefName,isDraft,labels,statusCheckRollup,reviewDecision,url \
        2>/dev/null; then
    echo "pr-shepherd: gh pr list failed (auth? network? repo?)" >&2
    exit 1
  fi
}

# Print the reviewThreads JSON object ({reviewThreads:[...]}) for one PR.
gh_pr_threads_json() {
  local n="$1"
  if [[ -n "$gh_mock" ]]; then
    local f="$gh_mock/threads-${n}.json"
    # A missing threads mock means "no threads" — green PRs without review
    # activity won't have a file. Return an empty shape rather than erroring.
    if [[ ! -r "$f" ]]; then
      echo '{"reviewThreads":[]}'
      return 0
    fi
    cat "$f"
    return 0
  fi
  if ! command -v gh >/dev/null 2>&1; then
    echo "pr-shepherd: gh not found on PATH; cannot read review threads" >&2
    exit 1
  fi
  local repo_args=()
  [[ -n "$repo" ]] && repo_args=(--repo "$repo")
  if ! gh pr view "$n" "${repo_args[@]}" --json reviewThreads 2>/dev/null; then
    # A view failure for one PR shouldn't kill the whole run — treat as
    # "threads unknown / none" so the PR still classifies on CI + labels.
    echo '{"reviewThreads":[]}'
    return 0
  fi
}

# -----------------------------------------------------------------------------
# pure-jq helpers (classification logic lives here so it is identical between
# human and --json output, and unit-testable via the fixture).
# -----------------------------------------------------------------------------

# Reduce a statusCheckRollup array to one of: green | red | pending.
# - empty array (no checks configured) → green (matches `gh pr merge` behavior)
# - any FAILURE/ERROR/TIMED_OUT/CANCELLED/STARTUP_FAILURE → red
# - else any non-success in-flight (IN_PROGRESS/QUEUED/PENDING/EXPECTED/WAITING/REQUESTED) → pending
# - else green
# Handles both check-run shape (.status/.conclusion) and status-context shape (.state).
CI_JQ='
def ci_state(rollup):
  (rollup // []) as $r
  | if ($r | length) == 0 then "green"
    else
      # Normalize each entry to a single uppercase token.
      ($r | map(
        ((.conclusion // .state // .status // "") | ascii_upcase)
      )) as $tokens
      | if ($tokens | any(. as $t |
            ["FAILURE","ERROR","TIMED_OUT","CANCELLED","STARTUP_FAILURE","ACTION_REQUIRED"]
            | index($t))) then "red"
        elif ($tokens | any(. as $t |
            ["IN_PROGRESS","QUEUED","PENDING","EXPECTED","WAITING","REQUESTED"]
            | index($t))) then "pending"
        else "green"
        end
    end;
'

# -----------------------------------------------------------------------------
# load active.json worker branches + ticket numbers for orphan detection
# -----------------------------------------------------------------------------
worker_branches=""   # newline-separated branch names
worker_tickets=""    # newline-separated trailing #N ticket numbers
if [[ -f "$ACTIVE_FILE" ]]; then
  if ! worker_branches="$(jq -r '
        (.workers // []) | map(.branch // empty) | .[]
      ' "$ACTIVE_FILE" 2>/dev/null)"; then
    echo "pr-shepherd: warning: $ACTIVE_FILE present but unparseable — treating fleet as empty" >&2
    worker_branches=""
  fi
  worker_tickets="$(jq -r '
        (.workers // [])
        | map(.ticket // "")
        | map(capture("#(?<n>[0-9]+)$") | .n)
        | .[]
      ' "$ACTIVE_FILE" 2>/dev/null || true)"
fi

# is_orphan <branch> <pr_number> → echoes "true"/"false"
is_orphan() {
  local branch="$1" num="$2"
  # primary join: branch matches a worker branch
  if [[ -n "$branch" ]] && printf '%s\n' "$worker_branches" | grep -Fxq -- "$branch"; then
    echo "false"; return
  fi
  # fallback join: trailing #N ticket number matches (pre-2026-04-17 entries
  # without a branch). The PR's headRefName for Hydra PRs ends in /<ticket>.
  if [[ -n "$num" ]] && printf '%s\n' "$worker_tickets" | grep -Fxq -- "$num"; then
    echo "false"; return
  fi
  echo "true"
}

# -----------------------------------------------------------------------------
# build the per-PR classification (one TSV-ish record per PR via jq), then layer
# orphan detection (which needs active.json, easier in bash) + thread checks.
# -----------------------------------------------------------------------------
pr_list="$(gh_pr_list_json)"
if ! printf '%s' "$pr_list" | jq empty 2>/dev/null; then
  echo "pr-shepherd: malformed PR list JSON from gh" >&2
  exit 1
fi

# First pass: per-PR core fields + CI state + has-label, as compact JSON lines.
# We resolve unresolved-threads + orphan in a second pass (need per-PR calls /
# active.json lookups).
US=$'\x1f'
core_lines="$(printf '%s' "$pr_list" | jq -r "
  $CI_JQ
  (. // [])
  | .[]
  | [ (.number|tostring),
      (.title // \"\"),
      (.url // \"\"),
      (.headRefName // \"\"),
      (.isDraft // false | tostring),
      ((.labels // []) | any(.name == \"commander-reviewed\") | tostring),
      ci_state(.statusCheckRollup),
      (.reviewDecision // \"\")
    ] | join(\"\")
")"

# Accumulate per-PR result objects into a JSON array via jq -n inputs.
results_jsonl=""
while IFS="$US" read -r number title url branch is_draft has_label ci review_decision; do
  [[ -n "$number" ]] || continue

  # unresolved threads: only fetch for otherwise-green PRs (bounds gh calls).
  unresolved="false"
  if [[ "$ci" == "green" ]]; then
    threads_json="$(gh_pr_threads_json "$number")"
    cnt="$(printf '%s' "$threads_json" | jq -r '
      (.reviewThreads // []) | map(select((.isResolved // false) == false)) | length
    ' 2>/dev/null || echo 0)"
    [[ "$cnt" =~ ^[0-9]+$ ]] && [[ "$cnt" -gt 0 ]] && unresolved="true"
  fi

  # orphan?
  orphaned="$(is_orphan "$branch" "$number")"

  # classification (precedence; first match wins)
  state=""; reason=""; action=""
  if [[ "$ci" == "red" ]]; then
    state="needs-fix"; reason="ci-red"; action="respawn implementation with CI logs"
  elif [[ "$ci" == "pending" ]]; then
    state="ci-pending"; reason="ci-pending"; action="wait (CI running); re-check next tick"
  elif [[ "$unresolved" == "true" ]]; then
    state="needs-fix"; reason="unresolved-threads"; action="address review comments"
  elif [[ "$has_label" != "true" ]]; then
    state="needs-review-gate"; reason="no-commander-reviewed-label"; action="spawn worker-review"
  elif [[ "$is_draft" == "true" ]]; then
    state="ready-to-surface"; reason="reviewed-still-draft"; action="surface 'ready for merge'"
  else
    state="merge-ready"; reason="reviewed-undrafted"; action="none (terminal healthy)"
  fi

  obj="$(jq -nc \
    --argjson number "$number" \
    --arg title "$title" \
    --arg url "$url" \
    --arg branch "$branch" \
    --argjson is_draft "$is_draft" \
    --arg ci "$ci" \
    --arg review_decision "$review_decision" \
    --argjson orphaned "$orphaned" \
    --arg state "$state" \
    --arg reason "$reason" \
    --arg action "$action" \
    '{number:$number, title:$title, url:$url, branch:$branch, is_draft:$is_draft,
      ci:$ci, review_decision:$review_decision, orphaned:$orphaned,
      state:$state, reason:$reason, recommended_action:$action}')"
  results_jsonl+="$obj"$'\n'
done <<<"$core_lines"

# Assemble the final results array (empty array if no PRs).
if [[ -n "${results_jsonl//[$'\n']/}" ]]; then
  prs_array="$(printf '%s' "$results_jsonl" | jq -sc '.')"
else
  prs_array='[]'
fi

GEN_TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# summary counts
summary="$(printf '%s' "$prs_array" | jq -c '
  {
    total:             (length),
    needs_fix:         (map(select(.state == "needs-fix")) | length),
    ci_pending:        (map(select(.state == "ci-pending")) | length),
    needs_review_gate: (map(select(.state == "needs-review-gate")) | length),
    ready_to_surface:  (map(select(.state == "ready-to-surface")) | length),
    merge_ready:       (map(select(.state == "merge-ready")) | length),
    orphaned:          (map(select(.orphaned == true)) | length)
  }')"

# -----------------------------------------------------------------------------
# output
# -----------------------------------------------------------------------------
if [[ "$json_mode" -eq 1 ]]; then
  jq -nc \
    --arg generated_at "$GEN_TS" \
    --arg repo "$repo" \
    --arg author "$author" \
    --argjson prs "$prs_array" \
    --argjson summary "$summary" \
    '{generated_at:$generated_at, repo:$repo, author:$author, prs:$prs, summary:$summary}'
  exit 0
fi

# human report
total="$(printf '%s' "$summary" | jq -r '.total')"
n_orphan="$(printf '%s' "$summary" | jq -r '.orphaned')"
echo "▸ PR Shepherd — ${repo:-current repo} (author: ${author})"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
if [[ "$total" -eq 0 ]]; then
  echo "No open Commander-authored PRs."
  exit 0
fi

printf '%s' "$prs_array" | jq -r '
  .[]
  | "#\(.number)\t\(.state)\t\(if .orphaned then "[orphaned] " else "" end)\(.title)\t→ \(.recommended_action)"
' | while IFS=$'\t' read -r col_num col_state col_title col_action; do
  printf '  %-6s %-18s %s\n' "$col_num" "$col_state" "$col_title"
  printf '         %s\n' "$col_action"
done

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
printf '%s' "$summary" | jq -r '
  "total \(.total) · needs-fix \(.needs_fix) · ci-pending \(.ci_pending) · " +
  "needs-review-gate \(.needs_review_gate) · ready-to-surface \(.ready_to_surface) · " +
  "merge-ready \(.merge_ready) · orphaned \(.orphaned)"
'
[[ "$n_orphan" -gt 0 ]] && echo "⚠️  $n_orphan orphaned PR(s) — re-attach at session start."
exit 0

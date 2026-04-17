#!/usr/bin/env bash
#
# rescue-worker.sh — recover a worker worktree after a stream-idle timeout.
#
# Usage:
#   scripts/rescue-worker.sh --probe         <worktree> <branch> <ticket>
#   scripts/rescue-worker.sh --rescue        <worktree> <branch> <ticket> [--remote <name>]
#   scripts/rescue-worker.sh --probe-review  <pr_number>
#
# Three modes:
#   --probe         Non-mutating. Inspects the worktree and prints a JSON verdict
#                   on stdout. Commander uses this to decide whether to run --rescue.
#                   Verdicts:
#                     { "verdict": "rescue-commits",     "commits_ahead": N }
#                     { "verdict": "rescue-uncommitted", "commits_ahead": N, "dirty": true }
#                     { "verdict": "push-only",          "commits_ahead": N, "pushed": false }
#                     { "verdict": "nothing-to-rescue",  "commits_ahead": 0, "dirty": false }
#
#   --rescue        Mutating. Commits any uncommitted changes, fetches origin/main,
#                   rebases (fast-forward only; bails on conflict with exit 3), and
#                   pushes the branch. Prints the branch name on stdout on success.
#
#   --probe-review  Non-mutating. Checks a PR on GitHub for a landed review
#                   artifact after a worker-review stream-idle timeout. Two
#                   signals count as "review landed":
#                     (a) a review body starting with "Commander review"
#                     (b) the label commander-review-clean applied to the PR
#                   If neither is present, exits 4 to tell commander "review
#                   did not land; dispatch to commander to run /review inline".
#                   Verdicts:
#                     { "verdict": "review-already-landed", "source": "body"|"label", "pr": N }  → exit 0
#                     { "verdict": "review-missing-dispatch-to-commander", "pr": N }              → exit 4
#
# Optional flags:
#   --base <ref>    Override the base ref for counting commits-ahead and for
#                   rebase. Default is <remote>/main. Useful when testing on
#                   a worktree with no remote (e.g. self-test fixtures).
#   --gh-mock <dir> Test-only: read mocked `gh pr view` JSON responses from
#                   <dir>/reviews-<pr>.json and <dir>/labels-<pr>.json instead
#                   of shelling out to `gh`. Used by self-test fixtures so CI
#                   can exercise --probe-review offline. Also honored via env
#                   var HYDRA_RESCUE_GH_MOCK.
#
# Exit codes:
#   0   success (probe done, or rescue completed, or review already landed)
#   1   I/O error / branch mismatch / worktree not a git repo / stale git lock /
#       gh unavailable or unauth'd
#   2   usage error
#   3   rescue conflict — rebase on main hit a conflict; commander must escalate
#   4   review-type rescue required; dispatch to commander to run /review inline
#       (emitted only by --probe-review)
#
# Spec: docs/specs/2026-04-16-worker-timeout-watchdog.md (ticket #45)
# Spec: docs/specs/2026-04-17-rescue-worker-index-lock.md (ticket #81)
# Spec: docs/specs/2026-04-17-review-worker-rescue.md   (ticket #75)

set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  scripts/rescue-worker.sh --probe         <worktree> <branch> <ticket>
  scripts/rescue-worker.sh --rescue        <worktree> <branch> <ticket> [--remote <name>]
  scripts/rescue-worker.sh --probe-review  <pr_number>

Recovers a worker after a stream-idle timeout. Probe modes are non-mutating;
rescue mode commits + rebases + pushes. --probe-review checks whether a
worker-review already posted its artifact on GitHub; if not, signals commander
to run the review inline (exit 4).

Required positional args:
  --probe / --rescue:  <worktree> <branch> <ticket>
  --probe-review:      <pr_number>

<worktree>    Absolute path to the worker's git worktree.
<branch>      Expected branch name (e.g. hydra/commander/45). Script refuses
              to run if HEAD isn't on this branch.
<ticket>      GitHub issue / Linear ticket number, used in commit messages.
<pr_number>   The PR number the worker-review was inspecting.

Options:
  --probe              Inspect the worktree and print a JSON verdict. No mutations.
  --rescue             Commit + rebase onto origin/main + push. Mutating.
  --probe-review       Inspect the PR for a landed review artifact. No mutations.
  --remote <name>      Remote to fetch + push against (default: origin).
  --base <ref>         Override base ref for commits-ahead and rebase
                       (default: <remote>/main). For self-test fixtures with
                       no remote: pass the parent commit SHA or a local branch.
  --gh-mock <dir>      Test-only: read mocked `gh pr view` responses from
                       <dir>/reviews-<pr>.json and <dir>/labels-<pr>.json.
                       Also honored via HYDRA_RESCUE_GH_MOCK env var.
  -h, --help           Show this help.

Exit codes:
  0   success
  1   I/O error / branch mismatch / worktree not a git repo / gh unavailable
  2   usage error
  3   rescue conflict — commander must escalate
  4   review-type rescue required; dispatch to commander (--probe-review only)

Spec: docs/specs/2026-04-16-worker-timeout-watchdog.md (ticket #45)
Spec: docs/specs/2026-04-17-review-worker-rescue.md   (ticket #75)
EOF
}

# ---- arg parsing -----------------------------------------------------------

mode=""
worktree=""
branch=""
ticket=""
pr_number=""
remote="origin"
base_override=""
gh_mock="${HYDRA_RESCUE_GH_MOCK:-}"

# Collect unnamed positional args; assignment depends on mode (resolved after parse).
positionals=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --probe)         [[ -z "$mode" ]] || { echo "✗ --probe, --rescue, and --probe-review are mutually exclusive" >&2; exit 2; }; mode="probe";         shift ;;
    --rescue)        [[ -z "$mode" ]] || { echo "✗ --probe, --rescue, and --probe-review are mutually exclusive" >&2; exit 2; }; mode="rescue";        shift ;;
    --probe-review)  [[ -z "$mode" ]] || { echo "✗ --probe, --rescue, and --probe-review are mutually exclusive" >&2; exit 2; }; mode="probe-review";  shift ;;
    --remote)   [[ $# -ge 2 ]] || { echo "✗ --remote needs a value" >&2; exit 2; }; remote="$2"; shift 2 ;;
    --remote=*) remote="${1#--remote=}"; shift ;;
    --base)     [[ $# -ge 2 ]] || { echo "✗ --base needs a value" >&2; exit 2; }; base_override="$2"; shift 2 ;;
    --base=*)   base_override="${1#--base=}"; shift ;;
    --gh-mock)  [[ $# -ge 2 ]] || { echo "✗ --gh-mock needs a value" >&2; exit 2; }; gh_mock="$2"; shift 2 ;;
    --gh-mock=*) gh_mock="${1#--gh-mock=}"; shift ;;
    --*) echo "✗ unknown flag: $1" >&2; usage >&2; exit 2 ;;
    *)  positionals+=("$1"); shift ;;
  esac
done

if [[ -z "$mode" ]]; then
  echo "✗ must specify --probe, --rescue, or --probe-review" >&2
  usage >&2
  exit 2
fi

if [[ "$mode" == "probe-review" ]]; then
  if [[ "${#positionals[@]}" -ne 1 ]]; then
    echo "✗ --probe-review needs exactly one positional arg: <pr_number>" >&2
    usage >&2
    exit 2
  fi
  pr_number="${positionals[0]}"
  if ! [[ "$pr_number" =~ ^[0-9]+$ ]]; then
    echo "✗ <pr_number> must be a positive integer; got: $pr_number" >&2
    exit 2
  fi
else
  if [[ "${#positionals[@]}" -ne 3 ]]; then
    echo "✗ missing required positional args: <worktree> <branch> <ticket>" >&2
    usage >&2
    exit 2
  fi
  worktree="${positionals[0]}"
  branch="${positionals[1]}"
  ticket="${positionals[2]}"
  if [[ ! -d "$worktree" ]]; then
    echo "✗ worktree does not exist: $worktree" >&2
    exit 1
  fi
fi

# ---- shared git helpers ----------------------------------------------------

git_in() { git -C "$worktree" "$@"; }

# The worktree/branch checks only apply to --probe and --rescue. --probe-review
# inspects a PR on GitHub and has no worktree; skip the git guards entirely.
if [[ "$mode" != "probe-review" ]]; then
  if ! git_in rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "✗ not a git worktree: $worktree" >&2
    exit 1
  fi

  current_branch="$(git_in rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")"
  if [[ "$current_branch" != "$branch" ]]; then
    echo "✗ branch mismatch: expected '$branch', worktree is on '$current_branch'" >&2
    exit 1
  fi
fi

# Resolve the base ref for commits-ahead counting and rebase. Precedence:
#   1. --base override (if passed; used by self-test fixtures with no remote)
#   2. <remote>/<branch> tracking branch (if exists) — probe only
#   3. <remote>/main
#   4. local refs/heads/main (last-resort fallback for no-remote fixtures)
#   5. empty string → count_commits_ahead returns 0
resolve_base_ref() {
  if [[ -n "$base_override" ]]; then
    printf '%s\n' "$base_override"
    return 0
  fi
  if git_in rev-parse --verify "$remote/$branch" >/dev/null 2>&1; then
    printf '%s\n' "$remote/$branch"
    return 0
  fi
  if git_in rev-parse --verify "$remote/main" >/dev/null 2>&1; then
    printf '%s\n' "$remote/main"
    return 0
  fi
  if git_in rev-parse --verify "refs/heads/main" >/dev/null 2>&1; then
    printf '%s\n' "refs/heads/main"
    return 0
  fi
  printf ''
}

count_commits_ahead() {
  local base
  base="$(resolve_base_ref)"
  if [[ -z "$base" ]]; then
    echo 0
    return 0
  fi
  git_in rev-list --count "$base..HEAD" 2>/dev/null || echo 0
}

is_dirty() {
  # staged or unstaged changes? (untracked files count as "dirty" for rescue)
  if ! git_in diff --quiet --ignore-submodules HEAD -- 2>/dev/null; then
    return 0
  fi
  if [[ -n "$(git_in status --porcelain --untracked-files=normal 2>/dev/null)" ]]; then
    return 0
  fi
  return 1
}

remote_branch_exists() {
  git_in rev-parse --verify "$remote/$branch" >/dev/null 2>&1
}

# Ticket #81: refuse --rescue if the worker is still writing
# (`.git/index.lock` present). Best-effort TOCTOU guard — narrows but does
# not eliminate the race. Probe mode does not call this (probe is read-only).
# Spec: docs/specs/2026-04-17-rescue-worker-index-lock.md.
ensure_no_stale_lock() {
  local lock="$worktree/.git/index.lock"
  if [[ -f "$lock" ]]; then
    local pid=""
    if [[ -r "$lock" ]]; then
      pid="$(tr -d '[:space:]' < "$lock" 2>/dev/null || true)"
    fi
    [[ -z "$pid" ]] && pid="unknown"
    echo "ERROR: .git/index.lock present at $worktree — worker may still be writing; rerun when fully exited (pid $pid)" >&2
    exit 1
  fi
}

# ---- mode: probe -----------------------------------------------------------

if [[ "$mode" == "probe" ]]; then
  commits_ahead="$(count_commits_ahead)"
  dirty="false"; is_dirty && dirty="true"
  pushed="false"; remote_branch_exists && pushed="true"

  if [[ "$dirty" == "true" ]]; then
    printf '{"verdict":"rescue-uncommitted","commits_ahead":%s,"dirty":true,"pushed":%s}\n' \
      "$commits_ahead" "$pushed"
    exit 0
  fi

  if [[ "$commits_ahead" -gt 0 ]]; then
    if [[ "$pushed" == "false" ]]; then
      printf '{"verdict":"rescue-commits","commits_ahead":%s,"dirty":false,"pushed":false}\n' \
        "$commits_ahead"
    else
      # local commits exist AND remote is up to date with them? → push-only
      # (we're ahead of origin/main but not of origin/<branch>)
      local_head="$(git_in rev-parse HEAD)"
      remote_head="$(git_in rev-parse "$remote/$branch" 2>/dev/null || echo "")"
      if [[ "$local_head" == "$remote_head" ]]; then
        printf '{"verdict":"push-only","commits_ahead":%s,"dirty":false,"pushed":true}\n' \
          "$commits_ahead"
      else
        printf '{"verdict":"rescue-commits","commits_ahead":%s,"dirty":false,"pushed":true}\n' \
          "$commits_ahead"
      fi
    fi
    exit 0
  fi

  printf '{"verdict":"nothing-to-rescue","commits_ahead":0,"dirty":false,"pushed":%s}\n' "$pushed"
  exit 0
fi

# ---- mode: rescue ----------------------------------------------------------

if [[ "$mode" == "rescue" ]]; then
  # 0. Refuse if a git index.lock is already held. Best-effort guard against
  #    racing a still-writing worker (ticket #81).
  ensure_no_stale_lock

  # 1. Commit any uncommitted changes with a rescue-prefixed message.
  if is_dirty; then
    git_in add -A
    git_in commit -m "rescue: partial work from timed-out worker on #${ticket}"
  fi

  # 2. Fetch remote so <remote>/main is current. Skip if --base overrides the
  #    remote (self-test fixtures don't have a real remote to fetch from).
  if [[ -z "$base_override" ]]; then
    if ! git_in fetch "$remote" main 2>&1; then
      echo "✗ fetch $remote main failed" >&2
      exit 1
    fi
  fi

  # 3. Rebase onto the resolved base. If conflict, abort and exit 3 so commander
  #    escalates to the operator (semantic conflict, not ours to resolve).
  rebase_base="$(resolve_base_ref)"
  if [[ -z "$rebase_base" ]]; then
    echo "✗ could not resolve a base ref for rebase (tried $remote/main, refs/heads/main, --base)" >&2
    exit 1
  fi
  if ! git_in rebase "$rebase_base" 2>&1; then
    git_in rebase --abort 2>/dev/null || true
    echo "rescue-conflict: rebase onto $rebase_base hit a conflict on branch $branch" >&2
    exit 3
  fi

  # 4. Push (create remote branch if needed). Skipped if --base overrides the
  #    remote — in self-test fixtures there's no remote to push to, and the
  #    caller already knows the local branch state.
  if [[ -z "$base_override" ]]; then
    if ! git_in push --set-upstream "$remote" "$branch" 2>&1; then
      echo "✗ push to $remote/$branch failed" >&2
      exit 1
    fi
  fi

  # 5. Emit the branch name so commander can look up / create the PR.
  printf '%s\n' "$branch"
  exit 0
fi

# ---- mode: probe-review ----------------------------------------------------
#
# Inspects a PR on GitHub for evidence that a worker-review already posted its
# artifact. Two signals count as "review landed":
#   (a) a PR review body whose first line starts with "Commander review"
#   (b) the label `commander-review-clean` applied to the PR
#
# If either is present: exit 0 with verdict "review-already-landed".
# If neither is present: exit 4 with verdict "review-missing-dispatch-to-commander".
#
# Spec: docs/specs/2026-04-17-review-worker-rescue.md (ticket #75)

if [[ "$mode" == "probe-review" ]]; then
  # --- shim: gh_fetch_json <kind> → print JSON for the mocked-or-real call.
  # If $gh_mock is set, read from $gh_mock/<kind>-<pr_number>.json (test seam
  # used by self-test fixtures so CI runs offline). Otherwise shell out to `gh`.
  gh_fetch_json() {
    local kind="$1"  # "reviews" or "labels"
    if [[ -n "$gh_mock" ]]; then
      local mock_file="$gh_mock/${kind}-${pr_number}.json"
      if [[ ! -r "$mock_file" ]]; then
        echo "✗ gh-mock file missing or unreadable: $mock_file" >&2
        exit 1
      fi
      cat "$mock_file"
      return 0
    fi
    if ! command -v gh >/dev/null 2>&1; then
      echo "✗ gh not found on PATH; cannot inspect PR #${pr_number}" >&2
      exit 1
    fi
    if ! gh pr view "$pr_number" --json "$kind" 2>/dev/null; then
      echo "✗ gh pr view #${pr_number} --json ${kind} failed (auth? network? PR exists?)" >&2
      exit 1
    fi
  }

  # Require jq for JSON parsing — it's already a hard dep elsewhere in Hydra
  # (scripts/parse-citations.sh, scripts/validate-state-all.sh).
  if ! command -v jq >/dev/null 2>&1; then
    echo "✗ jq not found on PATH; --probe-review needs jq" >&2
    exit 1
  fi

  # 1. Does any review body start with "Commander review"?
  reviews_json="$(gh_fetch_json reviews)"
  body_match="$(printf '%s' "$reviews_json" | jq -r '
    (.reviews // [])
    | map(select((.body // "") | startswith("Commander review")))
    | length
  ')"
  if [[ "$body_match" =~ ^[0-9]+$ ]] && [[ "$body_match" -gt 0 ]]; then
    printf '{"verdict":"review-already-landed","source":"body","pr":%s}\n' "$pr_number"
    exit 0
  fi

  # 2. Is the commander-review-clean label applied?
  labels_json="$(gh_fetch_json labels)"
  label_match="$(printf '%s' "$labels_json" | jq -r '
    (.labels // [])
    | map(select(.name == "commander-review-clean"))
    | length
  ')"
  if [[ "$label_match" =~ ^[0-9]+$ ]] && [[ "$label_match" -gt 0 ]]; then
    printf '{"verdict":"review-already-landed","source":"label","pr":%s}\n' "$pr_number"
    exit 0
  fi

  # 3. Neither signal — commander must run /review inline.
  printf '{"verdict":"review-missing-dispatch-to-commander","pr":%s}\n' "$pr_number"
  exit 4
fi

# Defensive catch-all: should be unreachable because mode must be one of
# probe / rescue / probe-review (all branches above exit). If we fall through,
# something in arg parsing is wrong.
echo "✗ internal error: unhandled mode '$mode'" >&2
exit 1

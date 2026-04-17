#!/usr/bin/env bash
#
# rescue-worker.sh — recover a worker worktree after a stream-idle timeout.
#
# Usage:
#   scripts/rescue-worker.sh --probe  <worktree> <branch> <ticket>
#   scripts/rescue-worker.sh --rescue <worktree> <branch> <ticket> [--remote <name>]
#
# Two modes:
#   --probe   Non-mutating. Inspects the worktree and prints a JSON verdict
#             on stdout. Commander uses this to decide whether to run --rescue.
#             Verdicts:
#               { "verdict": "rescue-commits",     "commits_ahead": N }
#               { "verdict": "rescue-uncommitted", "commits_ahead": N, "dirty": true }
#               { "verdict": "push-only",          "commits_ahead": N, "pushed": false }
#               { "verdict": "nothing-to-rescue",  "commits_ahead": 0, "dirty": false }
#
#   --rescue  Mutating. Commits any uncommitted changes, fetches origin/main,
#             rebases (fast-forward only; bails on conflict with exit 3), and
#             pushes the branch. Prints the branch name on stdout on success.
#
# Optional flags:
#   --base <ref>    Override the base ref for counting commits-ahead and for
#                   rebase. Default is <remote>/main. Useful when testing on
#                   a worktree with no remote (e.g. self-test fixtures).
#
# Exit codes:
#   0   success (probe done, or rescue completed)
#   1   I/O error / branch mismatch / worktree not a git repo
#   2   usage error
#   3   rescue conflict — rebase on main hit a conflict; commander must escalate
#
# Spec: docs/specs/2026-04-16-worker-timeout-watchdog.md (ticket #45)

set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  scripts/rescue-worker.sh --probe  <worktree> <branch> <ticket>
  scripts/rescue-worker.sh --rescue <worktree> <branch> <ticket> [--remote <name>]

Recovers a worker worktree after a stream-idle timeout. Probe mode is
non-mutating; rescue mode commits + rebases + pushes.

Required positional args (in order):
  <worktree>   Absolute path to the worker's git worktree.
  <branch>     Expected branch name (e.g. hydra/commander/45). Script refuses
               to run if HEAD isn't on this branch.
  <ticket>     GitHub issue / Linear ticket number, used in commit messages.

Options:
  --probe              Inspect the worktree and print a JSON verdict. No mutations.
  --rescue             Commit + rebase onto origin/main + push. Mutating.
  --remote <name>      Remote to fetch + push against (default: origin).
  --base <ref>         Override base ref for commits-ahead and rebase
                       (default: <remote>/main). For self-test fixtures with
                       no remote: pass the parent commit SHA or a local branch.
  -h, --help           Show this help.

Exit codes:
  0   success
  1   I/O error / branch mismatch / worktree not a git repo
  2   usage error
  3   rescue conflict — commander must escalate

Spec: docs/specs/2026-04-16-worker-timeout-watchdog.md (ticket #45)
EOF
}

# ---- arg parsing -----------------------------------------------------------

mode=""
worktree=""
branch=""
ticket=""
remote="origin"
base_override=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --probe)   [[ -z "$mode" ]] || { echo "✗ --probe and --rescue are mutually exclusive" >&2; exit 2; }; mode="probe";  shift ;;
    --rescue)  [[ -z "$mode" ]] || { echo "✗ --probe and --rescue are mutually exclusive" >&2; exit 2; }; mode="rescue"; shift ;;
    --remote)  [[ $# -ge 2 ]] || { echo "✗ --remote needs a value" >&2; exit 2; }; remote="$2"; shift 2 ;;
    --remote=*) remote="${1#--remote=}"; shift ;;
    --base)    [[ $# -ge 2 ]] || { echo "✗ --base needs a value" >&2; exit 2; }; base_override="$2"; shift 2 ;;
    --base=*)  base_override="${1#--base=}"; shift ;;
    --*) echo "✗ unknown flag: $1" >&2; usage >&2; exit 2 ;;
    *)
      if   [[ -z "$worktree" ]]; then worktree="$1"
      elif [[ -z "$branch"   ]]; then branch="$1"
      elif [[ -z "$ticket"   ]]; then ticket="$1"
      else echo "✗ unexpected positional arg: $1" >&2; usage >&2; exit 2
      fi
      shift ;;
  esac
done

if [[ -z "$mode" ]]; then
  echo "✗ must specify --probe or --rescue" >&2
  usage >&2
  exit 2
fi

if [[ -z "$worktree" || -z "$branch" || -z "$ticket" ]]; then
  echo "✗ missing required positional args: <worktree> <branch> <ticket>" >&2
  usage >&2
  exit 2
fi

if [[ ! -d "$worktree" ]]; then
  echo "✗ worktree does not exist: $worktree" >&2
  exit 1
fi

# ---- shared git helpers ----------------------------------------------------

git_in() { git -C "$worktree" "$@"; }

if ! git_in rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "✗ not a git worktree: $worktree" >&2
  exit 1
fi

current_branch="$(git_in rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")"
if [[ "$current_branch" != "$branch" ]]; then
  echo "✗ branch mismatch: expected '$branch', worktree is on '$current_branch'" >&2
  exit 1
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

#!/usr/bin/env bash
#
# assert-worktree-branch.sh — guard a worker against committing to the wrong branch.
#
# Usage:
#   scripts/assert-worktree-branch.sh <worktree> <expected-branch>
#
# Why this exists:
#   The Bash tool's cwd RESETS to the main repo dir between calls, and shell
#   variables do NOT persist between separate Bash calls. A worker that runs
#   `cd "$WT" && git commit` across separate Bash invocations actually commits in
#   the MAIN repo, on whatever branch it currently has checked out — often another
#   in-flight worker's branch. That corrupted two workers on 2026-05-20 (ticket
#   #185). Run this BEFORE every commit so a misplaced cwd fails loudly instead of
#   silently landing your work on a sibling worker's branch.
#
# Behavior:
#   - Resolves <worktree>'s current branch via
#       git -C "<worktree>" rev-parse --abbrev-ref HEAD
#   - Prints "OK: <worktree> on <branch>" and exits 0 when current == expected.
#   - Exits 1 with a loud stderr message when current != expected, when
#     <worktree> is not a git work tree, or when <worktree> does not exist.
#   - Exits 2 (usage) on wrong arg count.
#
# Exit codes:
#   0   on the expected branch — safe to commit
#   1   branch mismatch / not a git worktree / worktree missing
#   2   usage error
#
# Precedent: scripts/rescue-worker.sh already takes an explicit <worktree> and
# routes all git through `git -C` (see git_in() and its branch-mismatch guard).
#
# Spec: docs/specs/2026-05-20-worker-git-C-worktree.md (ticket #185)

set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  scripts/assert-worktree-branch.sh <worktree> <expected-branch>

Asserts that <worktree> currently has <expected-branch> checked out, so a worker
can refuse to commit when its Bash cwd has reset to the main repo (which may be
parked on another worker's branch).

Positional args:
  <worktree>          Absolute path to the worker's git worktree.
  <expected-branch>   The branch the worker must be on (e.g. hydra/commander/185).

Exit codes:
  0   on the expected branch — safe to commit
  1   branch mismatch / not a git worktree / worktree missing
  2   usage error

Spec: docs/specs/2026-05-20-worker-git-C-worktree.md (ticket #185)
EOF
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac

if [[ "$#" -ne 2 ]]; then
  echo "✗ expected exactly 2 args: <worktree> <expected-branch>" >&2
  usage >&2
  exit 2
fi

worktree="$1"
expected="$2"

if [[ ! -d "$worktree" ]]; then
  echo "✗ worktree does not exist: $worktree" >&2
  exit 1
fi

if ! git -C "$worktree" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "✗ not a git worktree: $worktree" >&2
  exit 1
fi

current="$(git -C "$worktree" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")"

if [[ "$current" != "$expected" ]]; then
  echo "✗ branch mismatch: expected '$expected', worktree is on '$current'" >&2
  echo "  Do NOT commit. Your Bash cwd may have reset to the main repo." >&2
  echo "  Target your own worktree explicitly: git -C \"$worktree\" <cmd>" >&2
  exit 1
fi

echo "OK: $worktree on $current"
exit 0

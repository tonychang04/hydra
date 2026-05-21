#!/usr/bin/env bash
#
# self-test fixture for the worker git -C <worktree> discipline (ticket #185).
#
# Reproduces the 2026-05-20 cwd-reset cross-branch contamination incident with
# throwaway git repos, then proves the fix:
#
#   RED   — a bare `git commit` run from the MAIN repo's dir (simulating a worker
#           whose Bash cwd reset to main) lands the commit on a SIBLING worker's
#           branch, NOT the worker's own branch. This is the bug.
#   RED   — scripts/assert-worktree-branch.sh, pointed at the main repo (parked on
#           the sibling branch), exits 1 with a "branch mismatch" message: the
#           guard would have stopped the bad commit.
#   GREEN — the assertion passes for the real worktree, and `git -C "<worktree>"
#           commit` lands on the worker's own branch while the main repo (and the
#           sibling's HEAD) stay untouched.
#
# Plus helper unit asserts: usage error (exit 2), nonexistent path (exit 1),
# --help (exit 0), bash -n cleanliness.
#
# No network, no `gh`, no Claude auth. Runs anywhere bash + git is installed.
#
# Run from anywhere:
#   bash self-test/fixtures/worker-git-worktree/run.sh
#
# Exit 0 on PASS, non-zero on FAIL with a clear message on stderr.
#
# Invoked by self-test/golden-cases.example.json case "worker-git-worktree-discipline".
# Spec: docs/specs/2026-05-20-worker-git-C-worktree.md

set -euo pipefail
export NO_COLOR=1

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd -- "$SCRIPT_DIR/../../.." && pwd)"
ASSERT="$ROOT_DIR/scripts/assert-worktree-branch.sh"

[[ -x "$ASSERT" ]] || { echo "FAIL: $ASSERT not executable" >&2; exit 1; }

SIBLING_BRANCH="hydra/commander/159"   # another in-flight worker's branch
WORKER_BRANCH="hydra/commander/185"    # this worker's branch

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

mainrepo="$tmp/main"
worktree="$tmp/worktree"

# --- build the MAIN repo, parked on a SIBLING worker's branch -----------------
mkdir -p "$mainrepo"
(
  cd "$mainrepo"
  git init -q
  git config user.email fixture@example.com
  git config user.name "git-worktree fixture"
  git symbolic-ref HEAD refs/heads/main
  echo "baseline" > base.txt
  git add base.txt
  git commit -q -m "init"
  # A sibling worker left the main repo checked out on THEIR branch, with their
  # own commit (the parallel-worker hazard).
  git checkout -q -b "$SIBLING_BRANCH"
  echo "sibling work" > sibling.txt
  git add sibling.txt
  git commit -q -m "sibling worker commit"
)
sibling_head_before="$(git -C "$mainrepo" rev-parse HEAD)"

# --- build the WORKER's own worktree, on the worker's branch ------------------
mkdir -p "$worktree"
(
  cd "$worktree"
  git init -q
  git config user.email fixture@example.com
  git config user.name "git-worktree fixture"
  git symbolic-ref HEAD refs/heads/main
  echo "baseline" > base.txt
  git add base.txt
  git commit -q -m "init"
  git checkout -q -b "$WORKER_BRANCH"
)
worker_head_before="$(git -C "$worktree" rev-parse HEAD)"

# =============================================================================
# RED 1: a bare commit from the MAIN repo dir lands on the SIBLING's branch.
# This is exactly what a worker does when its Bash cwd reset to main and it ran
# `cd "$WT" && git commit` (the cd is gone; the commit hits main's HEAD branch).
# =============================================================================
(
  cd "$mainrepo"
  echo "worker 185 output, MISPLACED" > misplaced.txt
  git add misplaced.txt
  git commit -q -m "worker 185 spec (WRONG: cwd reset to main)"
)
main_branch_after_bad="$(git -C "$mainrepo" rev-parse --abbrev-ref HEAD)"
if [[ "$main_branch_after_bad" != "$SIBLING_BRANCH" ]]; then
  echo "FAIL: RED1 setup wrong — main repo not on sibling branch (got '$main_branch_after_bad')" >&2
  exit 1
fi
# The misplaced commit must now be on the SIBLING's branch, on top of the
# sibling's work — demonstrating the contamination.
if ! git -C "$mainrepo" log --oneline -1 | grep -q 'WRONG: cwd reset to main'; then
  echo "FAIL: RED1 — expected misplaced commit on top of sibling branch; not found" >&2
  echo "  log: $(git -C "$mainrepo" log --oneline -3)" >&2
  exit 1
fi
echo "  RED1 pass: bare commit from main dir DID contaminate sibling branch $SIBLING_BRANCH"

# Clean the contamination out so the rest of the fixture starts from the
# incident's pre-bad-commit state (soft reset is the documented recovery).
( cd "$mainrepo" && git reset --soft HEAD~1 >/dev/null 2>&1 && git restore --staged misplaced.txt >/dev/null 2>&1 && rm -f misplaced.txt )
if [[ "$(git -C "$mainrepo" rev-parse HEAD)" != "$sibling_head_before" ]]; then
  echo "FAIL: cleanup did not restore sibling HEAD" >&2
  exit 1
fi

# =============================================================================
# RED 2: the guard pointed at the MAIN repo (on the sibling branch) refuses.
# A worker that ran the assertion against the wrong dir would have been stopped.
# =============================================================================
set +e
guard_out="$("$ASSERT" "$mainrepo" "$WORKER_BRANCH" 2>&1)"
guard_ec=$?
set -e
if [[ "$guard_ec" -ne 1 ]]; then
  echo "FAIL: RED2 — guard on main repo (sibling branch) expected exit 1, got $guard_ec" >&2
  echo "  out: $guard_out" >&2
  exit 1
fi
if ! printf '%s' "$guard_out" | grep -q 'branch mismatch'; then
  echo "FAIL: RED2 — expected 'branch mismatch' message; got: $guard_out" >&2
  exit 1
fi
echo "  RED2 pass: guard caught the mismatch (main on $SIBLING_BRANCH, expected $WORKER_BRANCH)"

# =============================================================================
# GREEN: discipline fixes it. Assertion passes for the real worktree; a
# `git -C "<worktree>"` commit lands on the worker's branch; main is untouched.
# =============================================================================
guard_ok="$("$ASSERT" "$worktree" "$WORKER_BRANCH")"
if ! printf '%s' "$guard_ok" | grep -q "on $WORKER_BRANCH"; then
  echo "FAIL: GREEN — guard on worktree expected OK on $WORKER_BRANCH; got: $guard_ok" >&2
  exit 1
fi

# The disciplined commit: explicit -C, never a bare git / cd.
echo "worker 185 output, correct" > "$worktree/correct.txt"
git -C "$worktree" add correct.txt
git -C "$worktree" commit -q -m "worker 185 spec (correct: git -C worktree)"

# Commit landed on the WORKER's branch inside the worktree.
worker_branch_now="$(git -C "$worktree" rev-parse --abbrev-ref HEAD)"
if [[ "$worker_branch_now" != "$WORKER_BRANCH" ]]; then
  echo "FAIL: GREEN — worktree not on $WORKER_BRANCH after commit (got '$worker_branch_now')" >&2
  exit 1
fi
if ! git -C "$worktree" log --oneline -1 | grep -q 'correct: git -C worktree'; then
  echo "FAIL: GREEN — disciplined commit not found on worker branch" >&2
  exit 1
fi
if [[ "$(git -C "$worktree" rev-parse HEAD)" == "$worker_head_before" ]]; then
  echo "FAIL: GREEN — worktree HEAD did not advance (commit didn't land)" >&2
  exit 1
fi

# The MAIN repo and the sibling's HEAD are completely untouched by the disciplined path.
if [[ "$(git -C "$mainrepo" rev-parse --abbrev-ref HEAD)" != "$SIBLING_BRANCH" ]]; then
  echo "FAIL: GREEN — main repo branch changed unexpectedly" >&2
  exit 1
fi
if [[ "$(git -C "$mainrepo" rev-parse HEAD)" != "$sibling_head_before" ]]; then
  echo "FAIL: GREEN — sibling HEAD changed; disciplined commit leaked into main repo" >&2
  exit 1
fi
echo "  GREEN pass: git -C committed to $WORKER_BRANCH; main repo + sibling HEAD untouched"

# =============================================================================
# Helper unit asserts.
# =============================================================================
# bash -n clean
bash -n "$ASSERT" || { echo "FAIL: bash -n on assert helper failed" >&2; exit 1; }

# usage error: wrong arg count → exit 2
set +e; "$ASSERT" only-one-arg >/dev/null 2>&1; ec=$?; set -e
if [[ "$ec" -ne 2 ]]; then
  echo "FAIL: helper with 1 arg should exit 2, got $ec" >&2
  exit 1
fi

# nonexistent worktree → exit 1
set +e; "$ASSERT" "/nonexistent/path/for/fixture-$$" "$WORKER_BRANCH" >/dev/null 2>&1; ec=$?; set -e
if [[ "$ec" -ne 1 ]]; then
  echo "FAIL: helper on nonexistent path should exit 1, got $ec" >&2
  exit 1
fi

# not-a-git-worktree → exit 1
plaindir="$tmp/plain"; mkdir -p "$plaindir"
set +e; "$ASSERT" "$plaindir" "$WORKER_BRANCH" >/dev/null 2>&1; ec=$?; set -e
if [[ "$ec" -ne 1 ]]; then
  echo "FAIL: helper on non-git dir should exit 1, got $ec" >&2
  exit 1
fi

# --help → exit 0, prints Usage:
if ! "$ASSERT" --help 2>&1 | grep -q 'Usage:'; then
  echo "FAIL: --help missing 'Usage:'" >&2
  exit 1
fi
echo "  helper unit asserts pass (usage/nonexistent/non-git/help)"

echo "PASS: worker git -C <worktree> discipline fixture (red→green)"

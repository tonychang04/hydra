#!/usr/bin/env bash
#
# ensure-repo-cloned.sh — idempotently ensure a repo exists at its cloud-local
# clone path. First invocation clones; subsequent invocations fetch + reset the
# default branch to a clean known-good state.
#
# Cloud commander (hydra-commander-*.fly.dev) runs this before spawning a
# worker-implementation against a repo, so the worker's `git worktree add`
# finds an existing checkout on the Fly volume. Local commanders skip this
# path entirely and keep using the operator's existing `local_path`.
#
# Spec: docs/specs/2026-04-17-cloud-repo-clone.md
#
# Contract:
#   - Input: <owner>/<repo> on argv.
#   - Reads state/repos.json to find the matching entry and the configured
#     `cloud_local_path` / `git_url` (both optional; defaults applied).
#   - Idempotent: first run clones, second run re-fetches — no repeated clone.
#   - Safe: refuses to `git reset --hard` if there are active worktrees under
#     the target (a worker is mid-ticket) — logs + exits 0 so the commander
#     keeps moving.
#   - Shallow: uses --depth 50 so big histories stay cheap.
#
# Auth:
#   - Uses $GITHUB_TOKEN for private-repo auth via https://x-access-token:...@...
#   - Public repos work without a token (standard unauthenticated HTTPS).
#
# Exit codes:
#   0   success (clone, re-fetch, or safe no-op due to active worktree).
#   1   bad arguments or config (missing owner/repo, repo not in state/repos.json,
#       missing GITHUB_TOKEN for a private repo, missing `git` binary, etc).
#   2   git operation failed (network, auth rejected, corrupted repo).

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"

# -----------------------------------------------------------------------------
# config — overridable for self-tests
# -----------------------------------------------------------------------------
REPOS_JSON="${HYDRA_REPOS_JSON:-$ROOT_DIR/state/repos.json}"
CLONE_DEPTH="${HYDRA_CLONE_DEPTH:-50}"
DEFAULT_CLOUD_BASE="${HYDRA_CLOUD_REPOS_BASE:-/hydra/data/repos}"

usage() {
  cat <<'EOF'
Usage: scripts/ensure-repo-cloned.sh <owner>/<repo>

Ensure the named repo is cloned to its cloud-local path and on the default
branch. Safe to re-run — idempotent.

Arguments:
  <owner>/<repo>   GitHub slug, e.g. "tonychang04/hydra".

Environment:
  GITHUB_TOKEN            HTTPS auth token. Required for private repos;
                          optional for public ones.
  HYDRA_REPOS_JSON        Override path to state/repos.json. Default:
                          <repo-root>/state/repos.json
  HYDRA_CLONE_DEPTH       Shallow clone depth. Default: 50
  HYDRA_CLOUD_REPOS_BASE  Fallback clone root when the repo entry has no
                          `cloud_local_path`. Default: /hydra/data/repos

Exit codes:
  0   success, or safe skip (active worker worktree present)
  1   bad arguments / missing config
  2   git operation failed
EOF
}

log()  { printf '[ensure-repo-cloned %s] %s\n' "$(date -u +%FT%TZ)" "$*"; }
fail() { printf '[ensure-repo-cloned %s] ERROR: %s\n' "$(date -u +%FT%TZ)" "$*" >&2; exit "${2:-1}"; }

# -----------------------------------------------------------------------------
# argv
# -----------------------------------------------------------------------------
if [[ $# -lt 1 ]] || [[ "${1:-}" == "-h" ]] || [[ "${1:-}" == "--help" ]]; then
  usage
  exit "$([[ $# -lt 1 ]] && echo 1 || echo 0)"
fi

slug="$1"
if [[ "$slug" != */* ]]; then
  fail "argument must be <owner>/<repo>, got: $slug" 1
fi
owner="${slug%%/*}"
name="${slug#*/}"
if [[ -z "$owner" ]] || [[ -z "$name" ]] || [[ "$name" == */* ]]; then
  fail "invalid slug '$slug' — expected exactly one '/'" 1
fi

# -----------------------------------------------------------------------------
# prerequisites
# -----------------------------------------------------------------------------
command -v git >/dev/null 2>&1 || fail "git not found on PATH" 1
command -v jq  >/dev/null 2>&1 || fail "jq not found on PATH" 1

if [[ ! -f "$REPOS_JSON" ]]; then
  fail "repos config not found: $REPOS_JSON (set HYDRA_REPOS_JSON to override)" 1
fi
if ! jq empty "$REPOS_JSON" 2>/dev/null; then
  fail "repos config is not valid JSON: $REPOS_JSON" 1
fi

# -----------------------------------------------------------------------------
# find the repo entry; compute cloud_local_path + git_url with defaults
# -----------------------------------------------------------------------------
entry_json="$(
  jq -c --arg owner "$owner" --arg name "$name" '
    .repos // []
    | map(select(.owner == $owner and .name == $name))
    | .[0] // null
  ' "$REPOS_JSON"
)"

if [[ "$entry_json" == "null" ]]; then
  fail "no repo entry for '$owner/$name' in $REPOS_JSON" 1
fi

# cloud_local_path: explicit entry wins; else default under HYDRA_CLOUD_REPOS_BASE.
target_path="$(jq -r --arg d "$DEFAULT_CLOUD_BASE/$owner/$name" '.cloud_local_path // $d' <<<"$entry_json")"
# git_url: explicit entry wins; else default to public GitHub HTTPS.
git_url="$(jq -r --arg d "https://github.com/$owner/$name.git" '.git_url // $d' <<<"$entry_json")"

# Inject auth for github.com URLs when GITHUB_TOKEN is set. Public clones
# without a token still work; private clones without a token fail with a clear
# message from git itself (propagated via exit 2 below).
auth_url="$git_url"
if [[ -n "${GITHUB_TOKEN:-}" ]] && [[ "$git_url" =~ ^https://github\.com/ ]]; then
  auth_url="https://x-access-token:${GITHUB_TOKEN}@${git_url#https://}"
fi

log "target_path=$target_path"
log "git_url=$git_url"

# -----------------------------------------------------------------------------
# clone vs re-fetch decision
# -----------------------------------------------------------------------------
run_git() {
  # Thin wrapper so we can translate git's non-zero exits into our exit code 2.
  if ! git "$@"; then
    fail "git $*: failed" 2
  fi
}

if [[ ! -d "$target_path/.git" ]]; then
  # ---- first clone ----
  mkdir -p "$(dirname "$target_path")"
  log "cloning $owner/$name (depth=$CLONE_DEPTH)"
  if ! git clone --depth "$CLONE_DEPTH" "$auth_url" "$target_path"; then
    fail "git clone failed for $owner/$name" 2
  fi
  # SECURITY: strip token from .git/config by setting origin to the clean URL.
  # Without this, GITHUB_TOKEN is persisted on disk and shows up in `git remote -v`.
  git -C "$target_path" remote set-url origin "$git_url" >/dev/null 2>&1 || true
  # Record the resolved default branch for observability.
  default_ref="$(git -C "$target_path" symbolic-ref --quiet --short HEAD || echo unknown)"
  log "cloned at $target_path (HEAD=$default_ref, sha=$(git -C "$target_path" rev-parse --short HEAD))"
  exit 0
fi

# ---- re-fetch + reset path ----
# Safety: refuse to reset if there are linked worktrees (a worker may be mid-ticket).
# `git worktree list` always includes the main worktree, so >1 line = linked worktrees exist.
worktree_count=0
if worktree_count="$(git -C "$target_path" worktree list 2>/dev/null | wc -l | tr -d ' ')"; then
  :
fi
if [[ "$worktree_count" -gt 1 ]]; then
  log "active worktrees present at $target_path (count=$worktree_count) — skipping reset"
  log "safe no-op; worker owns its tree"
  exit 0
fi

log "re-fetching $owner/$name"
# Keep auth fresh on fetch in case the entry's git_url has no embedded token
# but GITHUB_TOKEN is available.
if [[ -n "${GITHUB_TOKEN:-}" ]] && [[ "$git_url" =~ ^https://github\.com/ ]]; then
  # SECURITY: always restore to the clean URL ($git_url), not whatever was
  # previously configured — a prior buggy clone may have left the token baked
  # in, and "restoring" to that value would perpetuate the leak. $git_url is
  # the operator-provided canonical remote, with no embedded credentials.
  git -C "$target_path" remote set-url origin "$auth_url" >/dev/null 2>&1 || true
  set +e
  git -C "$target_path" fetch --depth "$CLONE_DEPTH" origin
  fetch_ec=$?
  set -e
  git -C "$target_path" remote set-url origin "$git_url" >/dev/null 2>&1 || true
  [[ "$fetch_ec" -eq 0 ]] || fail "git fetch failed for $owner/$name" 2
else
  run_git -C "$target_path" fetch --depth "$CLONE_DEPTH" origin
fi

# Determine default branch via origin/HEAD. If it's not set (shallow clones
# sometimes miss it), derive once via `git remote set-head`.
if ! default_ref="$(git -C "$target_path" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null)"; then
  log "origin/HEAD not set; probing with 'git remote set-head origin --auto'"
  run_git -C "$target_path" remote set-head origin --auto
  default_ref="$(git -C "$target_path" symbolic-ref --short refs/remotes/origin/HEAD)"
fi
# default_ref is "origin/<branch>"; extract the branch name.
default_branch="${default_ref#origin/}"

log "resetting to origin/$default_branch"
run_git -C "$target_path" reset --hard "origin/$default_branch"

log "up-to-date at $target_path (HEAD=$default_branch, sha=$(git -C "$target_path" rev-parse --short HEAD))"
exit 0

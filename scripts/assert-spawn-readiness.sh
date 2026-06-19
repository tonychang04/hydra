#!/usr/bin/env bash
#
# assert-spawn-readiness.sh — pre-spawn readiness gate (ticket #308).
#
# Given a CHECKOUT, report whether the base a worktree would be cut from is
# current (not behind origin/<default>) and clean (no dirty TRACKED changes).
# This is the missing half of anti-drift: scripts/plan-parallel-batch.sh (#257)
# prevents *file-overlap* collisions between concurrent tickets; this prevents
# *stale-base* collisions before a worktree is cut. Memory cites the stale/dirty
# base class 16+ times (#177/#185/#203/#231/#262/#267/#285).
#
# REPORT-ONLY discipline (same as scripts/plan-parallel-batch.sh and
# scripts/autopickup-tick.sh): this helper RECOMMENDS a remediation
# (`git merge --ff-only origin/<base>`). It does NOT run `git merge`, does NOT
# spawn, does NOT mutate any state. Commander reads the verdict and actuates.
# Keeping ff-only actuation with Commander keeps the irreversible decision in
# one place and makes this helper trivially testable offline (--no-fetch).
#
# Usage:
#   scripts/assert-spawn-readiness.sh [--repo-dir <path>] [--base <branch>]
#       [--no-fetch] [--json] [-h|--help]
#
# Output:
#   default   one-line human verdict (READY / NOT READY: <reason>) + remediation
#   --json    one stable object: {generated_at, ready, behind, ahead, dirty,
#             default_branch, untracked, remediation, reason}
#
# Exit codes:
#   0 = ready (base current + clean)
#   1 = not ready (behind origin and/or dirty tracked changes)
#   2 = usage / parse error (bad flag, not a git repo, missing jq) OR fetch
#       failure (fail-closed: do not spawn against an un-verifiable base)
#
# Spec: docs/specs/2026-06-18-pre-spawn-readiness-gate.md
# Style mirrors scripts/plan-parallel-batch.sh.

set -euo pipefail

# -----------------------------------------------------------------------------
# color / TTY
# -----------------------------------------------------------------------------
if [[ -t 1 ]] && [[ "${NO_COLOR:-}" != "1" ]]; then
  C_GREEN=$'\033[32m'
  C_YELLOW=$'\033[33m'
  C_DIM=$'\033[2m'
  C_RESET=$'\033[0m'
else
  C_GREEN=""
  C_YELLOW=""
  C_DIM=""
  C_RESET=""
fi

usage() {
  cat <<'EOF'
Usage: assert-spawn-readiness.sh [--repo-dir <path>] [--base <branch>]
                                 [--no-fetch] [--json]

Pre-spawn readiness gate (#308): report whether a checkout's base branch is
current (not behind origin/<default>) and clean (no dirty tracked changes)
before a worktree is cut from it. REPORT-ONLY — recommends a remediation,
never runs `git merge`, never spawns. Complements plan-parallel-batch.sh
(file-overlap) by preventing stale-base collisions.

Options:
  --repo-dir <path>  the checkout to inspect (default: cwd's git toplevel)
  --base <branch>    base branch to check (default: origin/HEAD target, else main)
  --no-fetch         skip `git fetch origin <base>` (offline; for tests / when
                     the caller already fetched)
  --json             emit machine-readable JSON instead of the human verdict
  -h, --help         show this help

Output (--json):
  {generated_at, ready, behind, ahead, dirty, default_branch, untracked,
   remediation, reason}

Exit codes:
  0 = ready              1 = not ready (behind and/or dirty)
  2 = usage / parse error, not a git repo, or fetch failure (fail-closed)

Spec: docs/specs/2026-06-18-pre-spawn-readiness-gate.md
EOF
}

# -----------------------------------------------------------------------------
# arg parsing (mirrors plan-parallel-batch.sh)
# -----------------------------------------------------------------------------
repo_dir=""
base_branch=""
no_fetch=0
json_mode=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo-dir)
      [[ $# -ge 2 ]] || { echo "assert-spawn-readiness: --repo-dir needs a value" >&2; exit 2; }
      repo_dir="$2"; shift 2 ;;
    --repo-dir=*)
      repo_dir="${1#--repo-dir=}"; shift ;;
    --base)
      [[ $# -ge 2 ]] || { echo "assert-spawn-readiness: --base needs a value" >&2; exit 2; }
      base_branch="$2"; shift 2 ;;
    --base=*)
      base_branch="${1#--base=}"; shift ;;
    --no-fetch)
      no_fetch=1; shift ;;
    --json)
      json_mode=1; shift ;;
    -h|--help)
      usage; exit 0 ;;
    --)
      shift; break ;;
    *)
      echo "assert-spawn-readiness: unknown argument: $1" >&2
      usage >&2
      exit 2 ;;
  esac
done

command -v jq >/dev/null 2>&1 || { echo "assert-spawn-readiness: jq not found on PATH" >&2; exit 2; }

# -----------------------------------------------------------------------------
# resolve repo dir + assert it's a git repo
# -----------------------------------------------------------------------------
if [[ -z "$repo_dir" ]]; then
  repo_dir="$(git rev-parse --show-toplevel 2>/dev/null || true)"
fi
[[ -n "$repo_dir" && -d "$repo_dir" ]] || { echo "assert-spawn-readiness: repo dir not found: ${repo_dir:-<cwd>}" >&2; exit 2; }
git -C "$repo_dir" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
  || { echo "assert-spawn-readiness: not a git repository: $repo_dir" >&2; exit 2; }

git_in() { git -C "$repo_dir" "$@"; }

# -----------------------------------------------------------------------------
# resolve default branch: --base, else origin/HEAD's target, else main.
# -----------------------------------------------------------------------------
if [[ -z "$base_branch" ]]; then
  base_branch="$(git_in symbolic-ref --quiet refs/remotes/origin/HEAD 2>/dev/null \
                  | sed 's#^refs/remotes/origin/##' || true)"
  [[ -n "$base_branch" ]] || base_branch="main"
fi

# -----------------------------------------------------------------------------
# optional fetch (fail-closed: a fetch error means we can't verify the base)
# -----------------------------------------------------------------------------
fetch_failed=0
if [[ "$no_fetch" -eq 0 ]]; then
  if ! git_in fetch origin "$base_branch" -q 2>/dev/null; then
    fetch_failed=1
  fi
fi

# -----------------------------------------------------------------------------
# behind / ahead of origin/<base>
#   left-right --count origin/<base>...<base>  ->  "<behind>\t<ahead>"
#   left  = commits reachable from origin/<base> but not <base>  (we are BEHIND)
#   right = commits reachable from <base> but not origin/<base>  (we are AHEAD)
# -----------------------------------------------------------------------------
behind=0
ahead=0
counts=""
if [[ "$fetch_failed" -eq 0 ]]; then
  counts="$(git_in rev-list --left-right --count "origin/${base_branch}...${base_branch}" 2>/dev/null || true)"
fi
if [[ -n "$counts" ]]; then
  behind="$(printf '%s' "$counts" | awk '{print $1}')"
  ahead="$(printf '%s' "$counts" | awk '{print $2}')"
fi
[[ "$behind" =~ ^[0-9]+$ ]] || behind=0
[[ "$ahead"  =~ ^[0-9]+$ ]] || ahead=0

# -----------------------------------------------------------------------------
# dirty: any TRACKED change (staged or unstaged). Untracked is NOT dirty.
# `git status --porcelain` lines: XY <path>. Untracked == "?? ". Anything else
# with a non-space status code is a tracked modification/staging.
# -----------------------------------------------------------------------------
porcelain="$(git_in status --porcelain 2>/dev/null || true)"
dirty=false
untracked_paths=()
while IFS= read -r line; do
  [[ -n "$line" ]] || continue
  local_status="${line:0:2}"
  path="${line:3}"
  if [[ "$local_status" == "??" ]]; then
    untracked_paths+=("$path")
  else
    dirty=true
  fi
done <<< "$porcelain"

if [[ ${#untracked_paths[@]} -gt 0 ]]; then
  untracked_json="$(printf '%s\n' "${untracked_paths[@]}" | jq -R '.' | jq -sc '.')"
else
  untracked_json="[]"
fi

# -----------------------------------------------------------------------------
# verdict
# -----------------------------------------------------------------------------
ready=true
reason="base is current and clean"
remediation_json="null"

if [[ "$fetch_failed" -eq 1 ]]; then
  ready=false
  reason="fetch-failed"
elif [[ "$behind" -gt 0 && "$dirty" == true ]]; then
  ready=false
  reason="base is ${behind} behind origin/${base_branch} and has dirty tracked changes"
  remediation_json="$(jq -Rn --arg b "$base_branch" '"git merge --ff-only origin/\($b)"')"
elif [[ "$behind" -gt 0 ]]; then
  ready=false
  reason="base is ${behind} behind origin/${base_branch}"
  remediation_json="$(jq -Rn --arg b "$base_branch" '"git merge --ff-only origin/\($b)"')"
elif [[ "$dirty" == true ]]; then
  ready=false
  reason="base has dirty tracked changes"
fi

GEN_TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

result_json="$(jq -nc \
  --arg generated_at "$GEN_TS" \
  --argjson ready "$ready" \
  --argjson behind "$behind" \
  --argjson ahead "$ahead" \
  --argjson dirty "$dirty" \
  --arg default_branch "$base_branch" \
  --argjson untracked "$untracked_json" \
  --argjson remediation "$remediation_json" \
  --arg reason "$reason" \
  '{generated_at:$generated_at, ready:$ready, behind:$behind, ahead:$ahead,
    dirty:$dirty, default_branch:$default_branch, untracked:$untracked,
    remediation:$remediation, reason:$reason}')"

# -----------------------------------------------------------------------------
# output
# -----------------------------------------------------------------------------
if [[ "$json_mode" -eq 1 ]]; then
  printf '%s\n' "$result_json"
else
  if [[ "$ready" == true ]]; then
    echo "${C_GREEN}READY${C_RESET} — base ${base_branch} is current (behind 0, ahead ${ahead}) and clean."
  else
    echo "${C_YELLOW}NOT READY${C_RESET}: ${reason}."
    remediation="$(printf '%s' "$result_json" | jq -r '.remediation // empty')"
    if [[ -n "$remediation" ]]; then
      echo "  Remediation (run in ${repo_dir}): ${remediation}"
    fi
    if [[ "$dirty" == true ]]; then
      echo "  ${C_DIM}Base has dirty tracked changes — commit/stash/discard before spawning.${C_RESET}"
    fi
  fi
  if [[ ${#untracked_paths[@]} -gt 0 ]]; then
    echo "  ${C_DIM}untracked (not a blocker): ${untracked_paths[*]}${C_RESET}"
  fi
fi

[[ "$ready" == true ]] && exit 0
exit 1

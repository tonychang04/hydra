#!/usr/bin/env bash
#
# preflight-syntax.sh — run CI's syntax-check locally before opening a PR.
#
# WHY: PRs routinely pass local `self-test/run.sh` + `scripts/validate-state-all.sh`
# yet FAIL CI on the `Syntax (bash -n + jq + frontmatter)` job because a new
# `docs/specs/*.md` lacked the required `status:` / `date:` frontmatter (incidents:
# PRs #243, #244). This wrapper closes that gap: it runs the EXACT CI script
# against the current worktree and propagates its exit code, so a worker reproduces
# the CI verdict before pushing instead of after.
#
# Single source of truth: this script does NOT re-implement any check. It `exec`s
# `.github/workflows/scripts/syntax-check.sh`, so the local verdict can never
# diverge from what CI runs.
#
# Usage:
#   scripts/preflight-syntax.sh        # run; exits 0 (OK) or 1 (FAIL), same as CI
#   scripts/preflight-syntax.sh -h     # this help
#
# Spec: docs/specs/2026-06-07-local-syntax-check-in-self-test.md (ticket #246 / T2)

set -euo pipefail

usage() {
  sed -n '2,/^set -euo/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//; /^set -euo/d'
}

case "${1:-}" in
  -h|--help)
    usage
    exit 0
    ;;
  "")
    ;;
  *)
    echo "preflight-syntax.sh: unexpected argument: $1" >&2
    usage >&2
    exit 2
    ;;
esac

# Resolve repo root (this script lives at <root>/scripts/preflight-syntax.sh).
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
CI_CHECK="$REPO_ROOT/.github/workflows/scripts/syntax-check.sh"

if [[ ! -f "$CI_CHECK" ]]; then
  echo "preflight-syntax.sh: CI syntax-check not found at $CI_CHECK" >&2
  exit 2
fi

# Hand off to the CI script. exec replaces this process so the CI script's exit
# code is our exit code verbatim — true parity with the `syntax` CI job.
exec bash "$CI_CHECK"

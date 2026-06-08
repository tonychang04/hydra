#!/usr/bin/env bash
#
# test-contract-path.sh — regression test for scripts/contract-path.sh (#262).
#
# contract-path.sh is the SINGLE SOURCE OF TRUTH for the per-ticket validation
# contract location: `<worktree>/.hydra/contracts/<ticket>.md`. Moving the
# artifact off the committed repo root (#255/#256 design flaw) means every
# caller (the worker agents, validate-contract.sh, revalidate-contract.sh) must
# resolve the same path — this test pins that convention.
#
# Exercises:
#   - resolves <ticket> against an explicit --worktree                 -> .hydra/contracts/<n>.md
#   - default worktree falls back to cwd outside a git repo            -> ./.hydra/contracts/<n>.md
#   - --mkdir creates the .hydra/contracts parent dir                  -> dir exists, exit 0
#   - non-numeric / path-traversal ticket                             -> exit 2 (rejected)
#   - missing ticket                                                  -> exit 2
#   - two distinct tickets resolve to two distinct paths (no collision)
#   - --help                                                          -> exit 0
#
# Style matches scripts/test-validate-contract.sh (bash, NO_COLOR-aware,
# pass/fail counter, no external harness).
# Spec: docs/specs/2026-06-08-contract-artifact-location.md

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
RESOLVE="$SCRIPT_DIR/contract-path.sh"

if [[ ! -f "$RESOLVE" ]]; then
  echo "test-contract-path: $RESOLVE not found" >&2
  exit 2
fi

if [[ -t 1 ]] && [[ "${NO_COLOR:-}" != "1" ]]; then
  C_GREEN=$'\033[32m'
  C_RED=$'\033[31m'
  C_BOLD=$'\033[1m'
  C_RESET=$'\033[0m'
else
  C_GREEN=""
  C_RED=""
  C_BOLD=""
  C_RESET=""
fi

passed=0
failed=0
tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

say() { printf "\n${C_BOLD}> %s${C_RESET}\n" "$*"; }
ok()  { printf "  ${C_GREEN}OK${C_RESET}  %s\n" "$*"; passed=$((passed + 1)); }
bad() { printf "  ${C_RED}XX${C_RESET}  %s\n" "$*"; failed=$((failed + 1)); }

# run <args...> -> sets EC + OUT
run() {
  set +e
  OUT="$(NO_COLOR=1 bash "$RESOLVE" "$@" 2>&1)"
  EC=$?
  set -e
}

# ---------------------------------------------------------------------------
say "explicit --worktree resolves to <wt>/.hydra/contracts/<ticket>.md"
run 262 --worktree "$tmpdir"
if [[ "$EC" -eq 0 && "$OUT" == "$tmpdir/.hydra/contracts/262.md" ]]; then
  ok "262 --worktree $tmpdir -> $OUT"
else
  bad "expected $tmpdir/.hydra/contracts/262.md (exit 0); got exit $EC: $OUT"
fi

# ---------------------------------------------------------------------------
say "worktree flag accepted before the ticket arg too"
run --worktree "$tmpdir" 300
if [[ "$EC" -eq 0 && "$OUT" == "$tmpdir/.hydra/contracts/300.md" ]]; then
  ok "--worktree first, then ticket -> $OUT"
else
  bad "expected $tmpdir/.hydra/contracts/300.md (exit 0); got exit $EC: $OUT"
fi

# ---------------------------------------------------------------------------
say "two distinct tickets resolve to two distinct paths (no collision)"
run 300 --worktree "$tmpdir"; P300="$OUT"
run 301 --worktree "$tmpdir"; P301="$OUT"
if [[ "$P300" != "$P301" && "$P300" == *"/300.md" && "$P301" == *"/301.md" ]]; then
  ok "300 -> $P300 ; 301 -> $P301 (distinct, no collision)"
else
  bad "tickets collided or wrong shape: 300=$P300 301=$P301"
fi

# ---------------------------------------------------------------------------
say "--mkdir creates the .hydra/contracts parent dir"
run 262 --worktree "$tmpdir" --mkdir
if [[ "$EC" -eq 0 && -d "$tmpdir/.hydra/contracts" ]]; then
  ok "--mkdir created $tmpdir/.hydra/contracts"
else
  bad "expected $tmpdir/.hydra/contracts to exist (exit 0); got exit $EC; dir? $([[ -d "$tmpdir/.hydra/contracts" ]] && echo yes || echo no)"
fi

# ---------------------------------------------------------------------------
say "default worktree falls back to cwd outside a git repo"
# $tmpdir is not a git repo; run from inside it with no --worktree.
set +e
OUT="$(cd "$tmpdir" && NO_COLOR=1 bash "$RESOLVE" 262 2>&1)"
EC=$?
set -e
# Accept either an absolute path under $tmpdir or the relative ./.hydra form.
case "$OUT" in
  "$tmpdir/.hydra/contracts/262.md"|"./.hydra/contracts/262.md"|".hydra/contracts/262.md")
    if [[ "$EC" -eq 0 ]]; then ok "fallback -> $OUT"; else bad "fallback exit $EC: $OUT"; fi
    ;;
  *)
    bad "expected a .hydra/contracts/262.md fallback (exit 0); got exit $EC: $OUT"
    ;;
esac

# ---------------------------------------------------------------------------
say "non-numeric ticket is rejected (no path traversal in the filename)"
run "../../etc/passwd" --worktree "$tmpdir"
if [[ "$EC" -eq 2 ]]; then
  ok "path-traversal ticket rejected (exit 2)"
else
  bad "expected exit 2 for non-numeric ticket; got exit $EC: $OUT"
fi

run "abc" --worktree "$tmpdir"
if [[ "$EC" -eq 2 ]]; then
  ok "alpha ticket rejected (exit 2)"
else
  bad "expected exit 2 for alpha ticket; got exit $EC: $OUT"
fi

# ---------------------------------------------------------------------------
say "missing ticket -> usage error (exit 2)"
run --worktree "$tmpdir"
if [[ "$EC" -eq 2 ]]; then
  ok "missing ticket -> exit 2"
else
  bad "expected exit 2 for missing ticket; got exit $EC: $OUT"
fi

# ---------------------------------------------------------------------------
say "--help -> exit 0"
run --help
if [[ "$EC" -eq 0 && "$OUT" == *"contract-path"* ]]; then
  ok "--help prints usage, exit 0"
else
  bad "expected --help usage exit 0; got exit $EC: $OUT"
fi

# ---------------------------------------------------------------------------
printf "\n${C_BOLD}%d passed · %d failed${C_RESET}\n" "$passed" "$failed"
[[ "$failed" -eq 0 ]]

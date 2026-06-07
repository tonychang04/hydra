#!/usr/bin/env bash
#
# run.sh — self-test fixture for local CI-syntax-check parity (ticket #246).
#
# Proves that a worker can reproduce the CI `Syntax (bash -n + jq + frontmatter)`
# verdict LOCALLY before pushing — closing the gap that let PRs #243 / #244 pass
# local self-test yet fail CI on missing `status:` / `date:` spec frontmatter.
#
# RED→GREEN, no network / no docker / no Claude auth. Assertions:
#
#   1. GREEN — scripts/preflight-syntax.sh passes on the real repo (the wrapper
#      runs the exact CI script and the repo is currently clean).
#   2. RED   — a throwaway repo containing a frontmatter-less spec makes the CI
#      script FAIL with exit 1 and the canonical "missing opening --- frontmatter
#      marker" message (reproducing the #243/#244 failure mode).
#   3. RED   — a spec with frontmatter but no `status:` FAILs with exit 1 and the
#      canonical "frontmatter missing: status" message.
#   4. GREEN — a well-formed spec in that throwaway repo PASSES (exit 0).
#   5. The wrapper is a thin pass-through: it must NOT re-implement the checks
#      (single source of truth) — assert it execs the CI script.
#
# The throwaway repo mirrors the CI script's path depth so its BASH_SOURCE-based
# repo-root resolution lands correctly.
#
# Run from anywhere:
#   bash self-test/fixtures/local-syntax-check/run.sh
#
# Exit 0 on pass, 1 on any failure.
#
# Spec: docs/specs/2026-06-07-local-syntax-check-in-self-test.md

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/../../.." && pwd)"
WRAPPER="$REPO_ROOT/scripts/preflight-syntax.sh"
CI_CHECK="$REPO_ROOT/.github/workflows/scripts/syntax-check.sh"

fail_count=0
fail() { echo "FAIL: $*" >&2; fail_count=$((fail_count + 1)); }
pass() { echo "  pass: $*"; }

# --- Test 1: wrapper passes on the real repo (GREEN) -------------------------
echo "[local-syntax-check] test 1: scripts/preflight-syntax.sh passes on the repo"

if [[ ! -f "$WRAPPER" ]]; then
  fail "wrapper missing at $WRAPPER"
elif [[ ! -f "$CI_CHECK" ]]; then
  fail "CI syntax-check missing at $CI_CHECK"
elif bash "$WRAPPER" >/dev/null 2>&1; then
  pass "wrapper exits 0 on the current worktree"
else
  fail "wrapper failed on a clean worktree (it should pass)"
fi

# --- Build a throwaway repo that mirrors the CI script's path depth ----------
# The CI script resolves its repo root as <script>/../../.. — so it must live at
# <tmp>/.github/workflows/scripts/syntax-check.sh for root resolution to land on
# <tmp>. We invoke the wrapper-equivalent path: the CI script directly (the
# wrapper just execs it, verified separately in test 5).
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/.github/workflows/scripts" "$TMP/docs/specs"
cp "$CI_CHECK" "$TMP/.github/workflows/scripts/syntax-check.sh"
TMP_CHECK="$TMP/.github/workflows/scripts/syntax-check.sh"

# --- Test 2: frontmatter-less spec → exit 1 + canonical marker message (RED) -
echo "[local-syntax-check] test 2: frontmatter-less spec fails identically to CI"

printf '# Bad spec\n\nNo frontmatter at all.\n' > "$TMP/docs/specs/bad.md"
set +e
out="$(bash "$TMP_CHECK" 2>&1)"; ec=$?
set -e
rm -f "$TMP/docs/specs/bad.md"

if [[ "$ec" -ne 1 ]]; then
  fail "frontmatter-less spec: expected exit 1, got $ec"
elif ! grep -qF "missing opening --- frontmatter marker" <<<"$out"; then
  fail "frontmatter-less spec: expected the canonical marker message; got: $out"
elif ! grep -qF "syntax-check: FAIL" <<<"$out"; then
  fail "frontmatter-less spec: expected 'syntax-check: FAIL' summary; got: $out"
else
  pass "frontmatter-less spec fails with exit 1 + canonical marker message"
fi

# --- Test 3: spec missing `status:` → exit 1 + canonical message (RED) -------
echo "[local-syntax-check] test 3: spec missing status: fails identically to CI"

printf -- '---\ndate: 2026-06-07\n---\n\n# Spec missing status\n' > "$TMP/docs/specs/nostatus.md"
set +e
out="$(bash "$TMP_CHECK" 2>&1)"; ec=$?
set -e
rm -f "$TMP/docs/specs/nostatus.md"

if [[ "$ec" -ne 1 ]]; then
  fail "missing-status spec: expected exit 1, got $ec"
elif ! grep -qF "frontmatter missing: status" <<<"$out"; then
  fail "missing-status spec: expected 'frontmatter missing: status'; got: $out"
else
  pass "missing-status spec fails with exit 1 + 'frontmatter missing: status'"
fi

# --- Test 4: well-formed spec → exit 0 (GREEN) ------------------------------
echo "[local-syntax-check] test 4: well-formed spec passes"

printf -- '---\nstatus: draft\ndate: 2026-06-07\n---\n\n# Good spec\n' > "$TMP/docs/specs/good.md"
set +e
out="$(bash "$TMP_CHECK" 2>&1)"; ec=$?
set -e
rm -f "$TMP/docs/specs/good.md"

if [[ "$ec" -ne 0 ]]; then
  fail "well-formed spec: expected exit 0, got $ec; output: $out"
elif ! grep -qF "syntax-check: OK" <<<"$out"; then
  fail "well-formed spec: expected 'syntax-check: OK'; got: $out"
else
  pass "well-formed spec passes with exit 0"
fi

# --- Test 5: wrapper is a thin pass-through (single source of truth) ---------
echo "[local-syntax-check] test 5: wrapper execs the CI script (no duplicated logic)"

if [[ -f "$WRAPPER" ]] \
   && grep -qE '^[[:space:]]*exec[[:space:]]+bash[[:space:]]' "$WRAPPER" \
   && grep -qF 'syntax-check.sh' "$WRAPPER"; then
  pass "wrapper execs the CI syntax-check.sh (no copied checks)"
else
  fail "wrapper does not exec the CI syntax-check — risk of logic drift from CI"
fi

# --- Summary ----------------------------------------------------------------
if (( fail_count == 0 )); then
  echo "[local-syntax-check] ALL TESTS PASS"
  exit 0
else
  echo "[local-syntax-check] $fail_count test(s) failed" >&2
  exit 1
fi

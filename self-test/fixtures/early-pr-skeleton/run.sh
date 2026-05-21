#!/usr/bin/env bash
#
# run.sh — self-test fixture for the skeleton-first early-PR worker doctrine.
#
# Asserts that the *documented flow* mandates the early-PR milestone: a worker
# makes an initial (skeleton) commit, pushes the branch, and opens a DRAFT PR
# as its FIRST milestone — so a ~13-min stall leaves a recoverable draft PR
# instead of an orphaned worktree (ticket #188; incidents #157/#176/#159).
#
# Static assertions only (no worker spawn — a real spawn-based A/B needs Claude
# auth + two real spawns, deliberately out of scope, same as the slim fixture).
# The assertions catch drift in:
#
#   1. worker-implementation.md has a skeleton-first / early-PR section header.
#   2. That doctrine mandates all three sub-actions: an initial/skeleton COMMIT,
#      a PUSH, and a DRAFT PR.
#   3. The slim spawn template spec communicates the early-PR milestone.
#   4. The slim fixture's sample-spawn-prompt.txt carries the early-PR line
#      (so the canonical example stays in sync with the template).
#   5. The early-PR spec file exists at its expected path.
#
# Run from anywhere:
#   bash self-test/fixtures/early-pr-skeleton/run.sh
#
# Exit 0 on pass, 1 on any failure.
#
# Spec: docs/specs/2026-05-21-early-pr-skeleton-first.md

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
AGENT_IMPL="$REPO_ROOT/.claude/agents/worker-implementation.md"
SLIM_SPEC="$REPO_ROOT/docs/specs/2026-04-17-slim-worker-prompts.md"
SLIM_SAMPLE="$REPO_ROOT/self-test/fixtures/slim-worker-prompts/sample-spawn-prompt.txt"
EARLY_PR_SPEC="$REPO_ROOT/docs/specs/2026-05-21-early-pr-skeleton-first.md"

fail_count=0
fail() { echo "FAIL: $*" >&2; fail_count=$((fail_count + 1)); }
pass() { echo "  pass: $*"; }

# --- Test 1: worker-implementation.md has an early-PR / skeleton-first header
echo "[early-pr-skeleton] test 1: worker-implementation.md documents the milestone"

if [[ ! -f "$AGENT_IMPL" ]]; then
  fail "worker-implementation.md missing at $AGENT_IMPL"
else
  # A section header that names the skeleton-first / early-PR doctrine.
  if grep -qiE '^#+ .*early.?pr.*skeleton|^#+ .*skeleton.?first.*early.?pr|^#+ .*early.?pr discipline' "$AGENT_IMPL"; then
    pass "worker-implementation.md has a skeleton-first / early-PR section header"
  else
    fail "worker-implementation.md missing a skeleton-first / early-PR section header"
  fi
fi

# --- Test 2: the doctrine mandates commit + push + draft PR -----------------
echo "[early-pr-skeleton] test 2: doctrine mandates commit + push + draft PR"

if [[ -f "$AGENT_IMPL" ]]; then
  # All three sub-actions must appear in the agent definition.
  if grep -qiE 'initial commit|skeleton commit|first commit' "$AGENT_IMPL"; then
    pass "agent def mandates an initial/skeleton commit"
  else
    fail "agent def does not mandate an initial/skeleton commit"
  fi
  if grep -qiE 'push the branch|push your branch|push the skeleton|push early' "$AGENT_IMPL"; then
    pass "agent def mandates pushing the branch early"
  else
    fail "agent def does not mandate pushing the branch early"
  fi
  if grep -qiE 'draft pr|--draft' "$AGENT_IMPL"; then
    pass "agent def mandates opening a draft PR"
  else
    fail "agent def does not mention opening a draft PR"
  fi
  # The recoverability rationale must be stated (why we do it early).
  if grep -qiE 'recoverab|stall|turn limit|orphan' "$AGENT_IMPL"; then
    pass "agent def states the recoverability rationale"
  else
    fail "agent def does not state the recoverability rationale"
  fi
fi

# --- Test 3: slim spawn template communicates the early-PR milestone --------
echo "[early-pr-skeleton] test 3: slim spawn template spec signals early PR"

if [[ ! -f "$SLIM_SPEC" ]]; then
  fail "slim-worker-prompts spec missing at $SLIM_SPEC"
elif grep -qiE 'first milestone|open the draft pr early|draft pr.*(early|first)|skeleton commit.*draft pr' "$SLIM_SPEC"; then
  pass "slim spawn template spec communicates the early-PR milestone"
else
  fail "slim spawn template spec does not communicate the early-PR milestone"
fi

# --- Test 4: slim sample-spawn-prompt.txt carries the early-PR line ---------
echo "[early-pr-skeleton] test 4: slim sample prompt carries the early-PR line"

if [[ ! -f "$SLIM_SAMPLE" ]]; then
  fail "slim sample-spawn-prompt.txt missing at $SLIM_SAMPLE"
elif grep -qiE 'first milestone|draft pr.*(stall|recoverab)|skeleton commit' "$SLIM_SAMPLE"; then
  pass "slim sample prompt carries the early-PR milestone line"
else
  fail "slim sample prompt does not carry the early-PR milestone line"
fi

# --- Test 5: early-PR spec file exists --------------------------------------
echo "[early-pr-skeleton] test 5: spec file exists at expected path"

if [[ -f "$EARLY_PR_SPEC" ]]; then
  pass "spec file present at $EARLY_PR_SPEC"
else
  fail "spec file missing at $EARLY_PR_SPEC"
fi

# --- Summary ----------------------------------------------------------------
if (( fail_count == 0 )); then
  echo "[early-pr-skeleton] ALL TESTS PASS"
  exit 0
else
  echo "[early-pr-skeleton] $fail_count test(s) failed" >&2
  exit 1
fi

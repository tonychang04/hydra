#!/usr/bin/env bash
#
# run.sh — self-test fixture for the slim worker-spawn prompt template.
#
# Static assertions only (no worker spawn — spawn-based A/B comparison is
# deliberately out of scope per docs/specs/2026-04-17-slim-worker-prompts.md
# "Non-goals"). The six assertions here are enough to catch drift in:
#
#   1. The canonical template shape (header + footer lines present in order).
#   2. The header+footer char budget (≤ 800 chars before the Memory Brief).
#   3. Every worker-*.md agent acknowledges the slim template.
#   4. CLAUDE.md points at the spec.
#   5. CLAUDE.md is still within the 18,000-char ceiling.
#   6. The canonical spec file exists at the expected path.
#
# Run from anywhere:
#   bash self-test/fixtures/slim-worker-prompts/run.sh
#
# Exit 0 on pass, 1 on any failure.
#
# Spec: docs/specs/2026-04-17-slim-worker-prompts.md

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
SAMPLE="$SCRIPT_DIR/sample-spawn-prompt.txt"
AGENTS_DIR="$REPO_ROOT/.claude/agents"
CLAUDE_MD="$REPO_ROOT/CLAUDE.md"
SPEC_PATH="$REPO_ROOT/docs/specs/2026-04-17-slim-worker-prompts.md"
SIZE_CAP=18000

fail_count=0
fail() { echo "FAIL: $*" >&2; fail_count=$((fail_count + 1)); }
pass() { echo "  pass: $*"; }

# --- Test 1: sample prompt has the canonical header + footer --------------
echo "[slim-worker-prompts] test 1: sample has canonical header + footer"

if [[ ! -f "$SAMPLE" ]]; then
  fail "sample-spawn-prompt.txt missing at $SAMPLE"
else
  # Four header lines in order: Ticket:, Repo:, Tier:, blank
  if ! grep -q '^Ticket: https://github.com/' "$SAMPLE"; then
    fail "sample missing 'Ticket: https://github.com/' header"
  else
    pass "sample has Ticket URL header"
  fi
  if ! grep -q '^Repo: ' "$SAMPLE"; then
    fail "sample missing 'Repo: ' header"
  else
    pass "sample has Repo header"
  fi
  if ! grep -q '^Tier: T' "$SAMPLE"; then
    fail "sample missing 'Tier: T' header"
  else
    pass "sample has Tier header"
  fi
  # Footer lines
  if ! grep -q '^Fetch full body via' "$SAMPLE"; then
    fail "sample missing 'Fetch full body via' footer"
  else
    pass "sample has Fetch-full-body footer"
  fi
  if ! grep -q '^Worker type: ' "$SAMPLE"; then
    fail "sample missing 'Worker type: ' footer"
  else
    pass "sample has Worker-type footer"
  fi
  if ! grep -q 'Coordinate-with:' "$SAMPLE"; then
    fail "sample missing 'Coordinate-with:' hint"
  else
    pass "sample has Coordinate-with hint"
  fi
  if ! grep -q '^Done = draft PR' "$SAMPLE"; then
    fail "sample missing 'Done = draft PR' footer"
  else
    pass "sample has Done=draft-PR footer"
  fi
fi

# --- Test 2: header + footer ≤ 800 chars (sans memory brief placeholder) --
echo "[slim-worker-prompts] test 2: header + footer ≤ 800 chars"

if [[ -f "$SAMPLE" ]]; then
  # Strip the brief-placeholder line — we're measuring the fixed envelope.
  envelope="$(grep -v 'MEMORY_BRIEF_PLACEHOLDER' "$SAMPLE" || true)"
  env_len="$(printf '%s' "$envelope" | LC_ALL=C wc -c | tr -d ' ')"
  if (( env_len <= 800 )); then
    pass "envelope is $env_len chars (≤ 800)"
  else
    fail "envelope is $env_len chars (exceeds 800 cap)"
  fi
fi

# --- Test 3: every worker-*.md acknowledges the slim template -------------
echo "[slim-worker-prompts] test 3: every worker-*.md has 'Slim spawn prompt'"

shopt -s nullglob
found_any=0
for agent_file in "$AGENTS_DIR"/worker-*.md; do
  found_any=1
  name="$(basename "$agent_file")"
  if grep -q 'Slim spawn prompt' "$agent_file"; then
    pass "$name has 'Slim spawn prompt' acknowledgement"
  else
    fail "$name missing 'Slim spawn prompt' acknowledgement"
  fi
done
shopt -u nullglob

if (( found_any == 0 )); then
  fail "no worker-*.md files found at $AGENTS_DIR"
fi

# --- Test 4: CLAUDE.md points at the spec ---------------------------------
echo "[slim-worker-prompts] test 4: CLAUDE.md references the spec"

if [[ ! -f "$CLAUDE_MD" ]]; then
  fail "CLAUDE.md missing at $CLAUDE_MD"
elif grep -q 'docs/specs/2026-04-17-slim-worker-prompts.md' "$CLAUDE_MD"; then
  pass "CLAUDE.md points at the spec"
else
  fail "CLAUDE.md does not reference docs/specs/2026-04-17-slim-worker-prompts.md"
fi

# --- Test 5: CLAUDE.md under size ceiling ---------------------------------
echo "[slim-worker-prompts] test 5: CLAUDE.md under $SIZE_CAP chars"

if [[ -f "$CLAUDE_MD" ]]; then
  claude_len="$(LC_ALL=C wc -c < "$CLAUDE_MD" | tr -d ' ')"
  if (( claude_len <= SIZE_CAP )); then
    pass "CLAUDE.md is $claude_len chars (≤ $SIZE_CAP)"
  else
    fail "CLAUDE.md is $claude_len chars (exceeds $SIZE_CAP)"
  fi
fi

# --- Test 6: spec file exists ---------------------------------------------
echo "[slim-worker-prompts] test 6: spec file exists at expected path"

if [[ -f "$SPEC_PATH" ]]; then
  pass "spec file present at $SPEC_PATH"
else
  fail "spec file missing at $SPEC_PATH"
fi

# --- Summary --------------------------------------------------------------
if (( fail_count == 0 )); then
  echo "[slim-worker-prompts] ALL TESTS PASS"
  exit 0
else
  echo "[slim-worker-prompts] $fail_count test(s) failed" >&2
  exit 1
fi

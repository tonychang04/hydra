#!/usr/bin/env bash
#
# run.sh — self-test fixture for the systematic-debugging routing wired into
# worker-implementation for bug-class tickets (ticket #177).
#
# Static assertions only (no worker spawn). The five assertions catch drift in:
#
#   1. worker-implementation.md frontmatter lists superpowers:systematic-debugging.
#   2. The agent doc has bug-class detection language (skill + trigger labels/keywords).
#   3. The agent doc has the non-bug exemption language (feature work isn't taxed).
#   4. The agent doc has a worked example referencing the skill's phases.
#   5. The canonical spec file exists at the expected path.
#
# This fixture would FAIL on the pre-#177 tree (no systematic-debugging in the
# frontmatter, no detection/exemption language) — that's the red/green proof.
#
# Run from anywhere:
#   bash self-test/fixtures/systematic-debugging-routing/run.sh
#
# Exit 0 on pass, 1 on any failure.
#
# Spec: docs/specs/2026-05-20-systematic-debugging-bug-tickets.md

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
AGENT_FILE="$REPO_ROOT/.claude/agents/worker-implementation.md"
SPEC_PATH="$REPO_ROOT/docs/specs/2026-05-20-systematic-debugging-bug-tickets.md"

fail_count=0
fail() { echo "FAIL: $*" >&2; fail_count=$((fail_count + 1)); }
pass() { echo "  pass: $*"; }

# --- Test 0: agent file present -------------------------------------------
echo "[systematic-debugging-routing] test 0: agent file present"
if [[ ! -f "$AGENT_FILE" ]]; then
  fail "worker-implementation.md missing at $AGENT_FILE"
  echo "[systematic-debugging-routing] $fail_count test(s) failed" >&2
  exit 1
fi
pass "worker-implementation.md present"

# Extract the YAML frontmatter (lines between the first two '---' delimiters).
frontmatter="$(awk 'NR==1 && $0=="---"{f=1; next} f && $0=="---"{exit} f' "$AGENT_FILE")"
# Everything after the frontmatter is the body prose.
body="$(awk 'BEGIN{d=0} $0=="---"{d++; next} d>=2' "$AGENT_FILE")"

# --- Test 1: frontmatter lists the skill ----------------------------------
echo "[systematic-debugging-routing] test 1: frontmatter lists superpowers:systematic-debugging"
if printf '%s\n' "$frontmatter" | grep -qE '^[[:space:]]*-[[:space:]]+superpowers:systematic-debugging[[:space:]]*$'; then
  pass "skills: frontmatter includes superpowers:systematic-debugging"
else
  fail "skills: frontmatter does NOT include superpowers:systematic-debugging"
fi

# --- Test 2: bug-class detection language ----------------------------------
echo "[systematic-debugging-routing] test 2: bug-class detection language present"
if printf '%s\n' "$body" | grep -q 'superpowers:systematic-debugging'; then
  pass "body invokes superpowers:systematic-debugging"
else
  fail "body does NOT mention superpowers:systematic-debugging"
fi
if printf '%s\n' "$body" | grep -qi 'bug-class'; then
  pass "body defines bug-class detection"
else
  fail "body has no 'bug-class' detection language"
fi
# At least one of the documented trigger signals must be named.
if printf '%s\n' "$body" | grep -qiE 'type:bug|stack trace|regression'; then
  pass "body names a bug-class trigger (label / keyword / stack trace)"
else
  fail "body names none of the bug-class triggers"
fi

# --- Test 3: non-bug exemption language ------------------------------------
echo "[systematic-debugging-routing] test 3: non-bug exemption language present"
if printf '%s\n' "$body" | grep -qiE 'non-bug|don.t tax|skip systematic-debugging'; then
  pass "body exempts non-bug tickets from debugging ceremony"
else
  fail "body does NOT exempt non-bug tickets"
fi

# --- Test 4: worked example referencing the phases ------------------------
echo "[systematic-debugging-routing] test 4: worked example references the phases"
if printf '%s\n' "$body" | grep -qiE 'Phase 1' && printf '%s\n' "$body" | grep -qiE 'Phase 4'; then
  pass "body has a worked example walking Phase 1 → Phase 4"
else
  fail "body lacks a worked example referencing the four phases"
fi
if printf '%s\n' "$body" | grep -qi 'root cause'; then
  pass "worked example emphasizes root cause over symptom"
else
  fail "worked example does not emphasize root cause"
fi

# --- Test 5: spec file exists ---------------------------------------------
echo "[systematic-debugging-routing] test 5: spec file exists at expected path"
if [[ -f "$SPEC_PATH" ]]; then
  pass "spec file present at $SPEC_PATH"
else
  fail "spec file missing at $SPEC_PATH"
fi

# --- Summary --------------------------------------------------------------
if (( fail_count == 0 )); then
  echo "[systematic-debugging-routing] ALL TESTS PASS"
  exit 0
else
  echo "[systematic-debugging-routing] $fail_count test(s) failed" >&2
  exit 1
fi

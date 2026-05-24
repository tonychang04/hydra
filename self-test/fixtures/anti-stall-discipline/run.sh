#!/usr/bin/env bash
#
# run.sh — self-test fixture for the worker anti-stall discipline.
#
# Asserts that the *documented worker behavior* prevents the harness 600s
# no-progress stall watchdog from killing workers: NEVER foreground a
# long-lived/quiet command, background→curl-poll→kill servers, do not assume
# `timeout` exists (absent on macOS → exit 127), and in worker-review keep
# `/codex review` OFF by default (it reliably stalls reviewers). Tickets #220 /
# #222; failure modes observed live 2026-05-23 (4+ workers killed).
#
# Static assertions only (no worker spawn — a real spawn-based A/B needs Claude
# auth + two real spawns, deliberately out of scope, same as the early-pr and
# slim fixtures). The assertions catch drift in:
#
#   1. worker-implementation.md has an "Anti-stall" section header.
#   2. worker-review.md has an "Anti-stall" section header.
#   3. Each anti-stall section mandates the three rules: (a) no foreground /
#      dev server / --watch; (b) background → curl-poll → kill; (c) the
#      timeout-is-absent + `sleep N && kill` portability rule.
#   4. worker-review.md documents `/codex review` as OFF by default, AND its
#      Flow step 6 no longer reads as an unconditional "Run /codex review".
#   5. The anti-stall spec file exists at its expected path.
#
# Run from anywhere:
#   bash self-test/fixtures/anti-stall-discipline/run.sh
#
# Exit 0 on pass, 1 on any failure.
#
# Spec: docs/specs/2026-05-24-worker-anti-stall-discipline.md

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
AGENT_IMPL="$REPO_ROOT/.claude/agents/worker-implementation.md"
AGENT_REVIEW="$REPO_ROOT/.claude/agents/worker-review.md"
SPEC="$REPO_ROOT/docs/specs/2026-05-24-worker-anti-stall-discipline.md"

fail_count=0
fail() { echo "FAIL: $*" >&2; fail_count=$((fail_count + 1)); }
pass() { echo "  pass: $*"; }

# Extract ONLY the body of an "Anti-stall" section (from its header up to the
# next top-level "## " header). Scoping is the point: the rule assertions must
# be satisfied by the DOCTRINE section, not by unrelated vocabulary elsewhere in
# the file (a false-green). awk emits the section body to stdout.
extract_anti_stall_section() {
  awk '
    /^## .*[Aa]nti.?stall/ { insec=1; next }
    insec && /^## / { insec=0 }
    insec { print }
  ' "$1"
}

# Assert the three anti-stall rules appear WITHIN a given section body.
assert_three_rules() {
  local label="$1" section="$2"
  # Rule 1: never foreground a long-lived/quiet command — name a concrete one.
  if grep -qiE 'foreground|dev server|--watch|never .*serv|npm run dev|vite' <<<"$section"; then
    pass "$label mandates: no foreground long-lived/quiet command"
  else
    fail "$label does not mandate: no foreground long-lived/quiet command"
  fi
  # Rule 2: background → poll/curl → kill.
  if grep -qiE 'curl' <<<"$section" && grep -qiE '\bkill\b' <<<"$section" \
     && grep -qiE 'background|&$|& *$|>/dev/null 2>&1 &| &\b' <<<"$section"; then
    pass "$label mandates: background → poll/curl → kill a server"
  else
    fail "$label does not mandate: background → poll/curl → kill a server"
  fi
  # Rule 3: timeout is not portable (macOS / exit 127) + sleep N && kill.
  if grep -qiE 'timeout' <<<"$section" \
     && grep -qiE 'macos|gtimeout|127|do not assume|never .*assume' <<<"$section" \
     && grep -qiE 'sleep [0-9N].*kill|sleep.*&&.*kill' <<<"$section"; then
    pass "$label mandates: do-not-assume-timeout + sleep N && kill watchdog"
  else
    fail "$label does not mandate: do-not-assume-timeout + sleep N && kill watchdog"
  fi
}

# --- Test 1: worker-implementation.md has an Anti-stall section header -------
echo "[anti-stall] test 1: worker-implementation.md documents anti-stall discipline"

if [[ ! -f "$AGENT_IMPL" ]]; then
  fail "worker-implementation.md missing at $AGENT_IMPL"
else
  if grep -qiE '^#+ .*anti.?stall' "$AGENT_IMPL"; then
    pass "worker-implementation.md has an Anti-stall section header"
  else
    fail "worker-implementation.md missing an Anti-stall section header"
  fi
fi

# --- Test 2: worker-review.md has an Anti-stall section header ---------------
echo "[anti-stall] test 2: worker-review.md documents anti-stall discipline"

if [[ ! -f "$AGENT_REVIEW" ]]; then
  fail "worker-review.md missing at $AGENT_REVIEW"
else
  if grep -qiE '^#+ .*anti.?stall' "$AGENT_REVIEW"; then
    pass "worker-review.md has an Anti-stall section header"
  else
    fail "worker-review.md missing an Anti-stall section header"
  fi
fi

# --- Test 3: each anti-stall section mandates the three rules ----------------
echo "[anti-stall] test 3: both anti-stall sections mandate the three rules"

if [[ -f "$AGENT_IMPL" ]]; then
  IMPL_SEC="$(extract_anti_stall_section "$AGENT_IMPL")"
  if [[ -z "$IMPL_SEC" ]]; then
    fail "could not extract an Anti-stall section body from worker-implementation.md"
  else
    assert_three_rules "worker-implementation.md" "$IMPL_SEC"
  fi
fi

if [[ -f "$AGENT_REVIEW" ]]; then
  REVIEW_SEC="$(extract_anti_stall_section "$AGENT_REVIEW")"
  if [[ -z "$REVIEW_SEC" ]]; then
    fail "could not extract an Anti-stall section body from worker-review.md"
  else
    assert_three_rules "worker-review.md" "$REVIEW_SEC"
  fi
fi

# --- Test 4: worker-review.md keeps /codex review OFF by default -------------
echo "[anti-stall] test 4: worker-review.md documents /codex review off by default"

if [[ -f "$AGENT_REVIEW" ]]; then
  # (a) the off-by-default rule is stated somewhere in the file.
  if grep -qiE 'codex review.*(off by default|off-by-default)|`?/codex review`? is off' "$AGENT_REVIEW"; then
    pass "worker-review.md states /codex review is OFF by default"
  else
    fail "worker-review.md does not state /codex review is OFF by default"
  fi
  # (b) Flow step 6 is no longer an unconditional "Run /codex review ..." line.
  #     Pull the line(s) of numbered step 6 and assert they carry the gate.
  STEP6="$(grep -E '^6\. ' "$AGENT_REVIEW" | head -1)"
  if [[ -z "$STEP6" ]]; then
    fail "could not find Flow step 6 in worker-review.md"
  elif grep -qiE '^6\. .*[Rr]un .*/codex review.*adversarial second opinion$' <<<"$STEP6"; then
    fail "Flow step 6 still reads as an unconditional 'Run /codex review' default step"
  elif grep -qiE 'off by default|opt[- ]in|skip it' <<<"$STEP6"; then
    pass "Flow step 6 gates /codex review (off by default / opt-in)"
  else
    fail "Flow step 6 does not gate /codex review as off-by-default / opt-in"
  fi
fi

# --- Test 5: anti-stall spec file exists ------------------------------------
echo "[anti-stall] test 5: spec file exists at expected path"

if [[ -f "$SPEC" ]]; then
  pass "spec file present at $SPEC"
else
  fail "spec file missing at $SPEC"
fi

# --- Summary ----------------------------------------------------------------
if (( fail_count == 0 )); then
  echo "[anti-stall] ALL TESTS PASS"
  exit 0
else
  echo "[anti-stall] $fail_count test(s) failed" >&2
  exit 1
fi

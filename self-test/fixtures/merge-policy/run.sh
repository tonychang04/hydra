#!/usr/bin/env bash
#
# self-test fixture driver for scripts/merge-policy-lookup.sh --queue mode.
#
# Exercises the `--queue` flag added in ticket #154 against the three
# merge-policy fixtures (legacy string, object form, queue-enabled). This
# complements — not replaces — the `repo-merge-policy-override` golden-case
# block in self-test/golden-cases.example.json that covers the pre-#154
# behavior (which MUST still pass).
#
# Tests:
#   1. queue-enabled repo + T1 auto → "queue:auto"
#   2. queue-enabled repo + T2 auto_if_review_clean → "queue:auto_if_review_clean"
#   3. queue-enabled repo + T3 → "never" (hard safety rail; never prefixed)
#   4. queue-enabled repo + T2 human (override) → "human" (not prefixed)
#   5. queue_disabled repo + T1 auto + --queue → "auto" (flag inert)
#   6. queue_enabled_absent repo + T1 auto + --queue → "auto" (default false)
#   7. legacy-string repo (auto-t1) + --queue + T1 → "queue:auto" (legacy compat)
#   8. legacy-string repo (auto-t1) + --queue + T2 → "human" (not prefixed)
#   9. baseline: no --queue on the queue-enabled repo → "auto" (flag required)
#
# Exits 0 on PASS, non-zero on FAIL with the diff on stderr.

set -euo pipefail
export NO_COLOR=1

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd -- "$SCRIPT_DIR/../../.." && pwd)"
LOOKUP="$ROOT_DIR/scripts/merge-policy-lookup.sh"
QUEUE_FIX="$SCRIPT_DIR/repos-queue-enabled.json"
LEGACY_FIX="$SCRIPT_DIR/repos-legacy-string.json"
OBJECT_FIX="$SCRIPT_DIR/repos-object-form.json"

[[ -x "$LOOKUP" ]] || { echo "FAIL: $LOOKUP not executable" >&2; exit 1; }
[[ -f "$QUEUE_FIX" ]] || { echo "FAIL: queue fixture missing: $QUEUE_FIX" >&2; exit 1; }
[[ -f "$LEGACY_FIX" ]] || { echo "FAIL: legacy fixture missing: $LEGACY_FIX" >&2; exit 1; }

fail=0
passed=0

# Assert stdout of `$LOOKUP $@` equals the first arg (expected output).
assert_eq() {
  local expected="$1"; shift
  local label="$1"; shift
  local got
  got="$("$LOOKUP" "$@" 2>/dev/null)" || { echo "FAIL: $label — lookup exited non-zero" >&2; fail=1; return; }
  if [[ "$got" != "$expected" ]]; then
    echo "FAIL: $label" >&2
    echo "  cmd:      $LOOKUP $*" >&2
    echo "  expected: $expected" >&2
    echo "  got:      $got" >&2
    fail=1
    return
  fi
  passed=$((passed+1))
}

# 1. queue-auto-both + T1 --queue → queue:auto
assert_eq "queue:auto" \
  "case-1: queue-auto-both T1 --queue" \
  fixture-org/queue-auto-both T1 --repos-file "$QUEUE_FIX" --queue

# 2. queue-auto-both + T2 --queue → queue:auto_if_review_clean
assert_eq "queue:auto_if_review_clean" \
  "case-2: queue-auto-both T2 --queue" \
  fixture-org/queue-auto-both T2 --repos-file "$QUEUE_FIX" --queue

# 3. T3 always never, never prefixed even with --queue
assert_eq "never" \
  "case-3: queue-auto-both T3 --queue (hard rail)" \
  fixture-org/queue-auto-both T3 --repos-file "$QUEUE_FIX" --queue

# 4. queue-enabled repo but T2 is `human` → not prefixed
assert_eq "human" \
  "case-4: queue-human-t2 T2 --queue (human not prefixed)" \
  fixture-org/queue-human-t2 T2 --repos-file "$QUEUE_FIX" --queue

# 5. queue_enabled:false explicitly → flag inert
assert_eq "auto" \
  "case-5: queue-off-explicit T1 --queue (explicit false)" \
  fixture-org/queue-off-explicit T1 --repos-file "$QUEUE_FIX" --queue

# 6. queue_enabled absent → treated as false
assert_eq "auto" \
  "case-6: queue-absent T1 --queue (default false)" \
  fixture-org/queue-absent T1 --repos-file "$QUEUE_FIX" --queue

# 7. legacy string form compat: auto-t1 + queue_enabled:true + T1 → queue:auto
assert_eq "queue:auto" \
  "case-7: queue-legacy-auto-t1 T1 --queue (legacy shape)" \
  fixture-org/queue-legacy-auto-t1 T1 --repos-file "$QUEUE_FIX" --queue

# 8. legacy string form: auto-t1 + queue_enabled:true + T2 → human (auto-t1 maps T2→human)
assert_eq "human" \
  "case-8: queue-legacy-auto-t1 T2 --queue (auto-t1 T2 is human)" \
  fixture-org/queue-legacy-auto-t1 T2 --repos-file "$QUEUE_FIX" --queue

# 9. Baseline: no --queue on queue-enabled repo → plain string
assert_eq "auto" \
  "case-9: queue-auto-both T1 (no --queue flag)" \
  fixture-org/queue-auto-both T1 --repos-file "$QUEUE_FIX"

# 10. Regression: the pre-#154 object-form behavior is untouched
assert_eq "human" \
  "case-10: object-form hydra T1 (regression — framework lock-down)" \
  tonychang04/hydra T1 --repos-file "$OBJECT_FIX"

# 11. Regression: the pre-#154 legacy-string behavior is untouched
assert_eq "auto" \
  "case-11: legacy-auto-t1 T1 (regression — legacy still works)" \
  fixture-org/legacy-auto-t1 T1 --repos-file "$LEGACY_FIX"

if [[ "$fail" != "0" ]]; then
  echo "merge-policy fixture: FAIL ($passed passed before first failure)" >&2
  exit 1
fi

echo "PASS ($passed/11 cases)"
exit 0

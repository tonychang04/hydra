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
# Ticket #245 additions (bare-string directive forms):
#  12-17. bare directive repos (auto / auto_if_review_clean / human) each
#         resolve to themselves for T1 and T2.
#  18.    bare directive repo + T3 → "never" (hard rail still wins).
#  19.    live-config drift guard: every merge_policy value present in
#         state/repos.json (or state/repos.example.json as fallback) resolves
#         without an "unknown legacy" error, and T3 → never is preserved.
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
BARE_FIX="$SCRIPT_DIR/repos-bare-directive.json"

[[ -x "$LOOKUP" ]] || { echo "FAIL: $LOOKUP not executable" >&2; exit 1; }
[[ -f "$QUEUE_FIX" ]] || { echo "FAIL: queue fixture missing: $QUEUE_FIX" >&2; exit 1; }
[[ -f "$LEGACY_FIX" ]] || { echo "FAIL: legacy fixture missing: $LEGACY_FIX" >&2; exit 1; }
[[ -f "$BARE_FIX" ]] || { echo "FAIL: bare-directive fixture missing: $BARE_FIX" >&2; exit 1; }

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

# -----------------------------------------------------------------------------
# Ticket #245: bare-string directive forms.
# A bare directive (auto / auto_if_review_clean / human) applies uniformly to
# T1 and T2; T3 stays hardcoded `never`. These MUST resolve, not error with
# "unknown legacy merge_policy".
# -----------------------------------------------------------------------------

# 12. bare `auto` + T1 → auto
assert_eq "auto" \
  "case-12: bare-auto T1" \
  fixture-org/bare-auto T1 --repos-file "$BARE_FIX"

# 13. bare `auto` + T2 → auto (uniform across non-T3 tiers)
assert_eq "auto" \
  "case-13: bare-auto T2" \
  fixture-org/bare-auto T2 --repos-file "$BARE_FIX"

# 14. bare `auto_if_review_clean` + T1 → auto_if_review_clean (the #245 bug)
assert_eq "auto_if_review_clean" \
  "case-14: bare-review-clean T1" \
  fixture-org/bare-review-clean T1 --repos-file "$BARE_FIX"

# 15. bare `auto_if_review_clean` + T2 → auto_if_review_clean (the exact repro)
assert_eq "auto_if_review_clean" \
  "case-15: bare-review-clean T2 (the #245 reproduction)" \
  fixture-org/bare-review-clean T2 --repos-file "$BARE_FIX"

# 16. bare `human` + T2 → human
assert_eq "human" \
  "case-16: bare-human T2" \
  fixture-org/bare-human T2 --repos-file "$BARE_FIX"

# 17. bare directive + --queue (queue absent on fixture) → unprefixed
assert_eq "auto_if_review_clean" \
  "case-17: bare-review-clean T2 --queue (no merge_queue_enabled → inert)" \
  fixture-org/bare-review-clean T2 --repos-file "$BARE_FIX" --queue

# 18. bare directive repo + T3 → never (hard rail wins over any policy value)
assert_eq "never" \
  "case-18: bare-review-clean T3 (hard rail preserved)" \
  fixture-org/bare-review-clean T3 --repos-file "$BARE_FIX"

# -----------------------------------------------------------------------------
# 19. Drift guard (ticket #245): EVERY merge_policy value present in the live
# state/repos.json must resolve without an "unknown legacy" error, and T3 must
# still resolve to `never`. Falls back to repos.example.json when the live file
# is absent (fresh worktree / CI). This catches future drift between the values
# the operator writes and the values the lookup recognizes.
# -----------------------------------------------------------------------------
live_repos="$ROOT_DIR/state/repos.json"
[[ -f "$live_repos" ]] || live_repos="$ROOT_DIR/state/repos.example.json"

if [[ -f "$live_repos" ]]; then
  # Enumerate every (owner/name, merge_policy) where merge_policy is a non-null
  # string. Object-form entries are exercised by the object fixture above; the
  # drift bug only affects bare strings, so we target those.
  while IFS=$'\t' read -r slug mp; do
    [[ -z "$slug" ]] && continue
    for t in T1 T2; do
      if ! out="$("$LOOKUP" "$slug" "$t" --repos-file "$live_repos" 2>&1)"; then
        echo "FAIL: case-19 drift-guard — '$slug' ($mp) at $t did not resolve" >&2
        echo "  out: $out" >&2
        fail=1
      else
        passed=$((passed+1))
      fi
    done
    # T3 must always be `never` regardless of the configured policy.
    t3="$("$LOOKUP" "$slug" T3 --repos-file "$live_repos" 2>/dev/null || true)"
    if [[ "$t3" != "never" ]]; then
      echo "FAIL: case-19 drift-guard — '$slug' T3 expected 'never', got '$t3'" >&2
      fail=1
    else
      passed=$((passed+1))
    fi
  done < <(jq -r '.repos[] | select((.merge_policy // null) | type == "string") | "\(.owner)/\(.name)\t\(.merge_policy)"' "$live_repos")
else
  echo "  (case-19 drift-guard: no repos.json/.example.json found — skipped)" >&2
fi

if [[ "$fail" != "0" ]]; then
  echo "merge-policy fixture: FAIL ($passed passed before first failure)" >&2
  exit 1
fi

echo "PASS ($passed cases)"
exit 0

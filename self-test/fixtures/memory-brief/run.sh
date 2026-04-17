#!/usr/bin/env bash
#
# run.sh — self-test fixture for scripts/build-memory-brief.sh
#
# Verifies:
#   1. Output matches expected-brief.md byte-for-byte (sorting, filtering,
#      scope inclusion/exclusion all deterministic for the fixture inputs).
#   2. Output is <= 2000 bytes (hard budget cap).
#   3. Exit code is 0.
#   4. Fresh-repo invocation (no fixtures) returns empty output and exit 0.
#
# Run from anywhere:
#   bash self-test/fixtures/memory-brief/run.sh
#
# Invoked by self-test/run.sh as part of `./hydra self-test`.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
BUILDER="$REPO_ROOT/scripts/build-memory-brief.sh"

FIXTURE_MEMORY="$SCRIPT_DIR/memory"
FIXTURE_STATE="$SCRIPT_DIR/state"
EXPECTED="$SCRIPT_DIR/expected-brief.md"

fail_count=0
fail() { echo "FAIL: $*" >&2; fail_count=$((fail_count + 1)); }
pass() { echo "  pass: $*"; }

# --- Test 1: deterministic output matches expected-brief.md ---------------
echo "[memory-brief] test 1: deterministic output matches golden"
actual="$("$BUILDER" samplerepo/samplerepo \
  --memory-dir "$FIXTURE_MEMORY" \
  --state-dir "$FIXTURE_STATE" \
  --now 2026-04-17)"

expected="$(cat "$EXPECTED")"
# Both are trimmed to single trailing newline by the script / cat, so compare strings directly.
if [[ "$actual" == "$expected" ]]; then
  pass "output matches expected-brief.md"
else
  fail "output does not match expected-brief.md"
  diff <(printf '%s\n' "$expected") <(printf '%s\n' "$actual") >&2 || true
fi

# --- Test 2: byte budget ≤ 2000 -------------------------------------------
echo "[memory-brief] test 2: output ≤ 2000 bytes"
byte_len="$(printf '%s' "$actual" | LC_ALL=C wc -c | tr -d ' ')"
if (( byte_len <= 2000 )); then
  pass "output is $byte_len bytes (≤ 2000)"
else
  fail "output is $byte_len bytes (exceeds 2000 cap)"
fi

# --- Test 3: top repo learnings are sorted by citation count desc ---------
echo "[memory-brief] test 3: repo learnings sorted by count desc"
top_block="$(printf '%s\n' "$actual" | awk '/^## Top repo learnings/{flag=1; next} /^## /{flag=0} flag && /^-/')"
counts="$(printf '%s\n' "$top_block" | sed -E 's/.*cited ([0-9]+) times.*/\1/')"
sorted="$(printf '%s\n' "$counts" | sort -rn)"
if [[ "$counts" == "$sorted" ]]; then
  pass "top learnings sorted ($counts) descending"
else
  fail "top learnings not sorted — raw: $counts, expected desc: $sorted"
fi

# --- Test 4: otherrepo excluded from repo learnings -----------------------
echo "[memory-brief] test 4: otherrepo excluded from ## Top repo learnings"
if printf '%s\n' "$top_block" | grep -q 'otherrepo\|Stream idle\|Redis port'; then
  fail "otherrepo content leaked into samplerepo's top learnings section"
else
  pass "samplerepo section does not contain otherrepo entries"
fi

# --- Test 5: cross-repo section includes entries from both repos ----------
echo "[memory-brief] test 5: cross-repo section mixes repos"
cross_block="$(printf '%s\n' "$actual" | awk '/^## Cross-repo patterns/{flag=1; next} /^## /{flag=0} flag && /^-/')"
if printf '%s\n' "$cross_block" | grep -q 'learnings-otherrepo.md'; then
  pass "cross-repo block contains learnings-otherrepo"
else
  fail "cross-repo block missing learnings-otherrepo entries"
fi

# --- Test 6: escalation-faq scope filter ----------------------------------
echo "[memory-brief] test 6: escalation-faq honors Scope: tags"
faq_block="$(printf '%s\n' "$actual" | awk '/^## Escalation FAQ/{flag=1; next} /^## /{flag=0} flag && /^-/')"
# samplerepo-scoped and global-scoped and no-scope (default global) are IN
if ! printf '%s\n' "$faq_block" | grep -q 'Broken lint'; then fail "missing samplerepo Broken lint entry"; else pass "has samplerepo Broken lint entry"; fi
if ! printf '%s\n' "$faq_block" | grep -q 'Stream idle timeout'; then fail "missing global Stream idle entry"; else pass "has global Stream idle entry"; fi
if ! printf '%s\n' "$faq_block" | grep -q 'Lockfile drift from npm'; then fail "missing no-scope entry"; else pass "has no-scope entry (defaults to global)"; fi
# otherrepo-only scope is OUT
if printf '%s\n' "$faq_block" | grep -q 'Redis port 6379 collides'; then
  fail "otherrepo-only scoped entry leaked into samplerepo brief"
else
  pass "otherrepo-only entry correctly excluded"
fi

# --- Test 7: fresh-repo invocation returns empty output with exit 0 -------
echo "[memory-brief] test 7: fresh repo → empty output, exit 0"
tmp_empty="$(mktemp -d)"
trap 'rm -rf "$tmp_empty"' EXIT
mkdir -p "$tmp_empty/memory" "$tmp_empty/state"
fresh_out="$("$BUILDER" fresh/repo --memory-dir "$tmp_empty/memory" --state-dir "$tmp_empty/state" --now 2026-04-17 2>&1)"
fresh_rc=$?
if [[ -z "$fresh_out" ]] && (( fresh_rc == 0 )); then
  pass "fresh repo emits empty brief and exits 0"
else
  fail "fresh repo: got rc=$fresh_rc, out='$fresh_out'"
fi

# --- Summary --------------------------------------------------------------
if (( fail_count == 0 )); then
  echo "[memory-brief] ALL TESTS PASS"
  exit 0
else
  echo "[memory-brief] $fail_count test(s) failed" >&2
  exit 1
fi

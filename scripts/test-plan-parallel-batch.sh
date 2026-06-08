#!/usr/bin/env bash
#
# test-plan-parallel-batch.sh — regression test for scripts/plan-parallel-batch.sh
# (ticket #257, anti-drift parallelism: pre-spawn file-overlap detection).
#
# Proves the helper deterministically partitions a candidate ticket batch into a
# parallel-safe set (disjoint file footprints) + serialized groups (overlapping
# footprints). The headline assertion (ticket acceptance criterion) is Test 1:
# 3 tickets, 2 sharing a file -> parallel{the disjoint one} + serialize{the 2}.
#
# Style: matches scripts/test-validate-contract.sh (bash, colored output,
# pass/fail counter, no external harness).
# Spec: docs/specs/2026-06-07-anti-drift-parallelism.md

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
HELPER="$SCRIPT_DIR/plan-parallel-batch.sh"

if [[ ! -f "$HELPER" ]]; then
  echo "test-plan-parallel-batch: $HELPER not found" >&2
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

# run_json <input-file> -> sets EC + writes JSON to $tmpdir/out
run_json() {
  local input="$1"
  set +e
  NO_COLOR=1 bash "$HELPER" --json --file "$input" > "$tmpdir/out" 2>"$tmpdir/err"
  EC=$?
  set -e
}

# jq_get <jq-filter> -> echoes compact result from $tmpdir/out
jq_get() { jq -rc "$1" "$tmpdir/out" 2>/dev/null; }

# ---------- Test 1: 3 tickets, 2 share a file (THE acceptance criterion) ----------
say "Test 1: 3 tickets, 2 share scripts/autopickup-tick.sh -> parallel{301} + serialize{302,303}"
cat > "$tmpdir/t1.json" <<'EOF'
{
  "tickets": [
    { "number": 301, "title": "Add --json to status", "body": "edits scripts/status.sh only" },
    { "number": 302, "title": "Fix interval guard", "body": "edits scripts/autopickup-tick.sh" },
    { "number": 303, "title": "Add gc marker", "body": "also edits scripts/autopickup-tick.sh" }
  ]
}
EOF
run_json "$tmpdir/t1.json"
if [[ "$EC" -eq 0 ]]; then ok "exit 0"; else bad "expected 0, got $EC; err: $(cat "$tmpdir/err")"; fi
if [[ "$(jq_get '.parallel')" == "[301]" ]]; then ok "parallel == [301]"; else bad "parallel was $(jq_get '.parallel')"; fi
if [[ "$(jq_get '.serialize_groups | length')" == "1" ]]; then ok "one serialize group"; else bad "groups: $(jq_get '.serialize_groups')"; fi
if [[ "$(jq_get '.serialize_groups[0].group')" == "[302,303]" ]]; then ok "group == [302,303]"; else bad "group was $(jq_get '.serialize_groups[0].group')"; fi
if jq -e '.serialize_groups[0].shared | index("scripts/autopickup-tick.sh")' "$tmpdir/out" >/dev/null 2>&1; then ok "shared names the tick script"; else bad "shared was $(jq_get '.serialize_groups[0].shared')"; fi
if [[ "$(jq_get '.serialize_groups[0].order')" == "[302,303]" ]]; then ok "order ascending [302,303]"; else bad "order was $(jq_get '.serialize_groups[0].order')"; fi

# ---------- Test 2: all disjoint -> all parallel ----------
say "Test 2: all disjoint footprints -> all in parallel, no serialize groups"
cat > "$tmpdir/t2.json" <<'EOF'
{
  "tickets": [
    { "number": 1, "title": "a", "body": "scripts/a.sh" },
    { "number": 2, "title": "b", "body": "scripts/b.sh" },
    { "number": 3, "title": "c", "body": "scripts/c.sh" }
  ]
}
EOF
run_json "$tmpdir/t2.json"
if [[ "$EC" -eq 0 ]]; then ok "exit 0"; else bad "expected 0, got $EC"; fi
if [[ "$(jq_get '.parallel')" == "[1,2,3]" ]]; then ok "parallel == [1,2,3]"; else bad "parallel was $(jq_get '.parallel')"; fi
if [[ "$(jq_get '.serialize_groups | length')" == "0" ]]; then ok "no serialize groups"; else bad "groups: $(jq_get '.serialize_groups')"; fi

# ---------- Test 3: all overlap -> one group of 3, empty parallel ----------
say "Test 3: all 3 touch the same file -> one serialize group of 3"
cat > "$tmpdir/t3.json" <<'EOF'
{
  "tickets": [
    { "number": 10, "title": "x", "body": "CLAUDE.md" },
    { "number": 11, "title": "y", "body": "CLAUDE.md" },
    { "number": 12, "title": "z", "body": "CLAUDE.md" }
  ]
}
EOF
run_json "$tmpdir/t3.json"
if [[ "$EC" -eq 0 ]]; then ok "exit 0"; else bad "expected 0, got $EC"; fi
if [[ "$(jq_get '.parallel')" == "[]" ]]; then ok "parallel empty"; else bad "parallel was $(jq_get '.parallel')"; fi
if [[ "$(jq_get '.serialize_groups[0].group')" == "[10,11,12]" ]]; then ok "group == [10,11,12]"; else bad "group was $(jq_get '.serialize_groups[0].group')"; fi

# ---------- Test 4: explicit footprint override beats heuristic ----------
say "Test 4: explicit footprint override partitions by the override, not body text"
cat > "$tmpdir/t4.json" <<'EOF'
{
  "tickets": [
    { "number": 20, "title": "mentions scripts/shared.sh in text", "body": "scripts/shared.sh", "footprint": ["scripts/alpha.sh"] },
    { "number": 21, "title": "also mentions scripts/shared.sh", "body": "scripts/shared.sh", "footprint": ["scripts/beta.sh"] }
  ]
}
EOF
run_json "$tmpdir/t4.json"
if [[ "$EC" -eq 0 ]]; then ok "exit 0"; else bad "expected 0, got $EC"; fi
if [[ "$(jq_get '.parallel')" == "[20,21]" ]]; then ok "override -> disjoint -> parallel [20,21]"; else bad "parallel was $(jq_get '.parallel')"; fi
if [[ "$(jq_get '.footprints["20"].source')" == "override" ]]; then ok "source flagged 'override'"; else bad "source was $(jq_get '.footprints["20"].source')"; fi

# ---------- Test 5: directory-bucket overlap (prefix match) ----------
say "Test 5: 'self-test' keyword overlaps an explicit self-test/ path (prefix)"
cat > "$tmpdir/t5.json" <<'EOF'
{
  "tickets": [
    { "number": 30, "title": "improve the self-test harness", "body": "touch the self-test runner" },
    { "number": 31, "title": "edit a fixture", "body": "self-test/fixtures/foo/run.sh" }
  ]
}
EOF
run_json "$tmpdir/t5.json"
if [[ "$EC" -eq 0 ]]; then ok "exit 0"; else bad "expected 0, got $EC"; fi
if [[ "$(jq_get '.parallel')" == "[]" ]]; then ok "prefix overlap -> serialized, parallel empty"; else bad "parallel was $(jq_get '.parallel')"; fi
if [[ "$(jq_get '.serialize_groups[0].group')" == "[30,31]" ]]; then ok "group == [30,31]"; else bad "group was $(jq_get '.serialize_groups[0].group')"; fi

# ---------- Test 6: unknown footprint -> surfaced, not silently parallelized ----------
say "Test 6: a ticket with no path/keyword -> 'unknown' list + warning (not parallel)"
cat > "$tmpdir/t6.json" <<'EOF'
{
  "tickets": [
    { "number": 40, "title": "improve performance", "body": "make it faster somehow" },
    { "number": 41, "title": "edit a script", "body": "scripts/known.sh" }
  ]
}
EOF
run_json "$tmpdir/t6.json"
if [[ "$EC" -eq 0 ]]; then ok "exit 0"; else bad "expected 0, got $EC"; fi
if jq -e '.unknown | index(40)' "$tmpdir/out" >/dev/null 2>&1; then ok "40 in unknown list"; else bad "unknown was $(jq_get '.unknown')"; fi
if jq -e '.parallel | index(40)' "$tmpdir/out" >/dev/null 2>&1; then bad "40 should NOT be auto-parallelized"; else ok "40 not silently parallelized"; fi
if [[ "$(jq_get '.parallel')" == "[41]" ]]; then ok "known disjoint 41 still parallel"; else bad "parallel was $(jq_get '.parallel')"; fi

# ---------- Test 7: determinism (byte-identical JSON modulo generated_at) ----------
say "Test 7: same input twice -> byte-identical JSON (ignoring generated_at)"
run_json "$tmpdir/t1.json"; jq 'del(.generated_at)' "$tmpdir/out" > "$tmpdir/det1.json"
run_json "$tmpdir/t1.json"; jq 'del(.generated_at)' "$tmpdir/out" > "$tmpdir/det2.json"
if diff -q "$tmpdir/det1.json" "$tmpdir/det2.json" >/dev/null; then ok "deterministic output"; else bad "output differs across runs: $(diff "$tmpdir/det1.json" "$tmpdir/det2.json")"; fi

# ---------- Test 8: usage errors ----------
say "Test 8: malformed JSON -> exit 2; empty batch -> exit 2; --help -> exit 0"
echo "not json {" > "$tmpdir/bad.json"
run_json "$tmpdir/bad.json"
if [[ "$EC" -eq 2 ]]; then ok "malformed JSON -> exit 2"; else bad "expected 2, got $EC"; fi
echo '{"tickets":[]}' > "$tmpdir/empty.json"
run_json "$tmpdir/empty.json"
if [[ "$EC" -eq 2 ]]; then ok "empty batch -> exit 2"; else bad "expected 2, got $EC"; fi
set +e
NO_COLOR=1 bash "$HELPER" --help >/dev/null 2>&1; HC=$?
set -e
if [[ "$HC" -eq 0 ]]; then ok "--help -> exit 0"; else bad "expected 0, got $HC"; fi

# ---------- Test 9: single ticket -> trivially parallel ----------
say "Test 9: single ticket -> one-element parallel, no groups"
cat > "$tmpdir/t9.json" <<'EOF'
{ "tickets": [ { "number": 50, "title": "solo", "body": "scripts/solo.sh" } ] }
EOF
run_json "$tmpdir/t9.json"
if [[ "$EC" -eq 0 ]]; then ok "exit 0"; else bad "expected 0, got $EC"; fi
if [[ "$(jq_get '.parallel')" == "[50]" ]]; then ok "parallel == [50]"; else bad "parallel was $(jq_get '.parallel')"; fi
if [[ "$(jq_get '.serialize_groups | length')" == "0" ]]; then ok "no groups"; else bad "groups: $(jq_get '.serialize_groups')"; fi

# ---------- Test 10: human (non-JSON) report renders the three sections ----------
say "Test 10: human report mentions Parallel / Serialize / recommendation"
set +e
NO_COLOR=1 bash "$HELPER" --file "$tmpdir/t1.json" > "$tmpdir/human" 2>&1
HEC=$?
set -e
if [[ "$HEC" -eq 0 ]]; then ok "human report exit 0"; else bad "expected 0, got $HEC"; fi
if grep -qiE "parallel" "$tmpdir/human"; then ok "report mentions parallel"; else bad "no 'parallel' in report"; fi
if grep -qiE "serialize" "$tmpdir/human"; then ok "report mentions serialize"; else bad "no 'serialize' in report"; fi
if grep -qiE "302.*303|303.*302" "$tmpdir/human"; then ok "report names the serialized pair"; else bad "report did not name 302/303"; fi

# -----------------------------------------------------------------------------
printf "\n${C_BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${C_RESET}\n"
printf "${C_BOLD}%d passed · %d failed${C_RESET}\n" "$passed" "$failed"
[[ "$failed" -gt 0 ]] && exit 1
exit 0

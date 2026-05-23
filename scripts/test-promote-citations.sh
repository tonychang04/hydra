#!/usr/bin/env bash
#
# test-promote-citations.sh — regression test for scripts/promote-citations.sh.
#
# Exercises (dry-run paths only — no gh or git mutation):
#   - 3 citations across 3 distinct tickets → one ELIGIBLE line + one
#     "would open PR" line (AC #6 from ticket #145).
#   - 3 citations but only 2 distinct tickets → zero ELIGIBLE lines
#     (dedup-applied selection).
#   - --only <key> filters to one entry (used by tests).
#   - Already-promoted skill → action=would update.
#   - Missing citations file → exit 0, silent (nothing to do).
#   - Usage errors exit 2.
#   - Cross-cutting memory files (escalation-faq.md etc.) are skipped with
#     a warning (non-fatal).
#   - Slug collision: two entries whose quote text matches but whose
#     source files differ get distinct slugs.
#
# Style: matches scripts/test-check-claude-md-size.sh — bash, colored
# output, pass/fail counter, no external test harness.
#
# Spec: docs/specs/2026-04-17-skill-promotion-automation.md

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROMOTE="$SCRIPT_DIR/promote-citations.sh"

if [[ ! -x "$PROMOTE" ]]; then
  echo "test-promote-citations: $PROMOTE not found or not executable" >&2
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

say()  { printf "\n${C_BOLD}▸ %s${C_RESET}\n" "$*"; }
ok()   { printf "  ${C_GREEN}✓${C_RESET} %s\n" "$*"; passed=$((passed + 1)); }
bad()  { printf "  ${C_RED}✗${C_RESET} %s\n" "$*"; failed=$((failed + 1)); }

# --- Fixture builder -------------------------------------------------------

# Make a minimal state_dir + memory_dir + repos.json pointing at a real
# local_path under tmpdir that we own. Leaves the fixture repo as a bare
# directory (not a git repo) — dry-run doesn't touch git.
mk_fixture() {
  local root="$1"
  mkdir -p "$root/state" "$root/memory" "$root/target-repo/.claude/skills"

  # Minimal repos.json with one enabled repo whose slug matches "hydra".
  cat > "$root/state/repos.json" <<EOF
{
  "repos": [
    {
      "owner": "tonychang04",
      "name": "hydra",
      "local_path": "$root/target-repo",
      "enabled": true
    }
  ]
}
EOF

  # Minimal learnings-hydra.md memory file — must contain the quote verbatim
  # so extract_context has something to grep.
  cat > "$root/memory/learnings-hydra.md" <<'EOF'
---
name: hydra learnings
description: test fixture
type: repo-learnings
---

## Known gotchas

- rescue stale index lock — if scripts/rescue-worker.sh exits 4, check for
  .git/index.lock left behind by a crashed worker. Remove it and retry the
  rescue probe. See docs/specs/2026-04-17-rescue-worker-index-lock.md.
- another entry about a different topic — just filler so grep doesn't hit
  a single-line file.
EOF
}

# Write a citations.json with specified entries. Args: file_path, then
# alternating key/count/tickets_csv triples.
write_citations() {
  local path="$1"
  shift
  local tmp
  tmp="$(mktemp)"
  echo '{"citations":{}}' > "$tmp"
  while [[ $# -ge 3 ]]; do
    local key="$1" count="$2" tickets="$3"
    shift 3
    local tickets_json
    tickets_json="$(printf '%s' "$tickets" \
      | awk 'BEGIN{RS=","; print "["} NR>1{print ","} {printf "\"%s\"", $0} END{print "]"}' \
      | tr -d '\n')"
    # Determine promotion_threshold_reached conservatively
    # (test doesn't rely on this field; script computes it).
    local distinct
    distinct="$(printf '%s' "$tickets" | tr ',' '\n' | sort -u | wc -l | tr -d ' ')"
    local ptr="false"
    if [[ "$count" -ge 3 ]] && [[ "$distinct" -ge 3 ]]; then ptr="true"; fi
    jq --arg k "$key" --argjson c "$count" \
       --argjson t "$tickets_json" --argjson p "$ptr" '
      .citations[$k] = {
        count: $c,
        last_cited: "2026-04-17",
        tickets: $t,
        promotion_threshold_reached: $p
      }
    ' "$tmp" > "$tmp.new" && mv "$tmp.new" "$tmp"
  done
  mv "$tmp" "$path"
}

# Run the script in dry-run with the given state/memory dirs. Redirects
# stdout and stderr into separate capture files.
run_dry() {
  local root="$1"
  local stdout="$2"
  local stderr="$3"
  shift 3
  set +e
  NO_COLOR=1 "$PROMOTE" \
    --state-dir "$root/state" \
    --memory-dir "$root/memory" \
    --repos-file "$root/state/repos.json" \
    --now "2026-04-17" \
    --dry-run \
    "$@" \
    > "$stdout" 2> "$stderr"
  local ec=$?
  set -e
  echo "$ec"
}

# --- Test 1: 3 citations, 3 distinct tickets → eligible ------------------
say "Test 1: 3 cites across 3 distinct tickets → one ELIGIBLE + one 'would open PR'"
root1="$tmpdir/t1"
mk_fixture "$root1"
write_citations "$root1/state/memory-citations.json" \
  'learnings-hydra.md#"rescue stale index lock"' 3 '#50,#61,#64'

ec=$(run_dry "$root1" "$tmpdir/t1.out" "$tmpdir/t1.err")
if [[ "$ec" -eq 0 ]]; then
  ok "exit 0 as expected"
else
  bad "expected exit 0, got $ec; stderr:"
  sed 's/^/    /' "$tmpdir/t1.err"
fi

eligible_count=$(grep -c '^ELIGIBLE' "$tmpdir/t1.out" || true)
if [[ "$eligible_count" -eq 1 ]]; then
  ok "exactly 1 ELIGIBLE line"
else
  bad "expected 1 ELIGIBLE line, got $eligible_count; stdout:"
  sed 's/^/    /' "$tmpdir/t1.out"
fi

pr_count=$(grep -c '^would open PR' "$tmpdir/t1.out" || true)
if [[ "$pr_count" -eq 1 ]]; then
  ok "exactly 1 'would open PR' line"
else
  bad "expected 1 'would open PR' line, got $pr_count"
fi

# Also: the action should be "would create" (skill doesn't exist yet).
if grep -q 'action=would create' "$tmpdir/t1.out"; then
  ok "action=would create (skill file does not pre-exist)"
else
  bad "expected action=would create; stdout:"
  sed 's/^/    /' "$tmpdir/t1.out"
fi

# The target repo resolution should pick up tonychang04/hydra.
if grep -q 'repo=tonychang04/hydra' "$tmpdir/t1.out"; then
  ok "target repo resolved to tonychang04/hydra"
else
  bad "expected target repo tonychang04/hydra; stdout:"
  sed 's/^/    /' "$tmpdir/t1.out"
fi

# --- Test 2: 3 count but only 2 distinct tickets → NOT eligible ----------
say "Test 2: count=3 but distinct tickets=2 → zero ELIGIBLE lines"
root2="$tmpdir/t2"
mk_fixture "$root2"
write_citations "$root2/state/memory-citations.json" \
  'learnings-hydra.md#"rescue stale index lock"' 3 '#50,#50,#61'

ec=$(run_dry "$root2" "$tmpdir/t2.out" "$tmpdir/t2.err")
if [[ "$ec" -eq 0 ]]; then
  ok "exit 0 (empty selection is success)"
else
  bad "expected exit 0, got $ec"
fi

if ! grep -q '^ELIGIBLE' "$tmpdir/t2.out"; then
  ok "no ELIGIBLE lines (distinct-tickets gate held)"
else
  bad "expected zero ELIGIBLE lines; stdout:"
  sed 's/^/    /' "$tmpdir/t2.out"
fi

# --- Test 3: --only filter ------------------------------------------------
say "Test 3: --only filters to one specific key"
root3="$tmpdir/t3"
mk_fixture "$root3"
write_citations "$root3/state/memory-citations.json" \
  'learnings-hydra.md#"rescue stale index lock"' 3 '#1,#2,#3' \
  'learnings-hydra.md#"another entry"' 4 '#4,#5,#6,#7'

ec=$(run_dry "$root3" "$tmpdir/t3.out" "$tmpdir/t3.err" \
     --only 'learnings-hydra.md#"another entry"')
if [[ "$ec" -eq 0 ]]; then
  ok "exit 0 as expected"
else
  bad "expected exit 0, got $ec"
fi

eligible_count=$(grep -c '^ELIGIBLE' "$tmpdir/t3.out" || true)
if [[ "$eligible_count" -eq 1 ]]; then
  ok "exactly 1 ELIGIBLE line under --only filter"
else
  bad "expected 1 ELIGIBLE line, got $eligible_count"
fi
if grep -q 'another entry' "$tmpdir/t3.out"; then
  ok "the filtered key was selected"
else
  bad "expected 'another entry' in stdout; stdout:"
  sed 's/^/    /' "$tmpdir/t3.out"
fi

# --- Test 4: already-promoted skill → action=would update ----------------
say "Test 4: existing SKILL.md → action=would update"
root4="$tmpdir/t4"
mk_fixture "$root4"
write_citations "$root4/state/memory-citations.json" \
  'learnings-hydra.md#"rescue stale index lock"' 3 '#1,#2,#3'
# Pre-create the SKILL.md at the expected path. The slug is
# learnings-hydra-rescue-stale-index-lock per the script's naming rule.
mkdir -p "$root4/target-repo/.claude/skills/learnings-hydra-rescue-stale-index-lock"
cat > "$root4/target-repo/.claude/skills/learnings-hydra-rescue-stale-index-lock/SKILL.md" <<EOF
---
name: learnings-hydra-rescue-stale-index-lock
description: pre-existing
---
# stale skill body
EOF

ec=$(run_dry "$root4" "$tmpdir/t4.out" "$tmpdir/t4.err")
if [[ "$ec" -eq 0 ]]; then
  ok "exit 0 as expected"
else
  bad "expected exit 0, got $ec"
fi
if grep -q 'action=would update' "$tmpdir/t4.out"; then
  ok "action=would update (skill exists)"
else
  bad "expected action=would update; stdout:"
  sed 's/^/    /' "$tmpdir/t4.out"
fi

# --- Test 5: missing citations file → exit 0, silent --------------------
say "Test 5: no citations file → exit 0 (nothing to do)"
root5="$tmpdir/t5"
mkdir -p "$root5/state" "$root5/memory"
# No citations file written.
ec=$(run_dry "$root5" "$tmpdir/t5.out" "$tmpdir/t5.err")
if [[ "$ec" -eq 0 ]]; then
  ok "exit 0 when citations file is missing"
else
  bad "expected exit 0, got $ec"
fi
if [[ -s "$tmpdir/t5.out" ]]; then
  bad "expected empty stdout; got:"
  sed 's/^/    /' "$tmpdir/t5.out"
else
  ok "stdout is empty (silent no-op)"
fi

# --- Test 6: usage errors → exit 2 --------------------------------------
say "Test 6: unknown flag → exit 2"
set +e
NO_COLOR=1 "$PROMOTE" --bogus-flag > "$tmpdir/t6.out" 2> "$tmpdir/t6.err"
ec=$?
set -e
if [[ "$ec" -eq 2 ]]; then
  ok "exit 2 on unknown flag"
else
  bad "expected exit 2, got $ec"
fi

# --- Test 7: cross-cutting memory files are skipped with a warning ------
say "Test 7: escalation-faq.md citation → warned + skipped"
root7="$tmpdir/t7"
mk_fixture "$root7"
write_citations "$root7/state/memory-citations.json" \
  'escalation-faq.md#"labels on PRs always use REST"' 3 '#10,#11,#12'

ec=$(run_dry "$root7" "$tmpdir/t7.out" "$tmpdir/t7.err")
if [[ "$ec" -eq 0 ]]; then
  ok "exit 0 (cross-cutting skip is not an error)"
else
  bad "expected exit 0, got $ec"
fi
if grep -q 'cross-cutting or unmatched' "$tmpdir/t7.err"; then
  ok "cross-cutting warning printed to stderr"
else
  bad "expected cross-cutting warning; stderr:"
  sed 's/^/    /' "$tmpdir/t7.err"
fi
if grep -q '^ELIGIBLE' "$tmpdir/t7.out"; then
  bad "cross-cutting entry was NOT supposed to emit ELIGIBLE"
else
  ok "no ELIGIBLE line for cross-cutting entry"
fi

# --- Test 8: slug disambiguation ----------------------------------------
say "Test 8: two entries with same quote but different source files → distinct slugs"
# Only one of them can be matched to a repo; use two learnings-*.md files.
root8="$tmpdir/t8"
mkdir -p "$root8/state" "$root8/memory" "$root8/repo-a" "$root8/repo-b"
cat > "$root8/state/repos.json" <<EOF
{
  "repos": [
    {"owner": "o", "name": "alpha", "local_path": "$root8/repo-a", "enabled": true},
    {"owner": "o", "name": "beta",  "local_path": "$root8/repo-b", "enabled": true}
  ]
}
EOF
cat > "$root8/memory/learnings-alpha.md" <<'EOF'
---
name: alpha
description: fixture
type: repo-learnings
---

## Known gotchas

- shared quote — same wording in both memory files to test disambiguation.
EOF
cp "$root8/memory/learnings-alpha.md" "$root8/memory/learnings-beta.md"

write_citations "$root8/state/memory-citations.json" \
  'learnings-alpha.md#"shared quote"' 3 '#1,#2,#3' \
  'learnings-beta.md#"shared quote"' 3 '#4,#5,#6'

ec=$(run_dry "$root8" "$tmpdir/t8.out" "$tmpdir/t8.err")
if [[ "$ec" -eq 0 ]]; then
  ok "exit 0 as expected"
else
  bad "expected exit 0, got $ec"
fi

# Both slugs must appear distinct.
if grep -q 'skill=\.claude/skills/learnings-alpha-shared-quote' "$tmpdir/t8.out" \
   && grep -q 'skill=\.claude/skills/learnings-beta-shared-quote'  "$tmpdir/t8.out"; then
  ok "distinct slugs per source file (learnings-alpha-* vs learnings-beta-*)"
else
  bad "expected distinct slugs; stdout:"
  sed 's/^/    /' "$tmpdir/t8.out"
fi

# --- Test 9: --check-due once/day guard ----------------------------------
# Helper: run --check-due against a state dir, return the exit code.
run_check_due() {
  local state_dir="$1" now="$2"
  set +e
  NO_COLOR=1 "$PROMOTE" --check-due --state-dir "$state_dir" --now "$now" \
    > /dev/null 2>&1
  local ec=$?
  set -e
  echo "$ec"
}

# Helper: write a minimal autopickup.json with a given last_promotion_run.
# Pass the literal word "null" to emit a JSON null, or "absent" to omit the key.
write_autopickup() {
  local path="$1" last_run="$2"
  if [[ "$last_run" == "absent" ]]; then
    cat > "$path" <<'EOF'
{"enabled": false, "interval_min": 30, "last_run": null, "last_picked_count": 0, "consecutive_rate_limit_hits": 0}
EOF
  elif [[ "$last_run" == "null" ]]; then
    cat > "$path" <<'EOF'
{"enabled": false, "interval_min": 30, "last_run": null, "last_picked_count": 0, "consecutive_rate_limit_hits": 0, "last_promotion_run": null}
EOF
  else
    jq -n --arg lr "$last_run" '{enabled: false, interval_min: 30, last_run: null, last_picked_count: 0, consecutive_rate_limit_hits: 0, last_promotion_run: $lr}' > "$path"
  fi
}

say "Test 9: --check-due is DUE (exit 0) when last_promotion_run is null"
root9="$tmpdir/t9"
mkdir -p "$root9/state"
write_autopickup "$root9/state/autopickup.json" null
ec=$(run_check_due "$root9/state" "2026-05-21")
if [[ "$ec" -eq 0 ]]; then
  ok "exit 0 (due) when last_promotion_run is null"
else
  bad "expected exit 0 (due), got $ec"
fi

say "Test 10: --check-due is DUE (exit 0) when last_promotion_run is a past date"
root10="$tmpdir/t10"
mkdir -p "$root10/state"
write_autopickup "$root10/state/autopickup.json" "2026-05-20"
ec=$(run_check_due "$root10/state" "2026-05-21")
if [[ "$ec" -eq 0 ]]; then
  ok "exit 0 (due) when last_promotion_run is yesterday"
else
  bad "expected exit 0 (due), got $ec"
fi

say "Test 11: --check-due is NOT DUE (exit 10) when last_promotion_run == today"
root11="$tmpdir/t11"
mkdir -p "$root11/state"
write_autopickup "$root11/state/autopickup.json" "2026-05-21"
ec=$(run_check_due "$root11/state" "2026-05-21")
if [[ "$ec" -eq 10 ]]; then
  ok "exit 10 (not due) when already promoted today"
else
  bad "expected exit 10 (not due), got $ec"
fi

say "Test 12: --check-due is DUE (exit 0) when autopickup.json is missing"
root12="$tmpdir/t12"
mkdir -p "$root12/state"
# No autopickup.json — fresh install has never run promotion.
ec=$(run_check_due "$root12/state" "2026-05-21")
if [[ "$ec" -eq 0 ]]; then
  ok "exit 0 (due) when autopickup.json is absent (fresh install)"
else
  bad "expected exit 0 (due), got $ec"
fi

say "Test 13: --check-due is DUE (exit 0) when last_promotion_run key absent"
root13="$tmpdir/t13"
mkdir -p "$root13/state"
write_autopickup "$root13/state/autopickup.json" absent
ec=$(run_check_due "$root13/state" "2026-05-21")
if [[ "$ec" -eq 0 ]]; then
  ok "exit 0 (due) when last_promotion_run key is absent"
else
  bad "expected exit 0 (due), got $ec"
fi

# --- Test 14: --greeting-count sums per-repo PR counts -------------------
say "Test 14: --greeting-count sums two repos via HYDRA_PROMOTION_COUNT_CMD"
root14="$tmpdir/t14"
mkdir -p "$root14/state"
cat > "$root14/state/repos.json" <<'EOF'
{
  "repos": [
    {"owner": "o", "name": "alpha", "local_path": "/tmp/a", "enabled": true},
    {"owner": "o", "name": "beta",  "local_path": "/tmp/b", "enabled": true}
  ]
}
EOF
set +e
out=$(HYDRA_PROMOTION_COUNT_CMD='echo 1' NO_COLOR=1 "$PROMOTE" \
  --greeting-count --repos-file "$root14/state/repos.json" 2>/dev/null)
ec=$?
set -e
if [[ "$ec" -eq 0 ]]; then
  ok "exit 0 as expected"
else
  bad "expected exit 0, got $ec"
fi
if [[ "$out" == "2" ]]; then
  ok "summed two repos × 1 PR each → 2"
else
  bad "expected '2', got '$out'"
fi

say "Test 15: --greeting-count prints 0 when no promotion PRs"
set +e
out=$(HYDRA_PROMOTION_COUNT_CMD='echo 0' NO_COLOR=1 "$PROMOTE" \
  --greeting-count --repos-file "$root14/state/repos.json" 2>/dev/null)
ec=$?
set -e
if [[ "$ec" -eq 0 && "$out" == "0" ]]; then
  ok "prints 0 when no promotion PRs (greeting stays silent)"
else
  bad "expected exit 0 and '0', got exit $ec out '$out'"
fi

say "Test 16: --greeting-count prints 0 when repos.json missing (best-effort)"
set +e
out=$(NO_COLOR=1 "$PROMOTE" --greeting-count \
  --repos-file "$tmpdir/does-not-exist.json" 2>/dev/null)
ec=$?
set -e
if [[ "$ec" -eq 0 && "$out" == "0" ]]; then
  ok "prints 0 when repos.json missing (never crashes the greeting)"
else
  bad "expected exit 0 and '0', got exit $ec out '$out'"
fi

say "Test 17: --greeting-count skips disabled repos"
root17="$tmpdir/t17"
mkdir -p "$root17/state"
cat > "$root17/state/repos.json" <<'EOF'
{
  "repos": [
    {"owner": "o", "name": "alpha", "local_path": "/tmp/a", "enabled": true},
    {"owner": "o", "name": "beta",  "local_path": "/tmp/b", "enabled": false}
  ]
}
EOF
set +e
out=$(HYDRA_PROMOTION_COUNT_CMD='echo 3' NO_COLOR=1 "$PROMOTE" \
  --greeting-count --repos-file "$root17/state/repos.json" 2>/dev/null)
ec=$?
set -e
if [[ "$ec" -eq 0 && "$out" == "3" ]]; then
  ok "counted only the 1 enabled repo (3), skipped the disabled one"
else
  bad "expected exit 0 and '3', got exit $ec out '$out'"
fi

# --- Test 18: heredoc hardening — inputs are literal data, never code -----
# Invariant under test (#166): build_skill_body treats $quote / $description /
# $context as literal data — command substitution and backticks pass through
# verbatim and are never executed. (Note: bash heredoc expansion is already
# single-pass so the pre-#166 unquoted heredocs weren't exploitable via data
# values; this test locks down the invariant for the quoted-template rewrite
# and guards against a future regression that puts a literal $(...) in the
# template body.) We write the harness to a temp file rather than inlining a
# backtick-containing $() here, which would trip the bash parser.
say "Test 18: build_skill_body renders \$(...) / backticks as literal (no execution)"
pwned="$tmpdir/PWNED_marker"
rm -f "$pwned"
harness="$tmpdir/inject-harness.sh"
inject_out="$tmpdir/inject.out"
cat > "$harness" <<'HARNESS'
set -euo pipefail
PROMOTE="$1"
PWNED="$2"
CITATIONS_START="<!-- hydra:citations-start -->"
CITATIONS_END="<!-- hydra:citations-end -->"
# Pull build_skill_body's definition out of the script under test.
eval "$(awk '/^build_skill_body\(\) \{/{p=1} p{print} p&&/^\}$/{exit}' "$PROMOTE")"
# Malicious inputs: command substitution + backticks. Built without inlining
# raw backticks into a $() context.
bt='`'
evil="boom \$(touch $PWNED) and ${bt}touch $PWNED${bt}"
build_skill_body "s" "d \$(touch $PWNED)" "$evil" "learnings-hydra.md" "c" "cites"
HARNESS
set +e
bash "$harness" "$PROMOTE" "$pwned" > "$inject_out" 2>/dev/null
set -e
if [[ -e "$pwned" ]]; then
  bad "injection EXECUTED — marker file was created (hardening regressed)"
  rm -f "$pwned"
else
  ok "no command executed (marker file absent)"
fi
if grep -qF 'boom $(touch' "$inject_out"; then
  ok "command substitution rendered as literal text"
else
  bad "evil quote not rendered literally; output:"
  sed 's/^/    /' "$inject_out"
fi
if grep -qF '`touch' "$inject_out"; then
  ok "backticks rendered as literal text"
else
  bad "backticks not rendered literally"
fi

# --- Summary -------------------------------------------------------------

echo ""
echo "${C_BOLD}Total: $((passed + failed))  passed: ${C_GREEN}${passed}${C_RESET}  failed: ${C_RED}${failed}${C_RESET}"
if [[ "$failed" -gt 0 ]]; then
  exit 1
fi
exit 0

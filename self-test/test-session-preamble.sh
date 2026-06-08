#!/usr/bin/env bash
#
# test-session-preamble.sh — self-test for the dynamic session-preamble scripts
# (scripts/hydra-memory-search.sh, scripts/hydra-recent-failures.sh).
#
# learnings-*.md and logs/*.json are gitignored runtime data, so this test
# builds SYNTHETIC tmp dirs and points the scripts at them via
# --memory-dir / --logs-dir. Self-contained; no committed fixtures.
#
# Exit 0 = all assertions pass. Spec: docs/specs/2026-06-08-dynamic-session-preamble.md

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"
SEARCH="$ROOT_DIR/scripts/hydra-memory-search.sh"
FAILURES="$ROOT_DIR/scripts/hydra-recent-failures.sh"

if [[ -t 1 ]] && [[ "${NO_COLOR:-}" != "1" ]]; then
  C_GREEN=$'\033[32m'; C_RED=$'\033[31m'; C_RESET=$'\033[0m'
else
  C_GREEN=""; C_RED=""; C_RESET=""
fi

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); echo "${C_GREEN}PASS${C_RESET}: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "${C_RED}FAIL${C_RESET}: $1"; }

TMP="$(mktemp -d 2>/dev/null || mktemp -d -t hydra-preamble)"
cleanup() { rm -rf "$TMP" 2>/dev/null || true; }
trap cleanup EXIT INT TERM

MEM="$TMP/memory"
LOGS="$TMP/logs"
EMPTY="$TMP/empty"
mkdir -p "$MEM" "$LOGS" "$EMPTY"

# --- synthetic learnings (rescue mentioned 3x in foo, 1x in bar) --------------
cat > "$MEM/learnings-foo.md" <<'EOF'
# foo learnings
- rescue stale index lock when probing
- a second rescue note about rescue flows
- unrelated note about caching
EOF
cat > "$MEM/learnings-bar.md" <<'EOF'
# bar learnings
- one rescue mention here
- unrelated note
EOF
# example placeholder must be IGNORED by the search
cat > "$MEM/learnings-baz.example.md" <<'EOF'
# baz example — rescue rescue rescue rescue (should be skipped)
EOF

# --- synthetic logs -----------------------------------------------------------
# repo alpha: two flaky-tool-retry observations (repeated → should surface)
cat > "$LOGS/1001.json" <<'EOF'
{ "ticket": 1001, "repo": "tony/alpha", "result": "flaky-tool-retry" }
EOF
cat > "$LOGS/1002.json" <<'EOF'
{ "ticket": 1002, "repo": "tony/alpha",
  "surprises": ["worker hit flaky-tool-retry on auth tool"] }
EOF
# repo beta: one rescue (below threshold → should NOT surface at --min 2)
cat > "$LOGS/1003.json" <<'EOF'
{ "ticket": 1003, "repo": "tony/beta", "rescued": true,
  "rescue_commit": "abc123" }
EOF
# repo gamma: clean PR with FALSE/NULL rescue markers present. Key presence
# alone must NOT classify these as rescue (codex #274 P2). Two of them, so if
# the guard regressed they would surface as a 2× rescue group — a strong signal.
cat > "$LOGS/1004.json" <<'EOF'
{ "ticket": 1004, "repo": "tony/gamma", "result": "pr-open-draft",
  "rescued": false, "rescue_commit": null }
EOF
cat > "$LOGS/1006.json" <<'EOF'
{ "ticket": 1006, "repo": "tony/gamma", "result": "pr-opened",
  "rescued": false }
EOF
# repo delta: two string-valued bug_class observations (codex #274 P2) — must
# classify as "bug", not be dropped because the value isn't literal true/1.
cat > "$LOGS/1007.json" <<'EOF'
{ "ticket": 1007, "repo": "tony/delta", "bug_class": "product" }
EOF
cat > "$LOGS/1008.json" <<'EOF'
{ "ticket": 1008, "repo": "tony/delta", "is_bug": "test" }
EOF
# malformed JSON: must be skipped silently, not crash
printf '{ this is not json' > "$LOGS/1005.json"

# =============================================================================
# Assertion 1: both scripts print usage on --help, exit 0
# =============================================================================
if out="$(bash "$SEARCH" --help 2>&1)" && printf '%s' "$out" | grep -q 'Usage: hydra-memory-search.sh'; then
  pass "hydra-memory-search.sh --help prints usage"
else
  fail "hydra-memory-search.sh --help"
fi
if out="$(bash "$FAILURES" --help 2>&1)" && printf '%s' "$out" | grep -q 'Usage: hydra-recent-failures.sh'; then
  pass "hydra-recent-failures.sh --help prints usage"
else
  fail "hydra-recent-failures.sh --help"
fi

# =============================================================================
# Assertion 2: memory-search ranks the higher-match file first, valid JSON
# =============================================================================
if json="$(bash "$SEARCH" rescue --memory-dir "$MEM" --json 2>/dev/null)" \
   && printf '%s' "$json" | jq -e . >/dev/null 2>&1; then
  top_repo="$(printf '%s' "$json" | jq -r '.results[0].repo // ""')"
  top_matches="$(printf '%s' "$json" | jq -r '.results[0].matches // 0')"
  n_results="$(printf '%s' "$json" | jq -r '.results | length')"
  has_example="$(printf '%s' "$json" | jq -r '[.results[].file] | any(. | test("example"))')"
  # foo mentions "rescue" 3 times (incl. twice on one line) → OCCURRENCE count
  # must be 3, not the 2 a line-count (grep -c) would give. This locks in the
  # codex #274 P2 occurrence-vs-line fix.
  if [[ "$top_repo" == "foo" ]] && [[ "$top_matches" -eq 3 ]] && [[ "$n_results" -eq 2 ]] && [[ "$has_example" == "false" ]]; then
    pass "memory-search ranks foo first, occurrence-count=3 (not line-count 2), example skipped"
  else
    fail "memory-search ranking (top_repo=$top_repo matches=$top_matches n=$n_results example=$has_example)"
  fi
else
  fail "memory-search --json not valid JSON"
fi

# =============================================================================
# Assertion 3: non-matching query → exit 0, empty results
# =============================================================================
if json="$(bash "$SEARCH" zzznomatchzzz --memory-dir "$MEM" --json 2>/dev/null)"; then
  if [[ "$(printf '%s' "$json" | jq -r '.results | length')" -eq 0 ]]; then
    pass "memory-search non-matching query → empty results, exit 0"
  else
    fail "memory-search non-matching query should be empty"
  fi
else
  fail "memory-search non-matching query should exit 0"
fi

# Assertion 3b: empty memory dir → exit 0, empty results
if json="$(bash "$SEARCH" rescue --memory-dir "$EMPTY" --json 2>/dev/null)"; then
  if [[ "$(printf '%s' "$json" | jq -r '.results | length')" -eq 0 ]]; then
    pass "memory-search empty dir → empty results, exit 0"
  else
    fail "memory-search empty dir should be empty"
  fi
else
  fail "memory-search empty dir should exit 0"
fi

# =============================================================================
# Assertion 4: recent-failures finds repeated (repo,type) group, valid JSON
# =============================================================================
if json="$(bash "$FAILURES" --logs-dir "$LOGS" --min 2 --json 2>/dev/null)" \
   && printf '%s' "$json" | jq -e . >/dev/null 2>&1; then
  alpha_flaky="$(printf '%s' "$json" | jq -r '[.patterns[] | select(.repo=="tony/alpha" and .failure_type=="flaky")] | length')"
  alpha_count="$(printf '%s' "$json" | jq -r '[.patterns[] | select(.repo=="tony/alpha" and .failure_type=="flaky")][0].count // 0')"
  beta_present="$(printf '%s' "$json" | jq -r '[.patterns[] | select(.repo=="tony/beta")] | length')"
  gamma_present="$(printf '%s' "$json" | jq -r '[.patterns[] | select(.repo=="tony/gamma")] | length')"
  if [[ "$alpha_flaky" -eq 1 ]] && [[ "$alpha_count" -eq 2 ]] && [[ "$beta_present" -eq 0 ]] && [[ "$gamma_present" -eq 0 ]]; then
    pass "recent-failures surfaces alpha 2× flaky; excludes beta (1×) and clean gamma"
  else
    fail "recent-failures grouping (alpha_flaky=$alpha_flaky count=$alpha_count beta=$beta_present gamma=$gamma_present)"
  fi
else
  fail "recent-failures --json not valid JSON"
fi

# Assertion 4d: gamma has "rescued": false / "rescue_commit": null on TWO logs.
# Key presence must NOT classify as rescue (codex #274 P2) — gamma must stay
# absent even at --min 2 (where a false 2× rescue group would otherwise show).
if json="$(bash "$FAILURES" --logs-dir "$LOGS" --min 2 --json 2>/dev/null)"; then
  gamma_rescue="$(printf '%s' "$json" | jq -r '[.patterns[] | select(.repo=="tony/gamma")] | length')"
  if [[ "$gamma_rescue" -eq 0 ]]; then
    pass "recent-failures ignores falsey rescue markers (rescued:false / rescue_commit:null)"
  else
    fail "recent-failures should NOT classify falsey rescue markers as rescue (got gamma groups: $gamma_rescue)"
  fi
fi

# Assertion 4e: delta has two STRING-valued bug signals (bug_class:"product",
# is_bug:"test"). Must classify as bug, not be dropped (codex #274 P2).
if json="$(bash "$FAILURES" --logs-dir "$LOGS" --min 2 --json 2>/dev/null)"; then
  delta_bug="$(printf '%s' "$json" | jq -r '[.patterns[] | select(.repo=="tony/delta" and .failure_type=="bug")][0].count // 0')"
  if [[ "$delta_bug" -eq 2 ]]; then
    pass "recent-failures classifies string-valued bug_class/is_bug as bug (2× delta)"
  else
    fail "recent-failures should surface delta 2× bug (got count: $delta_bug)"
  fi
fi

# Assertion 4b: tickets are captured for the alpha group
if json="$(bash "$FAILURES" --logs-dir "$LOGS" --min 2 --json 2>/dev/null)"; then
  has_tickets="$(printf '%s' "$json" | jq -r '[.patterns[] | select(.repo=="tony/alpha")][0].tickets | (index("1001") != null) and (index("1002") != null)')"
  if [[ "$has_tickets" == "true" ]]; then
    pass "recent-failures captures alpha tickets 1001 + 1002"
  else
    fail "recent-failures should capture tickets 1001+1002 (got: $has_tickets)"
  fi
fi

# Assertion 4c: with --min 1, beta's single rescue surfaces
if json="$(bash "$FAILURES" --logs-dir "$LOGS" --min 1 --json 2>/dev/null)"; then
  beta_rescue="$(printf '%s' "$json" | jq -r '[.patterns[] | select(.repo=="tony/beta" and .failure_type=="rescue")] | length')"
  if [[ "$beta_rescue" -eq 1 ]]; then
    pass "recent-failures --min 1 surfaces beta rescue (rescue-key signal works)"
  else
    fail "recent-failures --min 1 should surface beta rescue (got: $beta_rescue)"
  fi
fi

# =============================================================================
# Assertion 5: empty logs dir → exit 0, empty patterns
# =============================================================================
if json="$(bash "$FAILURES" --logs-dir "$EMPTY" --json 2>/dev/null)"; then
  scanned="$(printf '%s' "$json" | jq -r '.scanned')"
  npat="$(printf '%s' "$json" | jq -r '.patterns | length')"
  if [[ "$scanned" -eq 0 ]] && [[ "$npat" -eq 0 ]]; then
    pass "recent-failures empty dir → scanned 0, empty patterns, exit 0"
  else
    fail "recent-failures empty dir (scanned=$scanned patterns=$npat)"
  fi
else
  fail "recent-failures empty dir should exit 0"
fi

# =============================================================================
# Assertion 6: both scripts are syntactically valid
# =============================================================================
if bash -n "$SEARCH" 2>/dev/null; then pass "bash -n hydra-memory-search.sh"; else fail "bash -n hydra-memory-search.sh"; fi
if bash -n "$FAILURES" 2>/dev/null; then pass "bash -n hydra-recent-failures.sh"; else fail "bash -n hydra-recent-failures.sh"; fi

# =============================================================================
# Assertion 7: scripts contain no NUL bytes (codex #274 P2 — a literal NUL made
# git classify a script as binary, hiding the diff). grep -q exits 1 = clean.
# =============================================================================
for s in "$SEARCH" "$FAILURES"; do
  # Portable NUL detection: strip everything EXCEPT NUL, count what remains.
  # `tr -cd '\000'` keeps only NUL bytes; wc -c == 0 means none. Avoids
  # grep -P, which is unavailable on some platforms.
  nuls="$(tr -cd '\000' < "$s" | wc -c | tr -d '[:space:]')"
  if [[ "$nuls" -gt 0 ]]; then
    fail "$(basename "$s") contains $nuls NUL byte(s) (would be treated as binary)"
  else
    pass "$(basename "$s") is NUL-free (stays a text file)"
  fi
done

# =============================================================================
echo "----------------------------------------"
echo "session-preamble self-test: ${PASS} passed, ${FAIL} failed"
[[ "$FAIL" -eq 0 ]]

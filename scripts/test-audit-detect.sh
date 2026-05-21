#!/usr/bin/env bash
#
# test-audit-detect.sh — regression test for scripts/audit-detect.sh.
#
# For EACH of the four detection rules, asserts the rule FIRES on a positive
# fixture and DOES NOT fire on a matched negative fixture. Also checks the
# JSON-array contract, usage errors, and the --only filter.
#
# Style mirrors scripts/test-check-claude-md-size.sh and
# scripts/test-promote-citations.sh: pure bash, colored pass/fail counter, all
# fixtures in mktemp (never touches the live worktree). Deterministic via
# --now so the time-window rules don't depend on wall-clock.
#
# Spec: docs/specs/2026-04-17-worker-auditor-subagent.md

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"
DETECT="$SCRIPT_DIR/audit-detect.sh"
CHECK="$SCRIPT_DIR/check-claude-md-size.sh"

if [[ ! -f "$DETECT" ]]; then
  echo "test-audit-detect: $DETECT not found" >&2
  exit 2
fi

if [[ -t 1 ]] && [[ "${NO_COLOR:-}" != "1" ]]; then
  C_GREEN=$'\033[32m'; C_RED=$'\033[31m'; C_BOLD=$'\033[1m'; C_RESET=$'\033[0m'
else
  C_GREEN=""; C_RED=""; C_BOLD=""; C_RESET=""
fi

passed=0
failed=0
tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

say()  { printf "\n${C_BOLD}▸ %s${C_RESET}\n" "$*"; }
ok()   { printf "  ${C_GREEN}✓${C_RESET} %s\n" "$*"; passed=$((passed + 1)); }
bad()  { printf "  ${C_RED}✗${C_RESET} %s\n" "$*"; failed=$((failed + 1)); }

NOW="2026-05-21T09:00:00"   # fixed clock for all time-window rules

# Build a minimal fixture repo skeleton under $1. Copies in the real
# check-claude-md-size.sh so RULE_claude_md_ceiling has its dependency.
make_repo() {
  local r="$1"
  mkdir -p "$r/scripts" "$r/state" "$r/docs/specs" "$r/logs"
  cp "$CHECK" "$r/scripts/check-claude-md-size.sh"
  chmod +x "$r/scripts/check-claude-md-size.sh"
}

# Run audit-detect against a fixture repo; capture JSON to a file. Extra args
# are passed through. Always runs with the fixed clock.
run_detect() {
  local r="$1"; shift
  NO_COLOR=1 bash "$DETECT" --root "$r" --now "$NOW" "$@"
}

# jq helper: does the output contain a finding with rule == $1 ?
has_rule() {
  local json="$1" rule="$2"
  printf '%s' "$json" | jq -e --arg r "$rule" 'any(.[]; .rule == $r)' >/dev/null 2>&1
}

# ---------------------------------------------------------------------------
# Contract: empty/clean repo → "[]"
# ---------------------------------------------------------------------------
say "Contract: clean repo (small CLAUDE.md, no state) → empty array"
cr="$tmpdir/clean"
make_repo "$cr"
printf '# CLAUDE.md\n\nSmall and healthy.\n' > "$cr/CLAUDE.md"
out="$(run_detect "$cr")"
if printf '%s' "$out" | jq -e 'type == "array" and length == 0' >/dev/null 2>&1; then
  ok "clean repo emits an empty JSON array"
else
  bad "expected '[]'; got: $out"
fi

# ===========================================================================
# RULE 1: claude-md-ceiling
# ===========================================================================
say "RULE claude-md-ceiling — POSITIVE: CLAUDE.md at WARN band fires"
r1p="$tmpdir/ceiling-pos"
make_repo "$r1p"
# 970 chars at --claude-warn-pct 95 of max 1000 ⇒ WARN band ⇒ fires.
{ printf '# CLAUDE.md\n\n'; head -c 950 /dev/zero | tr '\0' 'x'; printf '\n'; } > "$r1p/CLAUDE.md"
# Drive the checker against a custom max via env so the fixture size maps to a
# clean percentage; --claude-warn-pct sets the band floor that trips the rule.
out="$(NO_COLOR=1 HYDRA_CLAUDEMD_MAX=1000 bash "$DETECT" --root "$r1p" --now "$NOW" --claude-warn-pct 95 --only claude-md-ceiling)"
if has_rule "$out" "claude-md-ceiling"; then
  ok "WARN-band CLAUDE.md fires claude-md-ceiling"
else
  bad "expected claude-md-ceiling to fire; got: $out"
fi

say "RULE claude-md-ceiling — NEGATIVE: CLAUDE.md in NOTICE band does NOT fire"
r1n="$tmpdir/ceiling-neg"
make_repo "$r1n"
# ~880 chars @ max 1000 ⇒ 88% ⇒ NOTICE band (below the 95% WARN floor) ⇒ silent.
{ printf '# CLAUDE.md\n\n'; head -c 860 /dev/zero | tr '\0' 'x'; printf '\n'; } > "$r1n/CLAUDE.md"
out="$(NO_COLOR=1 HYDRA_CLAUDEMD_MAX=1000 bash "$DETECT" --root "$r1n" --now "$NOW" --claude-warn-pct 95 --only claude-md-ceiling)"
if has_rule "$out" "claude-md-ceiling"; then
  bad "NOTICE-band CLAUDE.md must NOT fire (false positive); got: $out"
else
  ok "NOTICE-band CLAUDE.md is silent (no false positive)"
fi

# ===========================================================================
# RULE 2: promotion-stale
# ===========================================================================
# Positive: promotion-ready citation + last_promotion_run 10 days before NOW.
say "RULE promotion-stale — POSITIVE: ready citation + stale last_promotion_run fires"
r2p="$tmpdir/promo-pos"
make_repo "$r2p"
printf '# CLAUDE.md\n\nhealthy\n' > "$r2p/CLAUDE.md"
cat > "$r2p/state/autopickup.json" <<JSON
{"enabled":true,"interval_min":30,"last_run":"2026-05-21T08:00:00","last_picked_count":0,"consecutive_rate_limit_hits":0,"last_promotion_run":"2026-05-11T09:00:00"}
JSON
cat > "$r2p/state/memory-citations.json" <<JSON
{"citations":{"learnings-x.md#foo":{"count":4,"last_cited":"2026-05-20","tickets":["#1","#2","#3","#4"],"promotion_threshold_reached":true}}}
JSON
out="$(run_detect "$r2p" --only promotion-stale)"
if has_rule "$out" "promotion-stale"; then
  ok "stale promotion (10d) with ready work fires promotion-stale"
else
  bad "expected promotion-stale to fire; got: $out"
fi

# Negative A: last_promotion_run is recent (2 days ago) → no fire.
say "RULE promotion-stale — NEGATIVE A: recent last_promotion_run does NOT fire"
r2na="$tmpdir/promo-neg-recent"
make_repo "$r2na"
printf '# CLAUDE.md\n\nhealthy\n' > "$r2na/CLAUDE.md"
cat > "$r2na/state/autopickup.json" <<JSON
{"enabled":true,"interval_min":30,"last_run":"2026-05-21T08:00:00","last_picked_count":0,"consecutive_rate_limit_hits":0,"last_promotion_run":"2026-05-19T09:00:00"}
JSON
cp "$r2p/state/memory-citations.json" "$r2na/state/memory-citations.json"
out="$(run_detect "$r2na" --only promotion-stale)"
if has_rule "$out" "promotion-stale"; then
  bad "recent promotion run must NOT fire; got: $out"
else
  ok "recent promotion run is silent"
fi

# Negative B: stale run but NO promotion-ready work → no fire.
say "RULE promotion-stale — NEGATIVE B: stale run but no ready work does NOT fire"
r2nb="$tmpdir/promo-neg-empty"
make_repo "$r2nb"
printf '# CLAUDE.md\n\nhealthy\n' > "$r2nb/CLAUDE.md"
cp "$r2p/state/autopickup.json" "$r2nb/state/autopickup.json"
cat > "$r2nb/state/memory-citations.json" <<JSON
{"citations":{"learnings-x.md#bar":{"count":1,"last_cited":"2026-05-20","tickets":["#9"],"promotion_threshold_reached":false}}}
JSON
out="$(run_detect "$r2nb" --only promotion-stale)"
if has_rule "$out" "promotion-stale"; then
  bad "no promotion-ready work must NOT fire; got: $out"
else
  ok "stale run with no ready work is silent (no false positive)"
fi

# ===========================================================================
# RULE 3: worker-stalled
# ===========================================================================
# Positive: running worker started 30 min before NOW, no completion log.
say "RULE worker-stalled — POSITIVE: running >12m with no log fires"
r3p="$tmpdir/stall-pos"
make_repo "$r3p"
printf '# CLAUDE.md\n\nhealthy\n' > "$r3p/CLAUDE.md"
cat > "$r3p/state/active.json" <<JSON
{"workers":[{"id":"w-aaa","ticket":"tonychang04/hydra#42","repo":"tonychang04/hydra","tier":"T2","started_at":"2026-05-21T08:30:00","subagent_type":"worker-implementation","status":"running"}]}
JSON
out="$(run_detect "$r3p" --only worker-stalled)"
if has_rule "$out" "worker-stalled"; then
  ok "30m-running worker with no log fires worker-stalled"
else
  bad "expected worker-stalled to fire; got: $out"
fi

# Negative A: worker is young (started 5 min before NOW) → no fire.
say "RULE worker-stalled — NEGATIVE A: young worker (<12m) does NOT fire"
r3na="$tmpdir/stall-neg-young"
make_repo "$r3na"
printf '# CLAUDE.md\n\nhealthy\n' > "$r3na/CLAUDE.md"
cat > "$r3na/state/active.json" <<JSON
{"workers":[{"id":"w-bbb","ticket":"tonychang04/hydra#43","repo":"tonychang04/hydra","tier":"T2","started_at":"2026-05-21T08:55:00","subagent_type":"worker-implementation","status":"running"}]}
JSON
out="$(run_detect "$r3na" --only worker-stalled)"
if has_rule "$out" "worker-stalled"; then
  bad "young worker (5m) must NOT fire; got: $out"
else
  ok "young worker is silent"
fi

# Negative B: old worker but a completion log exists → no fire.
say "RULE worker-stalled — NEGATIVE B: old worker WITH completion log does NOT fire"
r3nb="$tmpdir/stall-neg-logged"
make_repo "$r3nb"
printf '# CLAUDE.md\n\nhealthy\n' > "$r3nb/CLAUDE.md"
cat > "$r3nb/state/active.json" <<JSON
{"workers":[{"id":"w-ccc","ticket":"tonychang04/hydra#44","repo":"tonychang04/hydra","tier":"T2","started_at":"2026-05-21T08:30:00","subagent_type":"worker-implementation","status":"running"}]}
JSON
printf '{"ticket":"#44","status":"complete"}\n' > "$r3nb/logs/44.json"
out="$(run_detect "$r3nb" --only worker-stalled)"
if has_rule "$out" "worker-stalled"; then
  bad "logged worker must NOT fire; got: $out"
else
  ok "old worker with completion log is silent (no false positive)"
fi

# Negative C: old worker but status is complete (not running) → no fire.
say "RULE worker-stalled — NEGATIVE C: non-running status does NOT fire"
r3nc="$tmpdir/stall-neg-complete"
make_repo "$r3nc"
printf '# CLAUDE.md\n\nhealthy\n' > "$r3nc/CLAUDE.md"
cat > "$r3nc/state/active.json" <<JSON
{"workers":[{"id":"w-ddd","ticket":"tonychang04/hydra#45","repo":"tonychang04/hydra","tier":"T2","started_at":"2026-05-21T08:00:00","subagent_type":"worker-implementation","status":"complete"}]}
JSON
out="$(run_detect "$r3nc" --only worker-stalled)"
if has_rule "$out" "worker-stalled"; then
  bad "completed worker must NOT fire; got: $out"
else
  ok "completed worker is silent"
fi

# ===========================================================================
# RULE 4: broken-spec-pointer
# ===========================================================================
say "RULE broken-spec-pointer — POSITIVE: CLAUDE.md cites a missing spec fires"
r4p="$tmpdir/ptr-pos"
make_repo "$r4p"
cat > "$r4p/CLAUDE.md" <<'MD'
# CLAUDE.md

See `docs/specs/2026-04-17-real-spec.md` for the landed behavior.
Also references docs/specs/2026-99-99-does-not-exist.md (dangling).
MD
printf '# real spec\n' > "$r4p/docs/specs/2026-04-17-real-spec.md"
out="$(run_detect "$r4p" --only broken-spec-pointer)"
if has_rule "$out" "broken-spec-pointer"; then
  ok "missing spec pointer fires broken-spec-pointer"
else
  bad "expected broken-spec-pointer to fire; got: $out"
fi
# And it must name the missing one, not the present one.
if printf '%s' "$out" | jq -e 'any(.[]; .title | contains("2026-99-99-does-not-exist.md"))' >/dev/null 2>&1; then
  ok "finding names the missing spec"
else
  bad "expected finding to name 2026-99-99-does-not-exist.md; got: $out"
fi
if printf '%s' "$out" | jq -e 'any(.[]; .title | contains("2026-04-17-real-spec.md"))' >/dev/null 2>&1; then
  bad "must NOT flag the present spec; got: $out"
else
  ok "present spec is not flagged"
fi

say "RULE broken-spec-pointer — NEGATIVE: all cited specs exist does NOT fire"
r4n="$tmpdir/ptr-neg"
make_repo "$r4n"
cat > "$r4n/CLAUDE.md" <<'MD'
# CLAUDE.md

See `docs/specs/2026-04-17-real-spec.md` and `docs/specs/2026-04-18-other.md`.
MD
printf '# spec a\n' > "$r4n/docs/specs/2026-04-17-real-spec.md"
printf '# spec b\n' > "$r4n/docs/specs/2026-04-18-other.md"
out="$(run_detect "$r4n" --only broken-spec-pointer)"
if has_rule "$out" "broken-spec-pointer"; then
  bad "all-specs-present must NOT fire; got: $out"
else
  ok "all cited specs present → silent (no false positive)"
fi

# ===========================================================================
# Misc: --only filter, usage errors
# ===========================================================================
say "Misc: --only restricts to one rule"
# r4p has a broken pointer; running --only worker-stalled there must be empty.
out="$(run_detect "$r4p" --only worker-stalled)"
if printf '%s' "$out" | jq -e 'length == 0' >/dev/null 2>&1; then
  ok "--only worker-stalled suppresses the broken-pointer finding"
else
  bad "expected empty array with --only worker-stalled; got: $out"
fi

say "Misc: unknown option → exit 2"
set +e
NO_COLOR=1 bash "$DETECT" --root "$cr" --bogus >/dev/null 2>&1
ec=$?
set -e
if [[ "$ec" -eq 2 ]]; then ok "unknown option → exit 2"; else bad "expected exit 2, got $ec"; fi

say "Misc: non-integer --stale-days → exit 2"
set +e
NO_COLOR=1 bash "$DETECT" --root "$cr" --stale-days foo >/dev/null 2>&1
ec=$?
set -e
if [[ "$ec" -eq 2 ]]; then ok "non-integer numeric option → exit 2"; else bad "expected exit 2, got $ec"; fi

say "Misc: missing --root dir → exit 2"
set +e
NO_COLOR=1 bash "$DETECT" --root "$tmpdir/nope" >/dev/null 2>&1
ec=$?
set -e
if [[ "$ec" -eq 2 ]]; then ok "missing root → exit 2"; else bad "expected exit 2, got $ec"; fi

# ---------- summary ----------
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
if [[ "$failed" -eq 0 ]]; then
  printf "${C_GREEN}${C_BOLD}test-audit-detect: OK${C_RESET} (%d passed)\n" "$passed"
  exit 0
fi
printf "${C_RED}${C_BOLD}test-audit-detect: FAIL${C_RESET} (%d passed, %d failed)\n" "$passed" "$failed" >&2
exit 1

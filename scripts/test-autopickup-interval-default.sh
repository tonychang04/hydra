#!/usr/bin/env bash
#
# test-autopickup-interval-default.sh — drift guard for the scheduled-autopickup
# default interval vs. the tick's stream-idle stall-watchdog threshold (#316).
#
# scripts/autopickup-tick.sh warns when `interval_min >= 18` ("will miss the
# ~18min stream-idle ceiling; set <15"). If the DEFAULT interval a fresh install
# stamps is at/above that threshold, every default-config tick trips its own
# watchdog warning — the default fights the watchdog it ships alongside (the
# exact bug #316 fixed by lowering the default 30 -> 15).
#
# The default is stamped by MORE THAN ONE source, and an earlier #316 pass
# missed one of them (the canonical root installer setup.sh). So this guard
# reads the threshold from autopickup-tick.sh AND the default from EVERY
# structural seed source, and asserts each default < threshold (and within the
# [5,120] accepted range). Seed sources checked:
#   - state/autopickup.json.example  (committed template; jq .interval_min)
#   - setup.sh                       (root installer's inline seed JSON)
# So a future divergence in EITHER seed source reds here.
#
# Source paths are overridable via TICK_SRC / EXAMPLE_SRC / SETUP_SRC so the
# test can prove it actually catches drift (the red cases the golden harness
# drives).
#
# Style mirrors scripts/test-contract-path.sh (bash, NO_COLOR-aware, pass/fail
# counter, no external harness).
# Spec: docs/specs/2026-06-26-autopickup-default-interval.md

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"

TICK_SRC="${TICK_SRC:-$ROOT_DIR/scripts/autopickup-tick.sh}"
EXAMPLE_SRC="${EXAMPLE_SRC:-$ROOT_DIR/state/autopickup.json.example}"
SETUP_SRC="${SETUP_SRC:-$ROOT_DIR/setup.sh}"

if [[ -t 1 ]] && [[ "${NO_COLOR:-}" != "1" ]]; then
  C_GREEN=$'\033[32m'; C_RED=$'\033[31m'; C_BOLD=$'\033[1m'; C_RESET=$'\033[0m'
else
  C_GREEN=""; C_RED=""; C_BOLD=""; C_RESET=""
fi

passed=0
failed=0
ok()  { printf "  ${C_GREEN}OK${C_RESET}  %s\n" "$*"; passed=$((passed + 1)); }
bad() { printf "  ${C_RED}XX${C_RESET}  %s\n" "$*"; failed=$((failed + 1)); }

# --- extract the watchdog threshold (the N in `interval_min >= N`) ------------
# Grep the interval-warn guard in autopickup-tick.sh. The canonical line is:
#   if (( interval_min >= 18 )); then
extract_threshold() {
  grep -oE 'interval_min[[:space:]]*>=[[:space:]]*[0-9]+' "$1" \
    | grep -oE '[0-9]+' \
    | head -n1
}

# --- extract the default interval from the committed state template ----------
extract_example_default() {
  jq -r '.interval_min' "$1"
}

# --- extract the default from setup.sh's inline autopickup.json seed JSON -----
# The root installer seeds a fresh file with an inline JSON object on the
# `*/autopickup.json)` case arm. Pull that object and read .interval_min.
extract_setup_default() {
  grep -E '/autopickup\.json\)' "$1" \
    | grep -oE '\{[^}]*"interval_min"[^}]*\}' \
    | jq -r '.interval_min' 2>/dev/null \
    | head -n1
}

printf "${C_BOLD}> test-autopickup-interval-default${C_RESET}\n"

[[ -f "$TICK_SRC" ]]    || bad "tick source not found: $TICK_SRC"
[[ -f "$EXAMPLE_SRC" ]] || bad "example source not found: $EXAMPLE_SRC"
[[ -f "$SETUP_SRC" ]]   || bad "setup source not found: $SETUP_SRC"

threshold="$(extract_threshold "$TICK_SRC" || true)"

if [[ "$threshold" =~ ^[0-9]+$ ]]; then
  ok "watchdog threshold parsed from autopickup-tick.sh: $threshold"
else
  bad "could not parse watchdog threshold (interval_min >= N) from $TICK_SRC"
fi

# Check one seed source: parse it, assert integer, in-range, and < threshold.
check_seed() {
  local label="$1" value="$2"
  if [[ ! "$value" =~ ^[0-9]+$ ]]; then
    bad "could not parse default from $label (got: '$value')"
    return
  fi
  ok "default parsed from $label: $value"
  if (( value >= 5 && value <= 120 )); then
    ok "$label default $value within accepted range [5,120]"
  else
    bad "$label default $value outside accepted range [5,120]"
  fi
  if [[ "$threshold" =~ ^[0-9]+$ ]]; then
    if (( value < threshold )); then
      ok "$label default ($value) < watchdog threshold ($threshold) — no interval_warn on a default config"
    else
      bad "$label default ($value) >= watchdog threshold ($threshold) — a fresh install would trip interval_warn"
    fi
  fi
}

check_seed "autopickup.json.example" "$(extract_example_default "$EXAMPLE_SRC" || true)"
check_seed "setup.sh installer seed" "$(extract_setup_default "$SETUP_SRC" || true)"

printf "\n${C_BOLD}%d passed, %d failed${C_RESET}\n" "$passed" "$failed"
[[ "$failed" -eq 0 ]]

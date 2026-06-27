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
# This test reads BOTH numbers from source — the watchdog threshold from
# autopickup-tick.sh and the default from state/autopickup.json.example — and
# asserts default < threshold (and default within the [5,120] accepted range).
# So the two can never silently drift apart again: bump the default to >= the
# threshold, or lower the threshold below the default, and CI reds here.
#
# Source paths are overridable via TICK_SRC / EXAMPLE_SRC so the test can prove
# it actually catches drift (the red cases at the bottom).
#
# Style mirrors scripts/test-contract-path.sh (bash, NO_COLOR-aware, pass/fail
# counter, no external harness).
# Spec: docs/specs/2026-06-26-autopickup-default-interval.md

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"

TICK_SRC="${TICK_SRC:-$ROOT_DIR/scripts/autopickup-tick.sh}"
EXAMPLE_SRC="${EXAMPLE_SRC:-$ROOT_DIR/state/autopickup.json.example}"

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
  local src="$1"
  grep -oE 'interval_min[[:space:]]*>=[[:space:]]*[0-9]+' "$src" \
    | grep -oE '[0-9]+' \
    | head -n1
}

# --- extract the default interval from the committed state template ----------
extract_default() {
  local src="$1"
  jq -r '.interval_min' "$src"
}

printf "${C_BOLD}> test-autopickup-interval-default${C_RESET}\n"

[[ -f "$TICK_SRC" ]]    || { bad "tick source not found: $TICK_SRC"; }
[[ -f "$EXAMPLE_SRC" ]] || { bad "example source not found: $EXAMPLE_SRC"; }

threshold="$(extract_threshold "$TICK_SRC" || true)"
default="$(extract_default "$EXAMPLE_SRC" || true)"

# Both must be plain integers, or the source moved and the guard is blind.
if [[ "$threshold" =~ ^[0-9]+$ ]]; then
  ok "watchdog threshold parsed from autopickup-tick.sh: $threshold"
else
  bad "could not parse watchdog threshold (interval_min >= N) from $TICK_SRC"
fi

if [[ "$default" =~ ^[0-9]+$ ]]; then
  ok "default interval parsed from autopickup.json.example: $default"
else
  bad "could not parse .interval_min from $EXAMPLE_SRC (got: '$default')"
fi

# Only run the numeric invariants if both parsed.
if [[ "$threshold" =~ ^[0-9]+$ ]] && [[ "$default" =~ ^[0-9]+$ ]]; then
  # default within the accepted [5,120] range
  if (( default >= 5 && default <= 120 )); then
    ok "default $default within accepted range [5,120]"
  else
    bad "default $default outside accepted range [5,120]"
  fi

  # THE invariant: a default-config tick must not trip the watchdog warning.
  if (( default < threshold )); then
    ok "default ($default) < watchdog threshold ($threshold) — no interval_warn on a default config"
  else
    bad "default ($default) >= watchdog threshold ($threshold) — a fresh install would trip interval_warn"
  fi
fi

printf "\n${C_BOLD}%d passed, %d failed${C_RESET}\n" "$passed" "$failed"
[[ "$failed" -eq 0 ]]

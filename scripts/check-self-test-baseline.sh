#!/usr/bin/env bash
#
# check-self-test-baseline.sh — refuse to let self-test coverage regress.
#
# The self-test harness (self-test/run.sh) is Hydra's regression safety net. A
# silent collapse of its executable-assertion count looks identical to a green
# run (exit 0, "0 failed"), which is exactly how ticket #118's "0 cases
# executing" regression went unnoticed while workers claimed "24 passed". This
# guard catches that: it compares the current net executable-assertion count
# against a committed floor (self-test/baseline.json) and FAILs when coverage
# drops below it.
#
# "Net executable assertions" = self-test/run.sh --kind=script --json's
# .executable_assertions: the total step-level assertions that actually ran in
# non-skipped script cases. It collapses to 0 in the #118 regression and is
# insensitive to host-dependent docker/hadolint SKIPs.
#
# Behavior:
#   - Runs self-test/run.sh --kind=script --json (or reads a summary from
#     --from-json <file> to avoid re-running the ~90s harness).
#   - current < (baseline - tolerance)  → exit 1 (the hard rail).
#   - otherwise                          → exit 0.
#   - --update rewrites baseline.json:executable_assertions to the current count
#     (for an intentional coverage change; the diff makes it explicit).
#
# Intended callers:
#   - scripts/validate-state-all.sh (preflight) — only when
#     HYDRA_SELFTEST_BASELINE_GATE=1 is set, since the harness run is ~90s and
#     should be paid at the merge gate, not on every `pick up`.
#   - The Commander review/merge gate and CI.
#
# Mirrors scripts/check-claude-md-size.sh in shape (--quiet one-liner, --json,
# exit 0/1/2). Spec: docs/specs/2026-06-01-self-test-baseline-guard.md (#118).

set -euo pipefail

# -----------------------------------------------------------------------------
# resolve worktree root (script lives at <root>/scripts/check-self-test-baseline.sh)
# -----------------------------------------------------------------------------
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"

RUNNER="$ROOT_DIR/self-test/run.sh"
BASELINE_JSON="$ROOT_DIR/self-test/baseline.json"

# -----------------------------------------------------------------------------
# color / TTY
# -----------------------------------------------------------------------------
if [[ -t 1 ]] && [[ "${NO_COLOR:-}" != "1" ]]; then
  C_GREEN=$'\033[32m'
  C_RED=$'\033[31m'
  C_RESET=$'\033[0m'
else
  C_GREEN=""
  C_RED=""
  C_RESET=""
fi

usage() {
  cat <<'EOF'
Usage: check-self-test-baseline.sh [options]

Fails (exit 1) if the self-test harness's net executable-assertion count has
dropped below the committed floor in self-test/baseline.json. This is the
regression detector that would have caught ticket #118 (coverage silently
collapsing to 0 while runs still reported green).

Options:
  --from-json <f>  Read the run summary from a JSON file (with an
                   .executable_assertions field) instead of running the harness.
                   Lets a caller that already ran run.sh --json reuse the result
                   and skip the ~90s re-run.
  --baseline <f>   Path to baseline.json (default: <root>/self-test/baseline.json)
  --update         Rewrite baseline.json:executable_assertions to the current
                   count, then exit 0. Use when intentionally changing coverage.
  --json           Emit {"current":N,"baseline":M,"tolerance":T,"ok":bool}.
  --quiet          Silent on PASS; one line on FAIL (preflight/greeting style).
  -h, --help       Show this help.

Environment:
  NO_COLOR=1       Disable colored output.

Exit codes:
  0 = PASS (current >= baseline - tolerance) or --update succeeded
  1 = FAIL (coverage regressed below baseline)
  2 = usage error / unreadable input / malformed JSON
EOF
}

# -----------------------------------------------------------------------------
# arg parsing
# -----------------------------------------------------------------------------
from_json=""
baseline_path=""
do_update=0
json_output=0
quiet=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --from-json)
      [[ $# -ge 2 ]] || { echo "check-self-test-baseline: --from-json needs a value" >&2; usage >&2; exit 2; }
      from_json="$2"; shift 2
      ;;
    --from-json=*)
      from_json="${1#--from-json=}"; shift
      ;;
    --baseline)
      [[ $# -ge 2 ]] || { echo "check-self-test-baseline: --baseline needs a value" >&2; usage >&2; exit 2; }
      baseline_path="$2"; shift 2
      ;;
    --baseline=*)
      baseline_path="${1#--baseline=}"; shift
      ;;
    --update)
      do_update=1; shift
      ;;
    --json)
      json_output=1; shift
      ;;
    --quiet)
      quiet=1; shift
      ;;
    -h|--help)
      usage; exit 0
      ;;
    --)
      shift; break
      ;;
    *)
      echo "check-self-test-baseline: unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

[[ -n "$baseline_path" ]] || baseline_path="$BASELINE_JSON"

# -----------------------------------------------------------------------------
# read baseline
# -----------------------------------------------------------------------------
if [[ ! -f "$baseline_path" ]]; then
  echo "check-self-test-baseline: baseline not found: $baseline_path" >&2
  exit 2
fi
if ! jq empty "$baseline_path" 2>/dev/null; then
  echo "check-self-test-baseline: malformed baseline JSON: $baseline_path" >&2
  exit 2
fi

baseline="$(jq -r '.executable_assertions // empty' "$baseline_path")"
tolerance="$(jq -r '.tolerance // 0' "$baseline_path")"
if ! [[ "$baseline" =~ ^[0-9]+$ ]]; then
  echo "check-self-test-baseline: baseline.executable_assertions must be a non-negative integer (got: '$baseline')" >&2
  exit 2
fi
if ! [[ "$tolerance" =~ ^[0-9]+$ ]]; then
  echo "check-self-test-baseline: baseline.tolerance must be a non-negative integer (got: '$tolerance')" >&2
  exit 2
fi

# -----------------------------------------------------------------------------
# obtain current executable-assertion count
# -----------------------------------------------------------------------------
get_current() {
  local summary
  if [[ -n "$from_json" ]]; then
    if [[ ! -f "$from_json" ]]; then
      echo "check-self-test-baseline: --from-json file not found: $from_json" >&2
      exit 2
    fi
    summary="$(cat "$from_json")"
  else
    if [[ ! -x "$RUNNER" ]]; then
      echo "check-self-test-baseline: runner not executable: $RUNNER" >&2
      exit 2
    fi
    # Run the deterministic, host-runnable subset. Tolerate exit 1 (a FAILing
    # case) — we still want the assertion count from the JSON summary; the
    # coverage check is independent of whether a case currently fails.
    summary="$("$RUNNER" --kind=script --json 2>/dev/null || true)"
  fi
  if ! jq empty <<<"$summary" 2>/dev/null; then
    echo "check-self-test-baseline: could not parse run summary JSON" >&2
    exit 2
  fi
  local val
  val="$(jq -r '.executable_assertions // empty' <<<"$summary")"
  if ! [[ "$val" =~ ^[0-9]+$ ]]; then
    echo "check-self-test-baseline: summary.executable_assertions missing or non-integer (got: '$val')" >&2
    exit 2
  fi
  echo "$val"
}

current="$(get_current)"

# -----------------------------------------------------------------------------
# --update: rewrite the baseline floor to the current count, then exit 0
# -----------------------------------------------------------------------------
if [[ "$do_update" -eq 1 ]]; then
  today="$(date +%Y-%m-%d)"
  tmp="$(mktemp)"
  jq --argjson c "$current" --arg d "$today" \
    '.executable_assertions = $c | .updated = $d' \
    "$baseline_path" >"$tmp"
  mv "$tmp" "$baseline_path"
  [[ "$quiet" -eq 1 ]] || echo "${C_GREEN}✓${C_RESET} self-test baseline updated to ${current} (was ${baseline})"
  exit 0
fi

# -----------------------------------------------------------------------------
# compare
# -----------------------------------------------------------------------------
floor=$((baseline - tolerance))
ok=true
[[ "$current" -lt "$floor" ]] && ok=false

if [[ "$json_output" -eq 1 ]]; then
  jq -n \
    --argjson current "$current" \
    --argjson baseline "$baseline" \
    --argjson tolerance "$tolerance" \
    --argjson ok "$ok" \
    '{current: $current, baseline: $baseline, tolerance: $tolerance, ok: $ok}'
fi

if [[ "$ok" == "true" ]]; then
  if [[ "$json_output" -ne 1 ]] && [[ "$quiet" -ne 1 ]]; then
    echo "${C_GREEN}✓${C_RESET} self-test: ${current} executable assertions (floor ${floor})"
  fi
  exit 0
fi

# FAIL — coverage regressed.
msg="self-test baseline regression: ${current} executable assertions < floor ${floor} (baseline ${baseline}, tolerance ${tolerance}). A PR must not drop net self-test assertions. If this reduction is intentional, run: scripts/check-self-test-baseline.sh --update"
if [[ "$json_output" -ne 1 ]]; then
  echo "${C_RED}✗${C_RESET} ${msg}" >&2
fi
exit 1

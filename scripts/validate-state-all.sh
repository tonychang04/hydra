#!/usr/bin/env bash
#
# validate-state-all.sh — validate every runtime state/*.json against its schema.
#
# Walks state/*.json (real runtime files — skips *.example.json), pairs each
# with its schema in state/schemas/, runs validate-state.sh on each, and
# reports per-file pass/fail plus a summary. Exit 0 only if every file passes.
#
# Usage:
#   scripts/validate-state-all.sh                   # run all, report all
#   scripts/validate-state-all.sh --fail-fast       # bail on first failure
#   scripts/validate-state-all.sh --state-dir <dir> # point at a different state/
#   scripts/validate-state-all.sh --help
#
# Called by scripts/hydra-doctor.sh in the Runtime state category.
# Spec: docs/specs/2026-04-16-state-schemas-complete.md
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"
VALIDATOR="$SCRIPT_DIR/validate-state.sh"

usage() {
  cat <<'EOF'
Usage: scripts/validate-state-all.sh [options]

Validates every runtime state/*.json against its matching schema in
state/schemas/<name>.schema.json. Skips *.example.json files (those are
templates, not runtime state).

Options:
  --state-dir <path>   Override the state directory (default: <repo>/state)
  --fail-fast          Exit on the first failure instead of checking all
  -h, --help           Show this help

Exit codes:
  0   all state files pass
  1   one or more failures
  2   usage error / missing validator

Behavior:
  - A state/<name>.json file with no matching schema is skipped with a warning
    (not a failure) — this keeps the script forward-compatible with new state
    files added before their schema.
  - A schema with no state file is also skipped (runtime state is often lazy-
    created; absent file = not yet written).
  - Each file is validated by invoking validate-state.sh. Per-file output goes
    to stderr/stdout verbatim so operators see the same message validate-state
    emits when run by hand.
EOF
}

# -----------------------------------------------------------------------------
# color / TTY
# -----------------------------------------------------------------------------
if [[ -t 1 ]] && [[ "${NO_COLOR:-}" != "1" ]]; then
  C_GREEN=$'\033[32m'
  C_RED=$'\033[31m'
  C_YELLOW=$'\033[33m'
  C_DIM=$'\033[2m'
  C_BOLD=$'\033[1m'
  C_RESET=$'\033[0m'
else
  C_GREEN=""
  C_RED=""
  C_YELLOW=""
  C_DIM=""
  C_BOLD=""
  C_RESET=""
fi

# -----------------------------------------------------------------------------
# arg parsing
# -----------------------------------------------------------------------------
state_dir=""
fail_fast=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --state-dir)
      [[ $# -ge 2 ]] || { echo "validate-state-all: --state-dir needs a value" >&2; usage >&2; exit 2; }
      state_dir="$2"; shift 2
      ;;
    --state-dir=*)
      state_dir="${1#--state-dir=}"; shift
      ;;
    --fail-fast)
      fail_fast=1; shift
      ;;
    -h|--help)
      usage; exit 0
      ;;
    *)
      echo "validate-state-all: unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ -z "$state_dir" ]]; then
  state_dir="$ROOT_DIR/state"
fi

if [[ ! -d "$state_dir" ]]; then
  echo "validate-state-all: state dir not found: $state_dir" >&2
  exit 2
fi

if [[ ! -x "$VALIDATOR" ]]; then
  echo "validate-state-all: validator not executable: $VALIDATOR" >&2
  exit 2
fi

schemas_dir="$state_dir/schemas"
if [[ ! -d "$schemas_dir" ]]; then
  echo "validate-state-all: schemas dir not found: $schemas_dir" >&2
  exit 2
fi

# -----------------------------------------------------------------------------
# walk state/*.json (skip *.example.json)
# -----------------------------------------------------------------------------
printf "%s▸ validate-state-all%s (state_dir=%s)\n" "$C_BOLD" "$C_RESET" "$state_dir"

shopt -s nullglob
state_files=("$state_dir"/*.json)
shopt -u nullglob

passed=0
failed=0
skipped=0
failures=()

for f in "${state_files[@]}"; do
  base_file="$(basename "$f")"
  case "$base_file" in
    *.example.json)
      continue
      ;;
  esac

  base="${base_file%.json}"
  schema="$schemas_dir/${base}.schema.json"

  if [[ ! -f "$schema" ]]; then
    printf "  %s⚠%s %s %s(no schema at %s — skipping)%s\n" \
      "$C_YELLOW" "$C_RESET" "$base_file" "$C_DIM" "$schema" "$C_RESET"
    skipped=$((skipped + 1))
    continue
  fi

  # Run the validator. Capture its output for inline display.
  set +e
  out="$("$VALIDATOR" "$f" 2>&1)"
  ec=$?
  set -e

  if [[ "$ec" -eq 0 ]]; then
    printf "  %s✓%s %s\n" "$C_GREEN" "$C_RESET" "$base_file"
    passed=$((passed + 1))
  else
    printf "  %s✗%s %s\n" "$C_RED" "$C_RESET" "$base_file"
    # Indent validator output for readability.
    if [[ -n "$out" ]]; then
      printf "%s\n" "$out" | sed 's/^/      /'
    fi
    failed=$((failed + 1))
    failures+=("$base_file")
    if [[ "$fail_fast" -eq 1 ]]; then
      break
    fi
  fi
done

# -----------------------------------------------------------------------------
# summary
# -----------------------------------------------------------------------------
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
printf "Summary: %d passed · %d failed · %d skipped\n" "$passed" "$failed" "$skipped"

if [[ "$failed" -gt 0 ]]; then
  printf "%sFailures:%s %s\n" "$C_RED" "$C_RESET" "${failures[*]}"
  exit 1
fi

exit 0

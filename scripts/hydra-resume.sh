#!/usr/bin/env bash
#
# hydra-resume.sh — toggle the PAUSE kill switch to OFF by removing PAUSE file.
# Idempotent. Prints current state.
#
# Usage: ./hydra resume
#
# Spec: docs/specs/2026-04-16-hydra-cli.md (ticket #25)

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"

# shellcheck disable=SC1091
[[ -f "$ROOT_DIR/.hydra.env" ]] && source "$ROOT_DIR/.hydra.env"

usage() {
  cat <<'EOF'
Usage: ./hydra resume

Removes the PAUSE file at the repo root. Commander starts spawning new
workers again on the next tick / interactive `pick up`.

Idempotent: running resume when already unpaused is a noop-with-message.

Options:
  -h, --help    Show this help.

Exit codes:
  0   pause file absent at exit
  1   I/O error
EOF
}

if [[ -t 1 ]] && [[ "${NO_COLOR:-}" != "1" ]]; then
  C_GREEN=$'\033[32m'; C_RED=$'\033[31m'; C_YELLOW=$'\033[33m'; C_DIM=$'\033[2m'; C_RESET=$'\033[0m'
else
  C_GREEN=""; C_RED=""; C_YELLOW=""; C_DIM=""; C_RESET=""
fi

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    *) echo "✗ unknown arg: $1" >&2; usage >&2; exit 2 ;;
  esac
done

pause_file="$ROOT_DIR/PAUSE"

if [[ ! -f "$pause_file" ]]; then
  printf "%s⚠%s PAUSE file not present (already resumed)\n" "$C_YELLOW" "$C_RESET"
  printf "  current state: %srunning%s\n" "$C_GREEN" "$C_RESET"
  exit 0
fi

rm -f "$pause_file"
printf "%s✓%s removed PAUSE file\n" "$C_GREEN" "$C_RESET"
printf "  current state: %srunning%s\n" "$C_GREEN" "$C_RESET"
printf "%s  pause again with: ./hydra pause%s\n" "$C_DIM" "$C_RESET"
exit 0

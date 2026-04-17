#!/usr/bin/env bash
#
# hydra-pause.sh — toggle the PAUSE kill switch to ON by creating PAUSE file.
# Idempotent. Prints current state.
#
# Usage: ./hydra pause [--reason <text>]
#
# Spec: docs/specs/2026-04-16-hydra-cli.md (ticket #25)

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"

# shellcheck disable=SC1091
[[ -f "$ROOT_DIR/.hydra.env" ]] && source "$ROOT_DIR/.hydra.env"

usage() {
  cat <<'EOF'
Usage: ./hydra pause [options]

Creates the PAUSE file at the repo root. Commander refuses to spawn new
workers while PAUSE exists. In-flight workers continue to completion.

Idempotent: running pause twice is a noop-with-message.

Options:
  --reason <text>   Write <text> as the contents of the PAUSE file.
                    Shown by ./hydra status / ./hydra doctor / Commander
                    greeting. Default: "paused via ./hydra pause at <ts>".
  -h, --help        Show this help.

Exit codes:
  0   pause file exists at exit (freshly created OR already present)
  1   I/O error
EOF
}

if [[ -t 1 ]] && [[ "${NO_COLOR:-}" != "1" ]]; then
  C_GREEN=$'\033[32m'; C_RED=$'\033[31m'; C_YELLOW=$'\033[33m'; C_DIM=$'\033[2m'; C_RESET=$'\033[0m'
else
  C_GREEN=""; C_RED=""; C_YELLOW=""; C_DIM=""; C_RESET=""
fi

reason=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --reason) [[ $# -ge 2 ]] || { echo "✗ --reason needs a value" >&2; usage >&2; exit 2; }; reason="$2"; shift 2 ;;
    --reason=*) reason="${1#--reason=}"; shift ;;
    *) echo "✗ unknown arg: $1" >&2; usage >&2; exit 2 ;;
  esac
done

pause_file="$ROOT_DIR/PAUSE"
ts="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
[[ -z "$reason" ]] && reason="paused via ./hydra pause at $ts"

if [[ -f "$pause_file" ]]; then
  printf "%s⚠%s PAUSE already active\n" "$C_YELLOW" "$C_RESET"
  printf "%s  existing reason: %s%s\n" "$C_DIM" "$(cat "$pause_file")" "$C_RESET"
  printf "  current state: %spaused%s\n" "$C_RED" "$C_RESET"
  exit 0
fi

printf "%s\n" "$reason" > "$pause_file"
printf "%s✓%s created PAUSE file at %s\n" "$C_GREEN" "$C_RESET" "$pause_file"
printf "  current state: %spaused%s\n" "$C_RED" "$C_RESET"
printf "%s  resume with: ./hydra resume%s\n" "$C_DIM" "$C_RESET"
exit 0

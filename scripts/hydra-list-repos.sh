#!/usr/bin/env bash
#
# hydra-list-repos.sh — table view of state/repos.json.
#
# Usage: ./hydra list-repos [--state-file <path>]
#
# Spec: docs/specs/2026-04-16-hydra-cli.md (ticket #25)

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"

# shellcheck disable=SC1091
[[ -f "$ROOT_DIR/.hydra.env" ]] && source "$ROOT_DIR/.hydra.env"

usage() {
  cat <<'EOF'
Usage: ./hydra list-repos [options]

Prints the contents of state/repos.json as a text table: name, trigger,
enabled, last autopickup poll. Read-only — no state is modified.

Options:
  --state-file <path>   Read repos from this file instead of state/repos.json.
                        Useful for tests / fixtures.
  -h, --help            Show this help.

Exit codes:
  0   OK
  1   state file missing or not valid JSON
EOF
}

if [[ -t 1 ]] && [[ "${NO_COLOR:-}" != "1" ]]; then
  C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'; C_GREEN=$'\033[32m'; C_RED=$'\033[31m'; C_RESET=$'\033[0m'
else
  C_BOLD=""; C_DIM=""; C_GREEN=""; C_RED=""; C_RESET=""
fi

err() { printf "✗ %s\n" "$*" >&2; }

repos_file=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --state-file) [[ $# -ge 2 ]] || { err "--state-file needs a value"; usage >&2; exit 2; }; repos_file="$2"; shift 2 ;;
    --state-file=*) repos_file="${1#--state-file=}"; shift ;;
    *) err "unknown arg: $1"; usage >&2; exit 2 ;;
  esac
done

repos_file="${repos_file:-$ROOT_DIR/state/repos.json}"

if [[ ! -f "$repos_file" ]]; then
  err "repos file not found: $repos_file"
  exit 1
fi
if ! jq empty "$repos_file" 2>/dev/null; then
  err "repos file is not valid JSON: $repos_file"
  exit 1
fi

auto_file="$ROOT_DIR/state/autopickup.json"
last_poll="never"
if [[ -f "$auto_file" ]] && jq empty "$auto_file" 2>/dev/null; then
  last_poll="$(jq -r '.last_run // "never"' "$auto_file")"
fi

default_trigger="$(jq -r '.default_ticket_trigger // "assignee"' "$repos_file")"

# Build rows via jq → TSV so column -t can align cleanly.
rows="$(
  jq -r --arg dt "$default_trigger" '
    .repos // []
    | map(select(type == "object" and has("owner") and has("name")))
    | .[]
    | [
        (.owner + "/" + .name),
        (.ticket_trigger // $dt),
        (if .enabled == true then "yes" else "no" end),
        (.local_path // "-")
      ]
    | @tsv
  ' "$repos_file"
)"

count="$(printf '%s\n' "$rows" | grep -c . || true)"

printf "%sHydra repos%s (autopickup last_run: %s%s%s)\n" "$C_BOLD" "$C_RESET" "$C_DIM" "$last_poll" "$C_RESET"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

if [[ "$count" -eq 0 ]]; then
  printf "%s(no repos configured — ./hydra add-repo <owner>/<name>)%s\n" "$C_DIM" "$C_RESET"
  exit 0
fi

# Render table.
{
  printf "NAME\tTRIGGER\tENABLED\tLOCAL_PATH\n"
  printf "%s\n" "$rows"
} | column -t -s $'\t'

printf "%s%d repo(s)%s\n" "$C_DIM" "$count" "$C_RESET"
exit 0

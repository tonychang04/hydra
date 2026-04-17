#!/usr/bin/env bash
#
# hydra-remove-repo.sh — remove a repo entry from state/repos.json.
#
# Usage: ./hydra remove-repo <owner>/<name>
#
# Spec: docs/specs/2026-04-16-hydra-cli.md (ticket #25)

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"

# shellcheck disable=SC1091
[[ -f "$ROOT_DIR/.hydra.env" ]] && source "$ROOT_DIR/.hydra.env"

usage() {
  cat <<'EOF'
Usage: ./hydra remove-repo <owner>/<name>

Removes a repo entry from state/repos.json. Atomic write (tmp + mv). Preserves
existing JSON formatting for unchanged entries.

Arguments:
  <owner>/<name>    Required. Repo slug to remove.

Exit codes:
  0   entry removed (or was already absent — noop with a message)
  1   I/O error or missing state/repos.json
  2   usage error
EOF
}

if [[ -t 1 ]] && [[ "${NO_COLOR:-}" != "1" ]]; then
  C_GREEN=$'\033[32m'; C_RED=$'\033[31m'; C_YELLOW=$'\033[33m'; C_RESET=$'\033[0m'
else
  C_GREEN=""; C_RED=""; C_YELLOW=""; C_RESET=""
fi

err()  { printf "%s✗%s %s\n" "$C_RED"    "$C_RESET" "$*" >&2; }
ok()   { printf "%s✓%s %s\n" "$C_GREEN"  "$C_RESET" "$*"; }
note() { printf "%sⓘ%s %s\n" "$C_YELLOW" "$C_RESET" "$*"; }

slug=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    -*) err "unknown flag: $1"; usage >&2; exit 2 ;;
    *)
      if [[ -z "$slug" ]]; then slug="$1"; else err "unexpected positional: $1"; exit 2; fi
      shift
      ;;
  esac
done

if [[ -z "$slug" ]]; then err "missing required <owner>/<name>"; usage >&2; exit 2; fi
if ! [[ "$slug" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then
  err "invalid slug '$slug' — expected <owner>/<name>"; exit 2
fi
owner="${slug%%/*}"
name="${slug##*/}"

repos_file="$ROOT_DIR/state/repos.json"
if [[ ! -f "$repos_file" ]]; then err "state/repos.json not found"; exit 1; fi
if ! jq empty "$repos_file" 2>/dev/null; then err "state/repos.json is not valid JSON"; exit 1; fi

existing="$(jq --arg o "$owner" --arg n "$name" \
  '.repos // [] | map(select(.owner == $o and .name == $n)) | length' "$repos_file")"
if [[ "$existing" -eq 0 ]]; then
  note "no entry matching $owner/$name — nothing to do"
  exit 0
fi

tmp="$(mktemp)"
# shellcheck disable=SC2064
trap "rm -f '$tmp'" EXIT

jq --arg o "$owner" --arg n "$name" \
  '.repos = ((.repos // []) | map(select(.owner != $o or .name != $n)))' \
  "$repos_file" > "$tmp"

mv "$tmp" "$repos_file"
trap - EXIT

ok "removed $owner/$name from state/repos.json"
exit 0

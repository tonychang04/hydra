#!/usr/bin/env bash
#
# hydra-issue.sh — queue a specific GitHub issue for the next autopickup tick.
# Appends to state/pending-dispatches.json (gitignored). Does NOT spawn a
# worker — the Commander's autopickup tick drains this queue first.
#
# Usage: ./hydra issue <url-or-owner/repo/num>
#
# Spec: docs/specs/2026-04-16-hydra-cli.md (ticket #25)

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"

# shellcheck disable=SC1091
[[ -f "$ROOT_DIR/.hydra.env" ]] && source "$ROOT_DIR/.hydra.env"

usage() {
  cat <<'EOF'
Usage: ./hydra issue <url-or-owner/repo/num>

Queues a specific GitHub issue for dispatch on the next autopickup tick.
Appends to state/pending-dispatches.json. Does NOT spawn a worker directly —
Commander drains this queue at the start of each tick.

Accepted argument shapes:
  https://github.com/owner/repo/issues/42
  owner/repo#42
  owner/repo/42

Options:
  --source <name>   Mark where this dispatch came from (default: cli).
                    Stored in the queue entry for audit.
  -h, --help        Show this help.

Exit codes:
  0   queued (or already present — deduped silently)
  1   I/O error
  2   usage error (could not parse the argument)
EOF
}

if [[ -t 1 ]] && [[ "${NO_COLOR:-}" != "1" ]]; then
  C_GREEN=$'\033[32m'; C_RED=$'\033[31m'; C_YELLOW=$'\033[33m'; C_DIM=$'\033[2m'; C_RESET=$'\033[0m'
else
  C_GREEN=""; C_RED=""; C_YELLOW=""; C_DIM=""; C_RESET=""
fi

err() { printf "%s✗%s %s\n" "$C_RED" "$C_RESET" "$*" >&2; }
ok()  { printf "%s✓%s %s\n" "$C_GREEN" "$C_RESET" "$*"; }

raw=""
source_tag="cli"

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --source) [[ $# -ge 2 ]] || { err "--source needs a value"; usage >&2; exit 2; }; source_tag="$2"; shift 2 ;;
    --source=*) source_tag="${1#--source=}"; shift ;;
    -*) err "unknown flag: $1"; usage >&2; exit 2 ;;
    *)
      if [[ -z "$raw" ]]; then raw="$1"; else err "unexpected positional: $1"; exit 2; fi
      shift
      ;;
  esac
done

if [[ -z "$raw" ]]; then
  err "missing argument: <url-or-owner/repo/num>"
  usage >&2
  exit 2
fi

# -----------------------------------------------------------------------------
# parse argument shapes
# -----------------------------------------------------------------------------
owner=""; name=""; num=""

if [[ "$raw" =~ ^https?://github\.com/([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+)/(issues|pull)/([0-9]+)(/.*)?$ ]]; then
  owner="${BASH_REMATCH[1]}"
  name="${BASH_REMATCH[2]}"
  num="${BASH_REMATCH[4]}"
elif [[ "$raw" =~ ^([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+)#([0-9]+)$ ]]; then
  owner="${BASH_REMATCH[1]}"
  name="${BASH_REMATCH[2]}"
  num="${BASH_REMATCH[3]}"
elif [[ "$raw" =~ ^([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+)/([0-9]+)$ ]]; then
  owner="${BASH_REMATCH[1]}"
  name="${BASH_REMATCH[2]}"
  num="${BASH_REMATCH[3]}"
else
  err "could not parse '$raw' as a GitHub issue reference"
  err "  try: https://github.com/owner/repo/issues/42  |  owner/repo#42  |  owner/repo/42"
  exit 2
fi

# -----------------------------------------------------------------------------
# append (atomic)
# -----------------------------------------------------------------------------
queue_file="$ROOT_DIR/state/pending-dispatches.json"
mkdir -p "$ROOT_DIR/state"

# Bootstrap if missing.
if [[ ! -f "$queue_file" ]]; then
  echo '{"queue": []}' > "$queue_file"
fi

if ! jq empty "$queue_file" 2>/dev/null; then
  err "state/pending-dispatches.json is not valid JSON"
  exit 1
fi

# Dedup check — matching owner/name/number.
existing="$(jq --arg o "$owner" --arg n "$name" --argjson num "$num" \
  '(.queue // []) | map(select(.owner == $o and .name == $n and .number == $num)) | length' \
  "$queue_file")"

if [[ "$existing" -gt 0 ]]; then
  printf "%sⓘ%s %s/%s#%s already queued (deduped)\n" "$C_YELLOW" "$C_RESET" "$owner" "$name" "$num"
  exit 0
fi

ts="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

tmp="$(mktemp)"
# shellcheck disable=SC2064
trap "rm -f '$tmp'" EXIT

jq --arg o "$owner" --arg n "$name" --argjson num "$num" \
   --arg ts "$ts" --arg src "$source_tag" \
  '.queue = ((.queue // []) + [{
     "owner": $o,
     "name": $n,
     "number": $num,
     "added_at": $ts,
     "source": $src
   }])' "$queue_file" > "$tmp"

mv "$tmp" "$queue_file"
trap - EXIT

ok "queued $owner/$name#$num for next autopickup tick"
printf "%s  (queue length: %s)%s\n" "$C_DIM" "$(jq -r '.queue | length' "$queue_file")" "$C_RESET"
exit 0

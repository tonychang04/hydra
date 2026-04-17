#!/usr/bin/env bash
#
# validate-citations.sh — verify every citation key in state/memory-citations.json
# still points at a real quote in its referenced memory file.
#
# Citation key format (produced by parse-citations.sh):
#   "<file>#<quote>"
# For example:
#   "learnings-CLI.md#\"npm install strips peer markers\""
# The part after the '#' may or may not be wrapped in straight double quotes.
# Match is a substring check against the referenced file; case-sensitive.
#
# Exit 0 if every citation is live. Otherwise print a list of stale references
# to stderr and exit 1.

set -euo pipefail

MEMORY_DIR_DEFAULT="./memory"
CITATIONS_FILE_DEFAULT="state/memory-citations.json"

usage() {
  cat <<'EOF'
Usage: validate-citations.sh [--memory-dir <path>] [--citations <file>]

Options:
  --memory-dir <path>   Override memory directory (default: $HYDRA_EXTERNAL_MEMORY_DIR,
                        falls back to ./memory).
  --citations <file>    Override citations JSON path (default: state/memory-citations.json).
  -h, --help            Show this help.

Exit codes:
  0   every citation is live
  1   one or more stale citations (printed to stderr)
  2   usage error / input missing or malformed
EOF
}

memory_dir=""
citations_file=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --memory-dir)
      [[ $# -ge 2 ]] || { echo "validate-citations: --memory-dir needs a value" >&2; usage >&2; exit 2; }
      memory_dir="$2"
      shift 2
      ;;
    --citations)
      [[ $# -ge 2 ]] || { echo "validate-citations: --citations needs a value" >&2; usage >&2; exit 2; }
      citations_file="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --)
      shift
      break
      ;;
    -*)
      echo "validate-citations: unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
    *)
      echo "validate-citations: unexpected argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ -z "$memory_dir" ]]; then
  memory_dir="${HYDRA_EXTERNAL_MEMORY_DIR:-$MEMORY_DIR_DEFAULT}"
fi
if [[ -z "$citations_file" ]]; then
  citations_file="$CITATIONS_FILE_DEFAULT"
fi

if [[ ! -f "$citations_file" ]]; then
  echo "validate-citations: citations file not found: $citations_file" >&2
  exit 2
fi
if [[ ! -d "$memory_dir" ]]; then
  echo "validate-citations: memory dir not found: $memory_dir" >&2
  exit 2
fi

# Extract all citation keys (skip _schema and any keys starting with "_").
keys="$(jq -r '
  . as $root
  | (if has("citations") then .citations else . end)
  | keys
  | map(select(startswith("_") | not))
  | .[]
' "$citations_file" 2>/dev/null)" || {
  echo "validate-citations: failed to parse JSON: $citations_file" >&2
  exit 2
}

stale=()
checked=0

while IFS= read -r key; do
  [[ -z "$key" ]] && continue
  checked=$((checked + 1))

  # Split on first '#'.
  file_part="${key%%#*}"
  quote_part="${key#*#}"

  if [[ "$file_part" == "$key" ]]; then
    stale+=("malformed citation key (no '#' separator): $key")
    continue
  fi

  # Strip surrounding straight double quotes if present.
  if [[ "$quote_part" == \"*\" ]]; then
    quote_part="${quote_part#\"}"
    quote_part="${quote_part%\"}"
  fi

  ref_file="$memory_dir/$file_part"
  if [[ ! -f "$ref_file" ]]; then
    stale+=("$key :: referenced file missing: $ref_file")
    continue
  fi

  # Substring match (case-sensitive). grep -F = fixed string; -q = quiet.
  if ! grep -Fq -- "$quote_part" "$ref_file"; then
    stale+=("$key :: quote not found in $ref_file")
  fi
done <<<"$keys"

if [[ ${#stale[@]} -eq 0 ]]; then
  echo "validate-citations: OK ($checked citation(s) checked in $citations_file)"
  exit 0
fi

echo "validate-citations: FAIL ($checked checked, ${#stale[@]} stale) in $citations_file" >&2
for s in "${stale[@]}"; do
  echo "  - $s" >&2
done
exit 1

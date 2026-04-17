#!/usr/bin/env bash
#
# parse-citations.sh — extract MEMORY_CITED: markers from a worker report
# and emit a JSON delta for state/memory-citations.json.
#
# Input: worker report on stdin, or as a filename argument.
# Output: JSON to stdout of the form
#   {
#     "citations": {
#       "<file.md>#<quote>": {
#         "count_delta": <int>,
#         "tickets_added": [<ticket-ref>, ...]
#       },
#       ...
#     }
#   }
#
# Commander is responsible for merging this delta into
# state/memory-citations.json (incrementing counts, de-duping tickets,
# flipping promotion_threshold_reached, etc.). This script stays stateless.
#
# Worker report format (see .claude/agents/worker-implementation.md step 10):
#   MEMORY_CITED: learnings-CLI.md#"npm install strips peer markers"
# Optional leading ticket ref line in the report, e.g.:
#   TICKET: cli#50
# If TICKET: is present, its value is attached to every citation emitted
# from this report.

set -euo pipefail

MEMORY_DIR_DEFAULT="./memory"

usage() {
  cat <<'EOF'
Usage: parse-citations.sh [--memory-dir <path>] [--ticket <ref>] [<report-file>]

Options:
  --memory-dir <path>   Override memory directory (default: $HYDRA_EXTERNAL_MEMORY_DIR,
                        falls back to ./memory). Currently only used for validation
                        that the referenced file exists; does not rewrite paths.
  --ticket <ref>        Ticket reference to attach to each citation. If not provided,
                        the script looks for a `TICKET: <ref>` line in the report.
                        Falls back to empty tickets_added list.
  -h, --help            Show this help.

Input:
  Worker report on stdin, OR as the last positional argument (a filename).

Output:
  JSON delta on stdout. Commander merges into state/memory-citations.json.

Exit codes:
  0  success (delta emitted; may be empty if no MEMORY_CITED lines found)
  2  usage error
EOF
}

memory_dir=""
ticket_ref=""
input_file=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --memory-dir)
      [[ $# -ge 2 ]] || { echo "parse-citations: --memory-dir needs a value" >&2; usage >&2; exit 2; }
      memory_dir="$2"
      shift 2
      ;;
    --ticket)
      [[ $# -ge 2 ]] || { echo "parse-citations: --ticket needs a value" >&2; usage >&2; exit 2; }
      ticket_ref="$2"
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
      echo "parse-citations: unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
    *)
      if [[ -n "$input_file" ]]; then
        echo "parse-citations: only one positional file argument allowed" >&2
        exit 2
      fi
      input_file="$1"
      shift
      ;;
  esac
done

if [[ -z "$memory_dir" ]]; then
  memory_dir="${HYDRA_EXTERNAL_MEMORY_DIR:-$MEMORY_DIR_DEFAULT}"
fi

# Read report.
if [[ -n "$input_file" ]]; then
  if [[ ! -f "$input_file" ]]; then
    echo "parse-citations: input file not found: $input_file" >&2
    exit 2
  fi
  report_text="$(cat "$input_file")"
else
  report_text="$(cat)"
fi

# If --ticket not provided, try to pull it from a TICKET: line in the report.
if [[ -z "$ticket_ref" ]]; then
  ticket_line="$(printf '%s\n' "$report_text" | grep -E '^TICKET:[[:space:]]*' | head -n1 || true)"
  if [[ -n "$ticket_line" ]]; then
    ticket_ref="$(printf '%s' "$ticket_line" | sed -E 's/^TICKET:[[:space:]]*//')"
  fi
fi

# Extract MEMORY_CITED: lines. Format:
#   MEMORY_CITED: <file>#"<quote>"
# Tolerant of surrounding whitespace. Quote delimiters: straight double quotes.
# Build a TSV stream of "<file>#<quote>" keys (one per line) to feed jq.
keys_tsv="$(printf '%s\n' "$report_text" \
  | grep -E '^[[:space:]]*MEMORY_CITED:' \
  | sed -E 's/^[[:space:]]*MEMORY_CITED:[[:space:]]*//' \
  | sed -E 's/[[:space:]]+$//' \
  || true)"

# Optionally warn (stderr) if a cited file does not exist in the resolved memory_dir.
# Does not change exit code — parse-citations is lenient; validate-citations is strict.
if [[ -d "$memory_dir" ]] && [[ -n "$keys_tsv" ]]; then
  while IFS= read -r key; do
    [[ -z "$key" ]] && continue
    file_part="${key%%#*}"
    if [[ -n "$file_part" ]] && [[ ! -f "$memory_dir/$file_part" ]]; then
      echo "parse-citations: warning: referenced file not found under $memory_dir: $file_part" >&2
    fi
  done <<<"$keys_tsv"
fi

# Build JSON via jq. Count occurrences per key in this single report.
# tickets_added is [ticket_ref] if ticket_ref is non-empty, else [].
if [[ -z "$keys_tsv" ]]; then
  # No citations — emit empty delta.
  jq -n '{citations: {}}'
else
  printf '%s\n' "$keys_tsv" \
    | jq -R -s \
        --arg ticket "$ticket_ref" \
        '
        split("\n")
        | map(select(length > 0))
        | reduce .[] as $k (
            {};
            .[$k] = ((.[$k] // {count_delta: 0, tickets_added: []})
                     | .count_delta += 1
                     | if ($ticket | length) > 0
                         and (.tickets_added | index($ticket) | not)
                       then .tickets_added += [$ticket]
                       else .
                       end)
          )
        | {citations: .}
        '
fi

# --- S3 sync hook ---------------------------------------------------------
# If HYDRA_MEMORY_BACKEND=s3 or s3-strict, push the memory dir to S3. This is
# a no-op for parse-citations (stateless; does not mutate files) but the
# ticket specifies all three memory-layer scripts get the identical hook for
# auditability. Sync output goes to stderr so it never contaminates the JSON
# delta we just emitted on stdout. Spec: docs/specs/2026-04-17-dual-mode-memory.md
if [[ "${HYDRA_MEMORY_BACKEND:-local}" =~ ^s3(-strict)?$ ]]; then
  sync_script="$(dirname "${BASH_SOURCE[0]}")/hydra-memory-sync.sh"
  if [[ -x "$sync_script" ]]; then
    if ! "$sync_script" --push --memory-dir "$memory_dir" >&2; then
      if [[ "${HYDRA_MEMORY_BACKEND}" == "s3-strict" ]]; then
        echo "parse-citations: S3 push failed and backend=s3-strict; exiting" >&2
        exit 1
      fi
      echo "parse-citations: warning — S3 push failed, continuing (backend=s3)" >&2
    fi
  fi
fi

exit 0

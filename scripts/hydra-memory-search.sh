#!/usr/bin/env bash
#
# hydra-memory-search.sh — read-only keyword search over memory/learnings-*.md.
#
# Surfaces the most relevant accumulated learnings for a query so Commander's
# session preamble can be DYNAMIC rather than static. Modeled on gstack's
# learnings-search (preamble pattern) but over Hydra's per-repo learnings files.
#
# Input:  a query (positional, space-joined if multiple words).
# Output: ranked text (default) or JSON (--json) of the form
#   {
#     "query":      "<query>",
#     "limit":      <int>,
#     "memory_dir": "<resolved dir>",
#     "results": [
#       { "file": "learnings-<repo>.md", "repo": "<repo>",
#         "matches": <int>, "snippets": [ "<line>", ... ] },
#       ...
#     ]
#   }
#
# Read-only: never writes to memory/. Files with zero matches are excluded.
# An empty memory dir or a zero-match query is NORMAL (a fresh checkout has no
# learnings yet) — exit 0 with an empty result set, same lenience as
# scripts/parse-citations.sh.
#
# Spec: docs/specs/2026-06-08-dynamic-session-preamble.md
# Ticket: https://github.com/tonychang04/hydra/issues/274

set -euo pipefail

MEMORY_DIR_DEFAULT="./memory"
DEFAULT_LIMIT=5
MAX_SNIPPETS=3      # snippet lines collected per matching file
SNIPPET_MAXLEN=200  # trim long lines so the preamble stays compact

usage() {
  cat <<'EOF'
Usage: hydra-memory-search.sh [options] <query>

Search memory/learnings-*.md for a keyword/phrase, ranked by match count.

Options:
  --memory-dir <path>   Override memory directory (default: $HYDRA_EXTERNAL_MEMORY_DIR,
                        falls back to ./memory).
  --limit <N>           Max number of learnings files to return (default: 5).
  --json                Emit JSON instead of compact text.
  -h, --help            Show this help.

Arguments:
  <query>               One or more words. Multiple words are space-joined and
                        matched as a single case-insensitive substring.

Exit codes:
  0  success (may be an empty result set — that is normal, not an error)
  2  usage error
EOF
}

memory_dir=""
limit="$DEFAULT_LIMIT"
as_json=false
query_parts=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --memory-dir)
      [[ $# -ge 2 ]] || { echo "hydra-memory-search: --memory-dir needs a value" >&2; usage >&2; exit 2; }
      memory_dir="$2"; shift 2 ;;
    --limit)
      [[ $# -ge 2 ]] || { echo "hydra-memory-search: --limit needs a value" >&2; usage >&2; exit 2; }
      limit="$2"; shift 2 ;;
    --json)
      as_json=true; shift ;;
    -h|--help)
      usage; exit 0 ;;
    --)
      shift
      while [[ $# -gt 0 ]]; do query_parts+=("$1"); shift; done
      break ;;
    -*)
      echo "hydra-memory-search: unknown option: $1" >&2; usage >&2; exit 2 ;;
    *)
      query_parts+=("$1"); shift ;;
  esac
done

if [[ ${#query_parts[@]} -eq 0 ]]; then
  echo "hydra-memory-search: a query is required" >&2
  usage >&2
  exit 2
fi
query="${query_parts[*]}"

if ! [[ "$limit" =~ ^[0-9]+$ ]] || [[ "$limit" -lt 1 ]]; then
  echo "hydra-memory-search: --limit must be a positive integer (got: $limit)" >&2
  exit 2
fi

if [[ -z "$memory_dir" ]]; then
  memory_dir="${HYDRA_EXTERNAL_MEMORY_DIR:-$MEMORY_DIR_DEFAULT}"
fi

# ---------------------------------------------------------------------------
# Collect (match_count, file) pairs for every learnings-*.md with >=1 match.
# A missing/empty memory dir yields zero results — that is fine.
# ---------------------------------------------------------------------------
# rows_tsv accumulates "<count>\t<path>" lines for ranking.
rows_tsv=""
if [[ -d "$memory_dir" ]]; then
  shopt -s nullglob
  for f in "$memory_dir"/learnings-*.md; do
    # Skip the tracked example placeholders — they are not real learnings.
    case "$(basename "$f")" in
      learnings-*.example.md) continue ;;
    esac
    # Case-insensitive fixed-string OCCURRENCE count across the file.
    # `grep -o` emits one line per match (not per matching line), so a query
    # repeated several times on a single line still scores correctly. `wc -l`
    # then counts occurrences. Trailing whitespace is stripped from wc output.
    # `grep -o` exits 1 on no match; under `set -o pipefail` that would fail the
    # pipeline, so capture matches first (tolerating exit 1) then count them.
    matches="$(grep -oiF -- "$query" "$f" 2>/dev/null || true)"
    if [[ -n "$matches" ]]; then
      count="$(printf '%s\n' "$matches" | wc -l | tr -d '[:space:]')"
    else
      count=0
    fi
    if [[ "$count" -gt 0 ]]; then
      rows_tsv+="${count}	${f}"$'\n'
    fi
  done
  shopt -u nullglob
fi

# Rank by count desc (stable on filename for ties), cap at limit.
ranked_tsv=""
if [[ -n "$rows_tsv" ]]; then
  ranked_tsv="$(printf '%s' "$rows_tsv" \
    | grep -v '^$' \
    | sort -t$'\t' -k1,1nr -k2,2 \
    | head -n "$limit")"
fi

# ---------------------------------------------------------------------------
# Build a JSONL stream of result objects, then assemble with jq.
# Each line: {file, repo, matches, snippets:[...]}
# ---------------------------------------------------------------------------
results_jsonl=""
if [[ -n "$ranked_tsv" ]]; then
  while IFS=$'\t' read -r count path; do
    [[ -z "$path" ]] && continue
    base="$(basename "$path")"
    repo="${base#learnings-}"
    repo="${repo%.md}"

    # Collect up to MAX_SNIPPETS matching lines, trimmed for length.
    snippets_jsonl=""
    while IFS= read -r line; do
      [[ -z "$line" ]] && continue
      # Strip leading whitespace and collapse for compactness.
      line="${line#"${line%%[![:space:]]*}"}"
      if [[ "${#line}" -gt "$SNIPPET_MAXLEN" ]]; then
        line="${line:0:$SNIPPET_MAXLEN}…"
      fi
      snippets_jsonl+="$(jq -Rn --arg s "$line" '$s')"$'\n'
    done < <(grep -iF -- "$query" "$path" 2>/dev/null | head -n "$MAX_SNIPPETS" || true)

    if [[ -n "$snippets_jsonl" ]]; then
      snippets_arr="$(printf '%s' "$snippets_jsonl" | jq -s '.')"
    else
      snippets_arr='[]'
    fi

    obj="$(jq -cn \
      --arg file "$base" \
      --arg repo "$repo" \
      --argjson matches "$count" \
      --argjson snippets "$snippets_arr" \
      '{file:$file, repo:$repo, matches:$matches, snippets:$snippets}')"
    results_jsonl+="$obj"$'\n'
  done <<< "$ranked_tsv"
fi

if [[ -n "$results_jsonl" ]]; then
  results_arr="$(printf '%s' "$results_jsonl" | jq -s '.')"
else
  results_arr='[]'
fi

if [[ "$as_json" == true ]]; then
  jq -n \
    --arg query "$query" \
    --argjson limit "$limit" \
    --arg memory_dir "$memory_dir" \
    --argjson results "$results_arr" \
    '{query:$query, limit:$limit, memory_dir:$memory_dir, results:$results}'
  exit 0
fi

# ---------------------------------------------------------------------------
# Compact text rendering.
# ---------------------------------------------------------------------------
n="$(printf '%s' "$results_arr" | jq 'length')"
if [[ "$n" -eq 0 ]]; then
  echo "No learnings match \"$query\" under $memory_dir."
  exit 0
fi

echo "Top $n learning file(s) for \"$query\":"
printf '%s' "$results_arr" | jq -r '
  .[] |
  "  • \(.repo)  (\(.matches) match\(if .matches == 1 then "" else "es" end))",
  (.snippets[] | "      \(.)")
'
exit 0

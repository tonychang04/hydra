#!/usr/bin/env bash
#
# retro-metrics.sh — compute per-worker / per-repo contribution + trend
# metrics for the weekly retro.
#
# Commander's weekly retro (docs/specs/2026-04-16-retro-workflow.md) writes
# memory/retros/YYYY-WW.md with six aggregate sections. This helper produces
# the *breakdown* block the operator needs to tune dispatch: which repo stalls
# workers, which repo merges cleanly, which memory entries earned citations
# this week, and which tool keeps flaking. Deterministic and report-only:
# it READS logs + citations and PRINTS markdown. It never spawns, merges,
# labels, or mutates state.
#
# Reads (all optional; missing => "_none in window_"):
#   logs/*.json                       ticket completion logs
#   state/memory-citations.json       citation counts
#
# Each logs/*.json may carry (all optional, jq `// default`):
#   repo, tier, result (merged|pr_opened|stuck), status, worker_type,
#   worker_id, wall_clock_minutes, completed_at (ISO8601), surprises
#   (string or array), flaky_tool (string or array).
#
# Window: a log is in-window when its completed_at is within
#   [now - window_days, now]. If completed_at is absent/unparseable, the
#   file mtime is used as a fallback.
#
# Usage:
#   retro-metrics.sh [options]
#
# Options:
#   --logs-dir <path>        Override logs/ (default: <root>/logs).
#   --citations-file <path>  Override state/memory-citations.json.
#   --window-days <N>        Window size in days (default: 7).
#   --now <ISO8601|epoch>    Anchor "now" for the window (default: current
#                            time). Used by tests for determinism. Accepts an
#                            ISO date (YYYY-MM-DD), a full ISO8601 timestamp,
#                            or a unix epoch integer.
#   --repo <slug>            Restrict to a single repo (default: all).
#   -h, --help               Show this help.
#
# Output (stdout): four `##` markdown sections —
#   Per-repo contribution / Per-worker contribution /
#   Citation leaderboard (active this week) / Flaky-tool hotspots.
#
# Exit codes:
#   0  success (including empty window — sections print "_none in window_").
#   1  unrecoverable (jq missing, citations file malformed).
#   2  usage error.
#
# Integration:
#   Commander's retro procedure appends this output after the six core
#   sections. Safe standalone. Deterministic: same inputs + same --now =>
#   byte-identical stdout.
#
# Spec: docs/specs/2026-06-08-retro-per-worker-trend-metrics.md (ticket #284).

set -euo pipefail

# --- cleanup ----------------------------------------------------------------

_tmp_files=()
_cleanup() {
  for f in "${_tmp_files[@]:+${_tmp_files[@]}}"; do
    [[ -n "$f" && -e "$f" ]] && rm -f "$f"
  done
}
trap _cleanup EXIT

# --- resolve paths ----------------------------------------------------------

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"

LOGS_DIR_DEFAULT="$ROOT_DIR/logs"
CITATIONS_FILE_DEFAULT="$ROOT_DIR/state/memory-citations.json"

# --- arg parse --------------------------------------------------------------

usage() { sed -n '3,52p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

logs_dir="$LOGS_DIR_DEFAULT"
citations_file="$CITATIONS_FILE_DEFAULT"
window_days=7
now_arg=""
repo_filter=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --logs-dir)
      [[ $# -ge 2 ]] || { echo "retro-metrics: --logs-dir needs a value" >&2; exit 2; }
      logs_dir="$2"; shift 2 ;;
    --citations-file)
      [[ $# -ge 2 ]] || { echo "retro-metrics: --citations-file needs a value" >&2; exit 2; }
      citations_file="$2"; shift 2 ;;
    --window-days)
      [[ $# -ge 2 ]] || { echo "retro-metrics: --window-days needs a value" >&2; exit 2; }
      window_days="$2"; shift 2 ;;
    --now)
      [[ $# -ge 2 ]] || { echo "retro-metrics: --now needs a value" >&2; exit 2; }
      now_arg="$2"; shift 2 ;;
    --repo)
      [[ $# -ge 2 ]] || { echo "retro-metrics: --repo needs a value" >&2; exit 2; }
      repo_filter="$2"; shift 2 ;;
    -h|--help)
      usage; exit 0 ;;
    *)
      echo "retro-metrics: unknown argument: $1" >&2; exit 2 ;;
  esac
done

case "$window_days" in
  ''|*[!0-9]*) echo "retro-metrics: --window-days must be a non-negative integer" >&2; exit 2 ;;
esac
# Strip leading zeros so Bash arithmetic does not interpret e.g. "08" as octal.
window_days=$(( 10#$window_days ))

command -v jq >/dev/null 2>&1 || { echo "retro-metrics: jq is required" >&2; exit 1; }

# --- resolve the window epoch bounds ----------------------------------------

# to_epoch <value> -> epoch seconds on stdout, or empty on failure.
# Accepts: epoch int, YYYY-MM-DD, or full ISO8601 (Z, numeric offset, or
# fractional seconds). Portable across BSD (macOS) and GNU date.
to_epoch() {
  local v="$1"
  [[ -z "$v" ]] && return 0
  # Pure integer => already epoch.
  if [[ "$v" =~ ^[0-9]+$ ]]; then printf '%s' "$v"; return 0; fi
  local out=""
  # GNU date handles offsets + fractional seconds natively.
  out="$(date -u -d "$v" +%s 2>/dev/null || true)"
  if [[ -n "$out" ]]; then printf '%s' "$out"; return 0; fi
  # BSD date can't parse offsets/fractional seconds, so normalize first:
  #   - strip a fractional-seconds component (".123")
  #   - convert a trailing numeric offset ("+00:00" / "-0500") to "Z" by
  #     dropping it (timestamps in logs are emitted in UTC; treating a
  #     normalized value as UTC keeps window math stable and deterministic).
  local norm="$v"
  norm="${norm/Z/}"                                  # drop trailing Z if any
  norm="$(printf '%s' "$norm" | sed -E 's/\.[0-9]+//; s/[+-][0-9]{2}:?[0-9]{2}$//')"
  local fmt
  for fmt in "%Y-%m-%dT%H:%M:%S" "%Y-%m-%d %H:%M:%S" "%Y-%m-%d"; do
    out="$(date -u -j -f "$fmt" "$norm" +%s 2>/dev/null || true)"
    [[ -n "$out" ]] && { printf '%s' "$out"; return 0; }
  done
  return 0
}

if [[ -n "$now_arg" ]]; then
  now_epoch="$(to_epoch "$now_arg")"
  [[ -n "$now_epoch" ]] || { echo "retro-metrics: could not parse --now '$now_arg'" >&2; exit 2; }
else
  now_epoch="$(date -u +%s)"
fi
window_start_epoch=$(( now_epoch - window_days * 86400 ))

# --- collect in-window logs into a single JSON array ------------------------

# Build a JSON array of normalized log records that fall inside the window.
# Each record: {repo, result, stuck(bool), shipped(bool), worker, wall, tools[]}
records_file="$(mktemp -t retro-metrics.XXXXXX)"
_tmp_files+=("$records_file")
printf '[]' > "$records_file"

records_json='[]'

if [[ -d "$logs_dir" ]]; then
  while IFS= read -r f; do
    [[ -n "$f" ]] || continue
    [[ "$(basename "$f")" == ".gitkeep" ]] && continue
    jq -e . "$f" >/dev/null 2>&1 || continue   # skip non-JSON

    # Determine completed_at epoch (fallback to file mtime).
    ca="$(jq -r '.completed_at // empty' "$f" 2>/dev/null || true)"
    ca_epoch="$(to_epoch "$ca")"
    if [[ -z "$ca_epoch" ]]; then
      # Portable mtime: GNU `stat -c %Y`, BSD `stat -f %m`. NOT `date -r <file>`
      # (BSD `date -r` expects an epoch int, not a path).
      ca_epoch="$(stat -c %Y "$f" 2>/dev/null || stat -f %m "$f" 2>/dev/null || date -u +%s)"
    fi
    # Window check (inclusive).
    (( ca_epoch >= window_start_epoch && ca_epoch <= now_epoch )) || continue

    # Optional repo filter.
    if [[ -n "$repo_filter" ]]; then
      rfile="$(jq -r '.repo // ""' "$f" 2>/dev/null || true)"
      [[ "$rfile" == "$repo_filter" ]] || continue
    fi

    # Normalize one record via jq. Coerce scalar fields to strings so an
    # object/array-valued field can't break a downstream section; skip records
    # that carry no identifying signal at all (e.g. `{}` or unrelated JSON).
    rec="$(jq -c '
      def asarr(x): if (x|type)=="array" then x
                    elif (x==null) then []
                    else [x] end;
      # str(x): scalar -> its string form; object/array/null -> "".
      def str(x): if (x|type) as $t | ($t=="string" or $t=="number" or $t=="boolean")
                  then (x|tostring) else "" end;
      {
        repo:   (str(.repo)),
        result: (str(.result)),
        status: (str(.status)),
        worker: (if str(.worker_type) != "" then str(.worker_type)
                 else str(.worker_id) end),
        wall:   ((.wall_clock_minutes // 0) | (try tonumber catch 0)),
        # flaky tool signal: explicit .flaky_tool plus any surprises that
        # name a tool via the "flaky-tool: <name>" convention.
        tools:  ( (asarr(.flaky_tool) | map(select(type=="string")))
                  + ( asarr(.surprises)
                      | map( select(type=="string")
                             | capture("flaky[- ]tool:?\\s*(?<t>[A-Za-z0-9_./-]+)"; "i")
                             | .t ) ) )
      }
      # Drop records with no identity (no repo, worker, result, or status and
      # no flaky-tool signal) — they are not completions.
      | select( (.repo != "") or (.worker != "") or (.result != "")
                or (.status != "") or ((.tools | length) > 0) )
      # Backfill display placeholders AFTER the identity check.
      | .repo   = (if .repo   == "" then "—" else .repo   end)
      | .worker = (if .worker == "" then "—" else .worker end)
      | .stuck   = ( (.result=="stuck")
                     or (.status=="stuck") or (.status=="failed")
                     or (.status=="paused-on-question")
                     or (.status=="paused_on_question") )
      | .shipped = ( (.result=="merged") or (.result=="pr_opened") )
    ' "$f" 2>/dev/null || true)"
    [[ -n "$rec" ]] || continue
    records_json="$(jq -c --argjson r "$rec" '. + [$r]' <<<"$records_json")"
  done < <(find "$logs_dir" -maxdepth 1 -type f -name '*.json' 2>/dev/null | sort)
fi

printf '%s' "$records_json" > "$records_file"

# --- section 1: per-repo contribution ---------------------------------------

echo "## Per-repo contribution"
echo
repo_rows="$(jq -r '
  group_by(.repo)
  | map({
      repo: .[0].repo,
      total: length,
      merged: (map(select(.result=="merged")) | length),
      opened: (map(select(.result=="pr_opened")) | length),
      stuck:  (map(select(.stuck)) | length)
    })
  | sort_by(-.total, .repo)
  | .[]
  | [ .repo, (.merged|tostring), (.opened|tostring), (.stuck|tostring),
      ( if .total>0 then ((.merged*100/.total)|floor|tostring)+"%" else "—" end),
      ( if .total>0 then ((.stuck*100/.total)|floor|tostring)+"%" else "—" end)
    ] | @tsv
' "$records_file" 2>/dev/null || true)"

if [[ -z "$repo_rows" ]]; then
  echo "_none in window_"
else
  echo "| Repo | Merged | PR open | Stuck | Merge rate | Stuck rate |"
  echo "|---|---|---|---|---|---|"
  while IFS=$'\t' read -r repo merged opened stuck mrate srate; do
    [[ -n "$repo" ]] || continue
    echo "| ${repo//|/\\|} | $merged | $opened | $stuck | $mrate | $srate |"
  done <<<"$repo_rows"
fi
echo

# --- section 2: per-worker contribution -------------------------------------

echo "## Per-worker contribution"
echo
worker_rows="$(jq -r '
  group_by(.worker)
  | map({
      worker: .[0].worker,
      total: length,
      shipped: (map(select(.shipped)) | length),
      stuck:   (map(select(.stuck)) | length),
      wall:    (map(.wall) | add // 0)
    })
  | sort_by(-.total, .worker)
  | .[]
  | [ .worker, (.total|tostring), (.shipped|tostring), (.stuck|tostring),
      (.wall|tostring) ] | @tsv
' "$records_file" 2>/dev/null || true)"

if [[ -z "$worker_rows" ]]; then
  echo "_none in window_"
else
  echo "| Worker | Completions | Shipped | Stuck | Wall-clock (min) |"
  echo "|---|---|---|---|---|"
  while IFS=$'\t' read -r worker total shipped stuck wall; do
    [[ -n "$worker" ]] || continue
    echo "| ${worker//|/\\|} | $total | $shipped | $stuck | $wall |"
  done <<<"$worker_rows"
fi
echo

# --- section 3: citation leaderboard (active this week) ---------------------

echo "## Citation leaderboard (active this week)"
echo
cite_rows=""
if [[ -f "$citations_file" ]]; then
  jq -e . "$citations_file" >/dev/null 2>&1 || {
    echo "retro-metrics: malformed citations file: $citations_file" >&2; exit 1; }
  # Structural guard: `.citations` (when present) MUST be an object. A wrong
  # top-level shape is a real corruption => exit 1 (loud, per Codex review).
  jq -e '(.citations == null) or (.citations | type == "object")' \
    "$citations_file" >/dev/null 2>&1 || {
    echo "retro-metrics: .citations is not an object in $citations_file" >&2; exit 1; }
  # Individual non-object entries (e.g. a string value) are skipped with a
  # stderr WARN rather than aborting the whole retro — report-only resilience.
  bad_entries="$(jq -r '
    (.citations // {}) | to_entries
    | map(select(((.key | startswith("_")) | not) and (.value | type != "object")))
    | length' "$citations_file" 2>/dev/null || echo 0)"
  if [[ "${bad_entries:-0}" -gt 0 ]]; then
    echo "retro-metrics: WARN skipping $bad_entries non-object citation entr(y/ies) in $citations_file" >&2
  fi
  # An entry is "active this week" when its last_cited is in-window.
  # Window bounds passed as ISO dates for string comparison (YYYY-MM-DD sorts
  # lexically == chronologically).
  ws_date="$(date -u -r "$window_start_epoch" +%Y-%m-%d 2>/dev/null \
             || date -u -d "@$window_start_epoch" +%Y-%m-%d 2>/dev/null || echo "0000-00-00")"
  now_date="$(date -u -r "$now_epoch" +%Y-%m-%d 2>/dev/null \
              || date -u -d "@$now_epoch" +%Y-%m-%d 2>/dev/null || echo "9999-99-99")"
  # Note: errors are NOT swallowed here — a structurally malformed citations
  # file (e.g. a non-object .citations, or a non-object entry that defeats the
  # object-guard) makes jq exit non-zero, which we promote to exit 1 below.
  if ! cite_rows="$(jq -r --arg ws "$ws_date" --arg ne "$now_date" '
    (.citations // {})
    | to_entries
    # Skip meta keys ("_comment") and any entry whose value is not an object.
    | map(select(((.key | startswith("_")) | not) and (.value | type == "object")))
    | map(select((.value.last_cited // null) != null
                 and (.value.last_cited | type == "string")
                 and .value.last_cited >= $ws
                 and .value.last_cited <= $ne))
    | map({
        key: .key,
        count: ((.value.count // 0) | (try tonumber catch 0)),
        last: (.value.last_cited // "—"),
        promo: (.value.promotion_threshold_reached // false),
        tickets: ((.value.tickets // []) | (if type=="array" then length else 0 end))
      })
    | sort_by(-.count, .key)
    | .[]
    | [ .key, (.count|tostring), (.tickets|tostring), .last,
        (if .promo then "yes" else "no" end) ] | @tsv
  ' "$citations_file")"; then
    echo "retro-metrics: malformed citations file: $citations_file" >&2
    exit 1
  fi
fi

if [[ -z "$cite_rows" ]]; then
  echo "_none in window_"
else
  echo "| Entry | Count | Tickets | Last cited | Promotion-ready |"
  echo "|---|---|---|---|---|"
  while IFS=$'\t' read -r key count tickets last promo; do
    [[ -n "$key" ]] || continue
    # Escape pipe chars in the key so the table stays well-formed.
    safe_key="${key//|/\\|}"
    echo "| $safe_key | $count | $tickets | $last | $promo |"
  done <<<"$cite_rows"
fi
echo

# --- section 4: flaky-tool hotspots -----------------------------------------

echo "## Flaky-tool hotspots"
echo
tool_rows="$(jq -r '
  [ .[].tools[] ]
  | group_by(.)
  | map({tool: .[0], n: length})
  | sort_by(-.n, .tool)
  | .[]
  | [ .tool, (.n|tostring) ] | @tsv
' "$records_file" 2>/dev/null || true)"

if [[ -z "$tool_rows" ]]; then
  echo "_none in window_"
else
  echo "| Tool | Flaky retries |"
  echo "|---|---|"
  while IFS=$'\t' read -r tool n; do
    [[ -n "$tool" ]] || continue
    echo "| ${tool//|/\\|} | $n |"
  done <<<"$tool_rows"
fi

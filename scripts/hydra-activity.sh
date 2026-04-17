#!/usr/bin/env bash
#
# hydra-activity.sh — text-based observability layer. Summarizes the last 24h
# of Hydra activity plus a live snapshot of active / stuck workers, top memory
# citations, and retro counts. Read-only: never writes to any state file.
#
# Spec: docs/specs/2026-04-17-hydra-activity.md (ticket #19)
# Companion scripts: hydra-status.sh (scalar "right now" snapshot) and the
# Commander `retro` command (weekly synthesis). Activity is the 24h middle
# layer between those two.
#
# Usage:
#   ./hydra activity                      Human-readable table (default)
#   ./hydra activity --json               Machine-parseable JSON envelope
#   ./hydra activity --window-hours N     Override 24h lookback (default 24)
#   ./hydra activity --logs-dir <path>    Override logs dir (test / fixture use)
#   ./hydra activity --state-dir <path>   Override state/ dir
#   ./hydra activity --memory-dir <path>  Override memory/ dir (retros count)
#   ./hydra activity -h | --help          Print this banner.
#
# Exit codes:
#   0   OK (including when some state files are missing — degrades to 0/empty)
#   2   usage error (bad flag, unknown arg)

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"

# shellcheck disable=SC1091
[[ -f "$ROOT_DIR/.hydra.env" ]] && source "$ROOT_DIR/.hydra.env"

usage() {
  cat <<'EOF'
Usage: ./hydra activity [options]

Text-based observability: last 24h of Hydra activity + live worker snapshot.

Sections:
  Completed (last 24h)       per-ticket rows from logs/*.json
  Active right now           state/active.json workers with status=running
  Stuck                      active.json workers with status paused-on-question or failed
  Memory citations top 5     state/memory-citations.json, sorted by count, last 7d
  Retros on disk             count + latest file from memory/retros/*.md

Options:
  --json                     Emit a JSON envelope instead of the text table.
  --window-hours N           Override 24h lookback window. Default 24.
  --logs-dir <path>          Override logs dir (default $ROOT/logs).
  --state-dir <path>         Override state dir (default $ROOT/state).
  --memory-dir <path>        Override memory dir (default $HYDRA_EXTERNAL_MEMORY_DIR
                             if set, else $ROOT/memory).
  -h, --help                 Show this help.

Does NOT launch a Claude session. Safe for scripts / cron / SSH.
Does NOT write to any state file. Read-only observability.
EOF
}

# -----------------------------------------------------------------------------
# color handling — matches hydra-status.sh
# -----------------------------------------------------------------------------
if [[ -t 1 ]] && [[ "${NO_COLOR:-}" != "1" ]]; then
  C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'; C_GREEN=$'\033[32m'; C_RED=$'\033[31m'
  C_YELLOW=$'\033[33m'; C_RESET=$'\033[0m'
else
  C_BOLD=""; C_DIM=""; C_GREEN=""; C_RED=""; C_YELLOW=""; C_RESET=""
fi

# -----------------------------------------------------------------------------
# argument parsing
# -----------------------------------------------------------------------------
mode="human"
window_hours=24
logs_dir_override=""
state_dir_override=""
memory_dir_override=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --json) mode="json"; shift ;;
    --window-hours)
      [[ $# -ge 2 ]] || { echo "✗ --window-hours requires a value" >&2; exit 2; }
      window_hours="$2"; shift 2
      ;;
    --logs-dir)
      [[ $# -ge 2 ]] || { echo "✗ --logs-dir requires a path" >&2; exit 2; }
      logs_dir_override="$2"; shift 2
      ;;
    --state-dir)
      [[ $# -ge 2 ]] || { echo "✗ --state-dir requires a path" >&2; exit 2; }
      state_dir_override="$2"; shift 2
      ;;
    --memory-dir)
      [[ $# -ge 2 ]] || { echo "✗ --memory-dir requires a path" >&2; exit 2; }
      memory_dir_override="$2"; shift 2
      ;;
    *)
      echo "✗ unknown arg: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

# sanity: window_hours must be a positive integer
if ! [[ "$window_hours" =~ ^[1-9][0-9]*$ ]]; then
  echo "✗ --window-hours must be a positive integer (got: $window_hours)" >&2
  exit 2
fi

LOGS_DIR="${logs_dir_override:-$ROOT_DIR/logs}"
STATE_DIR="${state_dir_override:-$ROOT_DIR/state}"
MEMORY_DIR="${memory_dir_override:-${HYDRA_EXTERNAL_MEMORY_DIR:-$ROOT_DIR/memory}}"

# -----------------------------------------------------------------------------
# helpers
# -----------------------------------------------------------------------------
# jq_or <file> <filter> <fallback>  —  defensive read that never errors out
jq_or() {
  local f="$1" filter="$2" fb="$3"
  if [[ -f "$f" ]] && jq empty "$f" 2>/dev/null; then
    jq -r "$filter" "$f" 2>/dev/null || printf '%s' "$fb"
  else
    printf '%s' "$fb"
  fi
}

# age_minutes <iso_timestamp> — minutes elapsed since timestamp (integer), or
# empty string if the timestamp is missing or can't be parsed. Portable across
# GNU and BSD date.
age_minutes() {
  local ts="$1"
  [[ -z "$ts" || "$ts" == "null" ]] && { printf ''; return; }
  local epoch=""
  if date -d "$ts" +%s >/dev/null 2>&1; then
    epoch="$(date -d "$ts" +%s)"
  elif date -j -f "%Y-%m-%dT%H:%M:%SZ" "$ts" +%s >/dev/null 2>&1; then
    epoch="$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$ts" +%s)"
  elif date -j -f "%Y-%m-%dT%H:%M:%S" "${ts%Z}" +%s >/dev/null 2>&1; then
    epoch="$(date -j -f "%Y-%m-%dT%H:%M:%S" "${ts%Z}" +%s)"
  fi
  [[ -z "$epoch" ]] && { printf ''; return; }
  local now; now="$(date +%s)"
  printf '%d' "$(( (now - epoch) / 60 ))"
}

# truncate_field <text> <maxlen>
truncate_field() {
  local s="$1" n="$2"
  if [[ ${#s} -le $n ]]; then
    printf '%s' "$s"
  else
    printf '%s…' "${s:0:$((n-1))}"
  fi
}

# -----------------------------------------------------------------------------
# gather data
# -----------------------------------------------------------------------------

# --- completed logs in window -------------------------------------------------
# Find log files whose mtime is within $window_hours (per the spec, mtime is
# the authoritative "recently completed" signal — `completed_at` inside the
# JSON is flexible and sometimes absent on older logs).
completed_tickets=""
completed_count=0

if [[ -d "$LOGS_DIR" ]]; then
  # Use a negative minutes expression for find -mmin; width ≠ 60 * hours.
  mmin=$(( window_hours * 60 ))
  # IFS+while over null-delimited output so paths with spaces survive.
  while IFS= read -r -d '' f; do
    # only JSON files
    [[ "$f" == *.json ]] || continue
    # defensively skip malformed JSON — show as zero-row rather than crash
    jq empty "$f" 2>/dev/null || continue
    completed_count=$((completed_count + 1))
    # build one row per ticket; tab-separated for easy pick-apart below
    row="$(jq -r \
      --arg file "$(basename "$f")" \
      '[
        (.ticket // $file),
        (.repo // "—"),
        (.tier // "—"),
        (.result // "—"),
        (if (.pr_url // null) == null or (.pr_url // "") == "" then "—" else (.pr_url | sub("https://github.com/"; "") | sub("/pull/"; "#")) end),
        (if (.wall_clock_minutes // null) == null then "—" else (.wall_clock_minutes | tostring) end)
      ] | @tsv' "$f")"
    completed_tickets+="$row"$'\n'
  done < <(find "$LOGS_DIR" -maxdepth 1 -type f -name '*.json' -mmin -"$mmin" -print0 2>/dev/null)
fi

# --- active snapshot ----------------------------------------------------------
active_file="$STATE_DIR/active.json"
active_running_rows=""
active_running_count=0
stuck_rows=""
stuck_count=0

if [[ -f "$active_file" ]] && jq empty "$active_file" 2>/dev/null; then
  # running workers
  while IFS= read -r row; do
    [[ -z "$row" ]] && continue
    active_running_count=$((active_running_count + 1))
    active_running_rows+="$row"$'\n'
  done < <(jq -r '(.workers // [])
    | map(select(.status == "running"))
    | .[]
    | [
        (.id // "—"),
        (.ticket // "—"),
        (.tier // "—"),
        (.status // "—"),
        (.started_at // "")
      ]
    | @tsv' "$active_file")

  # stuck workers (paused-on-question, paused_on_question, failed)
  while IFS= read -r row; do
    [[ -z "$row" ]] && continue
    stuck_count=$((stuck_count + 1))
    stuck_rows+="$row"$'\n'
  done < <(jq -r '(.workers // [])
    | map(select(.status == "paused-on-question"
                 or .status == "paused_on_question"
                 or .status == "failed"))
    | .[]
    | [
        (.ticket // "—"),
        (.repo // "—"),
        (.status // "—"),
        ((.last_question // .failure_reason // "—") | tostring)
      ]
    | @tsv' "$active_file")
fi

# --- memory citations (top 5 in last 7d) --------------------------------------
citations_file="$STATE_DIR/memory-citations.json"
citations_top_rows=""
citations_top_count=0

if [[ -f "$citations_file" ]] && jq empty "$citations_file" 2>/dev/null; then
  # Compute YYYY-MM-DD for today-7 in a portable way.
  if date -v-7d '+%Y-%m-%d' >/dev/null 2>&1; then
    since="$(date -v-7d '+%Y-%m-%d')"
  else
    since="$(date -d '7 days ago' '+%Y-%m-%d')"
  fi
  while IFS= read -r row; do
    [[ -z "$row" ]] && continue
    citations_top_count=$((citations_top_count + 1))
    citations_top_rows+="$row"$'\n'
  done < <(jq -r --arg since "$since" '
    (.citations // {})
    | to_entries
    | map(select((.value.last_cited // "1970-01-01") >= $since))
    | sort_by(-(.value.count // 0))
    | .[0:5]
    | .[]
    | [(.value.count // 0 | tostring), .key]
    | @tsv' "$citations_file")
fi

# --- retros count + latest -----------------------------------------------------
retros_dir="$MEMORY_DIR/retros"
retros_count=0
retros_latest="(none)"
if [[ -d "$retros_dir" ]]; then
  # natural sort; any *.md file counts. Avoid mapfile (bash 3.2 on macOS
  # doesn't have it); use a while-read loop instead.
  retros=()
  while IFS= read -r f; do
    retros+=("$f")
  done < <(find "$retros_dir" -maxdepth 1 -type f -name '*.md' 2>/dev/null | LC_ALL=C sort)
  retros_count="${#retros[@]}"
  if [[ "$retros_count" -gt 0 ]]; then
    retros_latest="${retros[$((retros_count - 1))]}"
    # Make path relative-ish for readability.
    retros_latest="${retros_latest#"$ROOT_DIR/"}"
  fi
fi

# -----------------------------------------------------------------------------
# render: JSON mode
# -----------------------------------------------------------------------------
if [[ "$mode" == "json" ]]; then
  # Build the envelope entirely in jq so each field is correctly quoted /
  # escaped; feed the captured rows as raw tsv via --rawfile and parse inside.
  tmp_completed="$(mktemp)"; tmp_active="$(mktemp)"; tmp_stuck="$(mktemp)"; tmp_cit="$(mktemp)"
  trap 'rm -f "$tmp_completed" "$tmp_active" "$tmp_stuck" "$tmp_cit"' EXIT
  printf '%s' "$completed_tickets" > "$tmp_completed"
  printf '%s' "$active_running_rows" > "$tmp_active"
  printf '%s' "$stuck_rows" > "$tmp_stuck"
  printf '%s' "$citations_top_rows" > "$tmp_cit"

  jq -n \
    --arg generated_at "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
    --argjson window_hours "$window_hours" \
    --rawfile completed "$tmp_completed" \
    --rawfile active "$tmp_active" \
    --rawfile stuck "$tmp_stuck" \
    --rawfile citations "$tmp_cit" \
    --argjson retros_count "$retros_count" \
    --arg retros_latest "$retros_latest" \
    '
    def tsv2rows(keys; text):
      (text | split("\n") | map(select(length > 0))
        | map(split("\t"))
        | map(. as $row | reduce range(0; keys|length) as $i ({};
            .[keys[$i]] = ($row[$i] // "")
          )));
    {
      generated_at: $generated_at,
      window_hours: $window_hours,
      completed: tsv2rows(["ticket","repo","tier","result","pr","minutes"]; $completed),
      active:    tsv2rows(["id","ticket","tier","status","started_at"]; $active),
      stuck:     tsv2rows(["ticket","repo","status","reason"]; $stuck),
      citations_top: tsv2rows(["count","entry"]; $citations),
      retros: { count: $retros_count, latest: $retros_latest }
    }
    '
  exit 0
fi

# -----------------------------------------------------------------------------
# render: human mode
# -----------------------------------------------------------------------------
printf "%s▸ Hydra activity — last %sh%s\n" "$C_BOLD" "$window_hours" "$C_RESET"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# --- Completed ---
printf "%sCompleted (last 24h):%s %s\n" "$C_BOLD" "$C_RESET" "$completed_count"
if [[ "$completed_count" -gt 0 ]]; then
  {
    printf "TICKET\tREPO\tTIER\tRESULT\tPR\tMIN\n"
    # strip trailing newline before piping to column
    printf '%s' "$completed_tickets"
  } | column -t -s $'\t' | sed 's/^/  /'
else
  printf "  %s(no completions in the last %sh)%s\n" "$C_DIM" "$window_hours" "$C_RESET"
fi
echo

# --- Active ---
printf "%sActive right now:%s %s\n" "$C_BOLD" "$C_RESET" "$active_running_count"
if [[ "$active_running_count" -gt 0 ]]; then
  rendered=""
  while IFS=$'\t' read -r id tkt tier status started_at; do
    [[ -z "$id" ]] && continue
    age_min="$(age_minutes "$started_at")"
    [[ -z "$age_min" ]] && age_min="—"
    rendered+="$id"$'\t'"$tkt"$'\t'"$tier"$'\t'"$status"$'\t'"${age_min}m"$'\n'
  done <<<"$active_running_rows"
  {
    printf "ID\tTICKET\tTIER\tSTATUS\tAGE\n"
    printf '%s' "$rendered"
  } | column -t -s $'\t' | sed 's/^/  /'
else
  printf "  %s(no running workers)%s\n" "$C_DIM" "$C_RESET"
fi
echo

# --- Stuck ---
printf "%sStuck (paused-on-question or failed):%s %s\n" "$C_BOLD" "$C_RESET" "$stuck_count"
if [[ "$stuck_count" -gt 0 ]]; then
  rendered=""
  while IFS=$'\t' read -r tkt repo status reason; do
    [[ -z "$tkt" ]] && continue
    reason_trunc="$(truncate_field "$reason" 60)"
    rendered+="$tkt"$'\t'"$repo"$'\t'"$status"$'\t'"$reason_trunc"$'\n'
  done <<<"$stuck_rows"
  {
    printf "TICKET\tREPO\tSTATUS\tREASON\n"
    printf '%s' "$rendered"
  } | column -t -s $'\t' | sed 's/^/  /'
else
  printf "  %s(nothing stuck)%s\n" "$C_DIM" "$C_RESET"
fi
echo

# --- Memory citations (top 5) ---
printf "%sMemory citations: top 5 of last 7d%s\n" "$C_BOLD" "$C_RESET"
if [[ "$citations_top_count" -gt 0 ]]; then
  rendered=""
  while IFS=$'\t' read -r count entry; do
    [[ -z "$count" ]] && continue
    rendered+="$count"$'\t'"$entry"$'\n'
  done <<<"$citations_top_rows"
  {
    printf "COUNT\tENTRY\n"
    printf '%s' "$rendered"
  } | column -t -s $'\t' | sed 's/^/  /'
else
  printf "  %s(no recent citations)%s\n" "$C_DIM" "$C_RESET"
fi
echo

# --- Retros ---
printf "%sRetros on disk:%s %s" "$C_BOLD" "$C_RESET" "$retros_count"
if [[ "$retros_count" -gt 0 ]]; then
  printf " (latest: %s)" "$retros_latest"
fi
printf "\n"

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
exit 0

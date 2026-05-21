#!/usr/bin/env bash
#
# build-board.sh — render the Hydra "Command Center" board.
#
# A single glanceable Markdown board grouping every worker by lifecycle state
# (Running / Paused-on-question / Rescued / Complete / Failed), one row each
# with: ticket (as a GitHub link), age (from started_at), tier, subagent_type,
# and a one-line summary of the worker's log if present.
#
# Reads (both optional; missing = empty fleet / empty cell):
#   state/active.json    in-flight workers (schema state/schemas/active.schema.json)
#   logs/<N>.json        per-ticket completion logs, keyed by ticket number
#
# Writes: state/board.md (a gitignored runtime artifact) AND prints the same
# Markdown to stdout. Read-only with respect to all inputs.
#
# Usage:
#   scripts/build-board.sh
#   scripts/build-board.sh --state-dir <path> --logs-dir <path> --out <path>
#   scripts/build-board.sh --now <iso8601>   # deterministic age (tests)
#   scripts/build-board.sh --no-write        # stdout only, no file
#
# Exit codes:
#   0   board rendered
#   2   usage error (unknown flag)
#
# Spec: docs/specs/2026-05-21-command-center-board.md (ticket #193)
# Style mirrors scripts/build-daily-digest.sh.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"

usage() {
  cat <<'EOF'
Usage: build-board.sh [options]

Render the Hydra Command Center board (workers grouped by lifecycle state).
Writes state/board.md and prints the same Markdown to stdout. Read-only inputs.

Options:
  --state-dir <path>   Override state/ dir (default $ROOT/state)
  --logs-dir <path>    Override logs/ dir (default $ROOT/logs)
  --out <path>         Override output file (default <state-dir>/board.md)
  --now <iso8601>      Override "now" used for age math (deterministic tests).
  --no-write           Print to stdout only; do not write the board file.
  -h, --help           Show this help.

Exit codes:
  0 success · 2 usage error
EOF
}

# -----------------------------------------------------------------------------
# argument parsing
# -----------------------------------------------------------------------------
state_dir_override=""
logs_dir_override=""
out_override=""
now_override=""
no_write=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --state-dir)   state_dir_override="${2:-}"; shift 2 ;;
    --logs-dir)    logs_dir_override="${2:-}"; shift 2 ;;
    --out)         out_override="${2:-}"; shift 2 ;;
    --now)         now_override="${2:-}"; shift 2 ;;
    --no-write)    no_write=1; shift ;;
    --state-dir=*) state_dir_override="${1#--state-dir=}"; shift ;;
    --logs-dir=*)  logs_dir_override="${1#--logs-dir=}"; shift ;;
    --out=*)       out_override="${1#--out=}"; shift ;;
    --now=*)       now_override="${1#--now=}"; shift ;;
    *) echo "build-board: unknown arg '$1'" >&2; usage >&2; exit 2 ;;
  esac
done

# -----------------------------------------------------------------------------
# resolve paths
# -----------------------------------------------------------------------------
STATE_DIR="${state_dir_override:-$ROOT_DIR/state}"
LOGS_DIR="${logs_dir_override:-$ROOT_DIR/logs}"
OUT_FILE="${out_override:-$STATE_DIR/board.md}"
ACTIVE_FILE="$STATE_DIR/active.json"

# -----------------------------------------------------------------------------
# helpers
# -----------------------------------------------------------------------------

# Resolve "now" as an epoch second. Honors --now (ISO-8601). Falls back to the
# current time. Tolerates GNU vs BSD date.
now_epoch() {
  if [[ -n "$now_override" ]]; then
    iso_to_epoch "$now_override"
  else
    date +%s
  fi
}

# Convert an ISO-8601 timestamp to epoch seconds. Echoes empty on failure.
# Handles both GNU date (-d) and BSD date (-j -f). Strips a trailing 'Z' and
# any fractional seconds, normalizing to "YYYY-MM-DDTHH:MM:SS".
iso_to_epoch() {
  local ts="$1"
  [[ -n "$ts" ]] || { echo ""; return; }
  # Normalize: drop fractional seconds and timezone suffix, treat as UTC.
  local norm="${ts%%.*}"      # strip ".123" fractional
  norm="${norm%%+*}"          # strip "+00:00" offset (best-effort)
  norm="${norm%Z}"            # strip trailing Z
  # GNU date
  if date -u -d "${norm}Z" +%s >/dev/null 2>&1; then
    date -u -d "${norm}Z" +%s
    return
  fi
  # BSD date
  if date -u -j -f "%Y-%m-%dT%H:%M:%S" "$norm" +%s >/dev/null 2>&1; then
    date -u -j -f "%Y-%m-%dT%H:%M:%S" "$norm" +%s
    return
  fi
  echo ""
}

# Humanize a duration in seconds into "Nm" / "NhMm" / "NdMh". Negative or
# unparseable → "?".
humanize_age() {
  local secs="$1"
  [[ "$secs" =~ ^-?[0-9]+$ ]] || { echo "?"; return; }
  (( secs < 0 )) && { echo "?"; return; }
  local d=$(( secs / 86400 ))
  local h=$(( (secs % 86400) / 3600 ))
  local m=$(( (secs % 3600) / 60 ))
  if (( d > 0 )); then
    echo "${d}d${h}h"
  elif (( h > 0 )); then
    echo "${h}h${m}m"
  else
    echo "${m}m"
  fi
}

# Render a ticket reference as a Markdown GitHub link when it parses as
# "owner/repo#N"; otherwise echo it verbatim (bare "repo#N", "LIN-123", etc.).
render_ticket() {
  local ticket="$1"
  # owner/repo#N  → link to /issues/N
  if [[ "$ticket" =~ ^([^/[:space:]]+)/([^#/[:space:]]+)#([0-9]+)$ ]]; then
    local owner="${BASH_REMATCH[1]}"
    local repo="${BASH_REMATCH[2]}"
    local num="${BASH_REMATCH[3]}"
    echo "[${ticket}](https://github.com/${owner}/${repo}/issues/${num})"
  else
    echo "$ticket"
  fi
}

# Extract the trailing "#N" issue number from a ticket ref, or empty.
ticket_number() {
  local ticket="$1"
  if [[ "$ticket" =~ \#([0-9]+)$ ]]; then
    echo "${BASH_REMATCH[1]}"
  else
    echo ""
  fi
}

# Render a one-line log summary for a ticket, looked up as logs/<N>.json.
# Format: "<result> (#<pr>, <N>m)" with optional pieces omitted gracefully.
# Empty string when no log file or no usable fields.
render_log_line() {
  local ticket="$1"
  local num
  num="$(ticket_number "$ticket")"
  [[ -n "$num" ]] || { echo ""; return; }
  local logf="$LOGS_DIR/$num.json"
  [[ -f "$logf" ]] || { echo ""; return; }

  local result pr_url wall pr_ref
  result="$(jq -r '.result // empty' "$logf" 2>/dev/null || true)"
  pr_url="$(jq -r '.pr_url // empty' "$logf" 2>/dev/null || true)"
  wall="$(jq -r '.wall_clock_minutes // empty' "$logf" 2>/dev/null || true)"

  # Build the parenthetical: "#502, 23m" — drop pieces that are absent.
  pr_ref=""
  if [[ -n "$pr_url" ]]; then
    pr_ref="#${pr_url##*/}"
  fi
  local paren=""
  if [[ -n "$pr_ref" && -n "$wall" ]]; then
    paren=" (${pr_ref}, ${wall}m)"
  elif [[ -n "$pr_ref" ]]; then
    paren=" (${pr_ref})"
  elif [[ -n "$wall" ]]; then
    paren=" (${wall}m)"
  fi

  if [[ -n "$result" ]]; then
    echo "${result}${paren}"
  elif [[ -n "$paren" ]]; then
    # No result but we have a PR/time — strip the leading space.
    echo "${paren# }"
  else
    echo ""
  fi
}

# -----------------------------------------------------------------------------
# gather workers
# -----------------------------------------------------------------------------
# Each worker is emitted as a TAB-separated record:
#   status \t ticket \t started_at \t tier \t subagent_type
# (TAB chosen because none of those fields contain tabs.)
workers_tsv=""
worker_count=0
if [[ -f "$ACTIVE_FILE" ]]; then
  workers_tsv="$(jq -r '
    .workers[]? |
    [ (.status // "unknown"),
      (.ticket // "?"),
      (.started_at // ""),
      (.tier // "?"),
      (.subagent_type // "?") ] | @tsv
  ' "$ACTIVE_FILE" 2>/dev/null || true)"
  if [[ -n "$workers_tsv" ]]; then
    worker_count="$(printf '%s\n' "$workers_tsv" | grep -c . || true)"
  fi
fi

NOW="$(now_epoch)"
# Generated timestamp for the header (UTC ISO-8601).
if [[ -n "$now_override" ]]; then
  GEN_TS="$now_override"
else
  GEN_TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
fi

# -----------------------------------------------------------------------------
# render
# -----------------------------------------------------------------------------

# Buffer the full board so stdout and the file are byte-identical.
render_board() {
  printf '# Hydra Command Center\n\n'
  printf '_Generated %s · %s worker' "$GEN_TS" "$worker_count"
  (( worker_count == 1 )) || printf 's'
  printf '_\n'

  if (( worker_count == 0 )); then
    printf '\n_No active workers._\n'
    return
  fi

  # Section order is fixed so the operator's eye learns the layout. Each entry
  # is "Header Title|status-matcher" where the matcher is a |-joined set of
  # raw status strings that map into this section.
  local sections=(
    "Running|running"
    "Paused-on-question|paused_on_question paused-on-question"
    "Rescued|rescued"
    "Complete|complete"
    "Failed|failed"
  )

  # Track which statuses are "known" so the Other bucket can catch the rest.
  local known_statuses=" running paused_on_question paused-on-question rescued complete failed "

  local title matchers
  for entry in "${sections[@]}"; do
    title="${entry%%|*}"
    matchers="${entry#*|}"
    render_section "$title" "$matchers"
  done

  # Other: any worker whose status is not in known_statuses.
  local other_rows
  other_rows="$(printf '%s\n' "$workers_tsv" | while IFS=$'\t' read -r status ticket started tier stype; do
    [[ -n "$status" ]] || continue
    # Known status → skip; otherwise it falls into Other so nothing is dropped.
    if [[ "$known_statuses" == *" $status "* ]]; then
      continue
    fi
    printf '%s\t%s\t%s\t%s\t%s\n' "$status" "$ticket" "$started" "$tier" "$stype"
  done)"
  if [[ -n "$other_rows" ]]; then
    render_section_from_rows "Other" "$other_rows"
  fi
}

# Render one named section, selecting workers whose status is in $matchers
# (space-separated list of acceptable status strings).
render_section() {
  local title="$1" matchers="$2"
  local rows
  rows="$(printf '%s\n' "$workers_tsv" | while IFS=$'\t' read -r status ticket started tier stype; do
    [[ -n "$status" ]] || continue
    local hit=0
    for m in $matchers; do
      [[ "$status" == "$m" ]] && { hit=1; break; }
    done
    (( hit )) && printf '%s\t%s\t%s\t%s\t%s\n' "$status" "$ticket" "$started" "$tier" "$stype"
  done)"
  render_section_from_rows "$title" "$rows"
}

# Render a section header + table from a TSV blob of rows (may be empty).
render_section_from_rows() {
  local title="$1" rows="$2"
  local count=0
  [[ -n "$rows" ]] && count="$(printf '%s\n' "$rows" | grep -c . || true)"

  printf '\n## %s (%s)\n' "$title" "$count"
  if (( count == 0 )); then
    printf '_none_\n'
    return
  fi

  printf '| Ticket | Age | Tier | Type | Last log |\n'
  printf '|---|---|---|---|---|\n'
  printf '%s\n' "$rows" | while IFS=$'\t' read -r status ticket started tier stype; do
    [[ -n "$status" ]] || continue
    local link age secs logline
    link="$(render_ticket "$ticket")"
    if [[ -n "$started" ]]; then
      local started_epoch
      started_epoch="$(iso_to_epoch "$started")"
      if [[ -n "$started_epoch" && -n "$NOW" ]]; then
        secs=$(( NOW - started_epoch ))
        age="$(humanize_age "$secs")"
      else
        age="?"
      fi
    else
      age="?"
    fi
    logline="$(render_log_line "$ticket")"
    printf '| %s | %s | %s | %s | %s |\n' "$link" "$age" "$tier" "$stype" "$logline"
  done
}

board_md="$(render_board)"

# Write the file (unless --no-write).
if (( ! no_write )); then
  out_parent="$(dirname -- "$OUT_FILE")"
  mkdir -p "$out_parent" 2>/dev/null || true
  printf '%s\n' "$board_md" > "$OUT_FILE"
fi

# Always print to stdout.
printf '%s\n' "$board_md"

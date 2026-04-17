#!/usr/bin/env bash
#
# build-daily-digest.sh — compose the daily one-paragraph status digest.
#
# Reads (all optional; missing = zero/omitted clause):
#   logs/*.json                         last 24h of ticket completions
#   state/active.json                   workers running/paused/failed right now
#   state/budget-used.json              today's ticket counters
#   state/autopickup.json               autopickup state (last_picked_count, rl hits)
#   memory/retros/*.md                  most-recent retro → "written" vs "queued"
#
# Writes: nothing. Emits the paragraph to stdout. Read-only.
#
# Usage:
#   scripts/build-daily-digest.sh
#   scripts/build-daily-digest.sh --logs-dir <path> --state-dir <path> --memory-dir <path>
#   scripts/build-daily-digest.sh --window-hours 24 --max-chars 500
#
# Called by: './hydra connect digest' (for --dry-run preview) and by the
# autopickup tick's step-1.6 check (routes the stdout to the configured
# channel). Also callable directly by an operator who wants "what's going on
# right now" without opening logs.
#
# Exit codes:
#   0   paragraph written to stdout
#   2   usage error (unknown flag)
#
# Spec: docs/specs/2026-04-17-daily-digest.md (ticket #144)

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"

usage() {
  cat <<'EOF'
Usage: build-daily-digest.sh [options]

Emit the daily 1-paragraph Hydra status digest to stdout. Read-only.

Options:
  --logs-dir <path>     Override logs/ dir (default $ROOT/logs)
  --state-dir <path>    Override state/ dir (default $ROOT/state)
  --memory-dir <path>   Override memory/ dir (default $HYDRA_EXTERNAL_MEMORY_DIR
                        if set, else $ROOT/memory)
  --window-hours N      Look-back window in hours. Default 24.
  --max-chars N         Truncate cap. Default 500. Overridden by
                        state/digests.json:max_chars if set.
  --full-pointer <s>    Trailing pointer on truncation. Default
                        "./hydra status". Overridden by
                        state/digests.json:full_status_pointer if set.
  -h, --help            Show this help.

Exit codes:
  0 success · 2 usage error
EOF
}

# -----------------------------------------------------------------------------
# argument parsing
# -----------------------------------------------------------------------------
logs_dir_override=""
state_dir_override=""
memory_dir_override=""
window_hours=24
max_chars=""
full_pointer=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --logs-dir)     logs_dir_override="${2:-}"; shift 2 ;;
    --state-dir)    state_dir_override="${2:-}"; shift 2 ;;
    --memory-dir)   memory_dir_override="${2:-}"; shift 2 ;;
    --window-hours) window_hours="${2:-24}"; shift 2 ;;
    --max-chars)    max_chars="${2:-}"; shift 2 ;;
    --full-pointer) full_pointer="${2:-}"; shift 2 ;;
    --logs-dir=*)     logs_dir_override="${1#--logs-dir=}"; shift ;;
    --state-dir=*)    state_dir_override="${1#--state-dir=}"; shift ;;
    --memory-dir=*)   memory_dir_override="${1#--memory-dir=}"; shift ;;
    --window-hours=*) window_hours="${1#--window-hours=}"; shift ;;
    --max-chars=*)    max_chars="${1#--max-chars=}"; shift ;;
    --full-pointer=*) full_pointer="${1#--full-pointer=}"; shift ;;
    *) echo "build-daily-digest: unknown arg '$1'" >&2; usage >&2; exit 2 ;;
  esac
done

# -----------------------------------------------------------------------------
# resolve paths
# -----------------------------------------------------------------------------
LOGS_DIR="${logs_dir_override:-$ROOT_DIR/logs}"
STATE_DIR="${state_dir_override:-$ROOT_DIR/state}"
MEMORY_DIR="${memory_dir_override:-${HYDRA_EXTERNAL_MEMORY_DIR:-$ROOT_DIR/memory}}"

DIGESTS_FILE="$STATE_DIR/digests.json"

# -----------------------------------------------------------------------------
# resolve config overrides from state/digests.json (if it exists)
# -----------------------------------------------------------------------------
if [[ -z "$max_chars" ]]; then
  if [[ -f "$DIGESTS_FILE" ]]; then
    cfg_max="$(jq -r '.max_chars // empty' "$DIGESTS_FILE" 2>/dev/null || true)"
    max_chars="${cfg_max:-500}"
  else
    max_chars=500
  fi
fi

if [[ -z "$full_pointer" ]]; then
  if [[ -f "$DIGESTS_FILE" ]]; then
    cfg_ptr="$(jq -r '.full_status_pointer // empty' "$DIGESTS_FILE" 2>/dev/null || true)"
    full_pointer="${cfg_ptr:-./hydra status}"
  else
    full_pointer="./hydra status"
  fi
fi

# Numeric validation on max_chars — prevent silly inputs from blowing up
# `printf` / substring math later.
if ! [[ "$max_chars" =~ ^[0-9]+$ ]] || (( max_chars < 50 )); then
  echo "build-daily-digest: --max-chars must be a positive integer >= 50 (got '$max_chars')" >&2
  exit 2
fi
if ! [[ "$window_hours" =~ ^[0-9]+$ ]] || (( window_hours < 1 )); then
  echo "build-daily-digest: --window-hours must be a positive integer (got '$window_hours')" >&2
  exit 2
fi

# -----------------------------------------------------------------------------
# helpers
# -----------------------------------------------------------------------------

# Count files in $LOGS_DIR modified within the window whose JSON matches a
# jq filter. Echoes an integer. Never exits non-zero (missing dir → 0).
count_logs_matching() {
  local jq_filter="$1"
  [[ -d "$LOGS_DIR" ]] || { echo 0; return; }

  local count=0 window_seconds
  window_seconds=$(( window_hours * 3600 ))
  local now_epoch cutoff_epoch
  now_epoch=$(date +%s)
  cutoff_epoch=$(( now_epoch - window_seconds ))

  local f mtime
  while IFS= read -r -d '' f; do
    # Portable mtime (GNU vs BSD stat)
    if stat -f %m "$f" >/dev/null 2>&1; then
      mtime=$(stat -f %m "$f")
    else
      mtime=$(stat -c %Y "$f")
    fi
    (( mtime >= cutoff_epoch )) || continue
    if jq -e "$jq_filter" "$f" >/dev/null 2>&1; then
      count=$((count + 1))
    fi
  done < <(find "$LOGS_DIR" -maxdepth 1 -type f -name '*.json' -print0 2>/dev/null)

  echo "$count"
}

# Collect in-window PR URLs whose result matches $1 (merged|pr_opened|stuck).
# Emits space-separated "#N" or "org/repo#N" identifiers (best-effort).
collect_refs_for_result() {
  local want_result="$1"
  [[ -d "$LOGS_DIR" ]] || return 0

  local window_seconds now_epoch cutoff_epoch
  window_seconds=$(( window_hours * 3600 ))
  now_epoch=$(date +%s)
  cutoff_epoch=$(( now_epoch - window_seconds ))

  local f mtime result ref
  while IFS= read -r -d '' f; do
    if stat -f %m "$f" >/dev/null 2>&1; then
      mtime=$(stat -f %m "$f")
    else
      mtime=$(stat -c %Y "$f")
    fi
    (( mtime >= cutoff_epoch )) || continue

    result="$(jq -r '.result // empty' "$f" 2>/dev/null)"
    [[ "$result" == "$want_result" ]] || continue

    # Prefer the ticket id ("org/repo#N") which is the most compact readable
    # reference. Fall back to the PR number from pr_url if ticket is missing.
    ref="$(jq -r '.ticket // empty' "$f" 2>/dev/null)"
    if [[ -z "$ref" ]]; then
      local pr_url
      pr_url="$(jq -r '.pr_url // empty' "$f" 2>/dev/null)"
      if [[ -n "$pr_url" ]]; then
        ref="#${pr_url##*/}"
      fi
    fi
    [[ -n "$ref" ]] && printf '%s ' "$ref"
  done < <(find "$LOGS_DIR" -maxdepth 1 -type f -name '*.json' -print0 2>/dev/null)
}

# Fetch a scalar from a JSON file with a default. Returns the default if the
# file doesn't exist, isn't readable, isn't valid JSON, or the path is null.
json_or_default() {
  local file="$1" path="$2" default="$3"
  if [[ -f "$file" ]]; then
    local v
    v="$(jq -r --arg d "$default" "$path // \$d" "$file" 2>/dev/null || printf '%s' "$default")"
    printf '%s' "${v:-$default}"
  else
    printf '%s' "$default"
  fi
}

# Count active workers whose status matches the supplied jq filter (e.g.
# '.status == "running"'). Tolerates missing active.json.
count_active_matching() {
  local filter="$1"
  local active_file="$STATE_DIR/active.json"
  [[ -f "$active_file" ]] || { echo 0; return; }
  jq -r "[.workers[]? | select($filter)] | length" "$active_file" 2>/dev/null || echo 0
}

# Collect ticket refs from active.json for workers whose status matches.
collect_active_refs_matching() {
  local filter="$1"
  local active_file="$STATE_DIR/active.json"
  [[ -f "$active_file" ]] || return 0
  jq -r "[.workers[]? | select($filter) | .ticket] | join(\" \")" "$active_file" 2>/dev/null || true
}

# Describe retro state:
#   "written YYYY-MM-DD" if the most recent retro is in the last 7 days
#   "queued for Monday"  otherwise (incl. no retro)
describe_retro_state() {
  local retro_dir="$MEMORY_DIR/retros"
  [[ -d "$retro_dir" ]] || { echo "queued for Monday"; return; }

  # Most recent *.md by mtime
  local latest
  latest="$(find "$retro_dir" -maxdepth 1 -type f -name '*.md' -print0 2>/dev/null \
    | xargs -0 ls -t 2>/dev/null | head -1 || true)"
  [[ -n "$latest" ]] || { echo "queued for Monday"; return; }

  local mtime now
  if stat -f %m "$latest" >/dev/null 2>&1; then
    mtime=$(stat -f %m "$latest")
  else
    mtime=$(stat -c %Y "$latest")
  fi
  now=$(date +%s)
  local seven_days=$(( 7 * 24 * 3600 ))

  if (( now - mtime <= seven_days )); then
    local date_str
    if date -r "$mtime" '+%Y-%m-%d' >/dev/null 2>&1; then
      date_str=$(date -r "$mtime" '+%Y-%m-%d')
    else
      date_str=$(date -d "@$mtime" '+%Y-%m-%d')
    fi
    echo "written $date_str"
  else
    echo "queued for Monday"
  fi
}

# Truncate $1 to $max_chars. If truncated, strip trailing whitespace and
# punctuation, then append " … full: $full_pointer". Guarantees the result
# is ≤ $max_chars including the pointer.
truncate_to_cap() {
  local text="$1"
  local len=${#text}
  (( len <= max_chars )) && { printf '%s' "$text"; return; }

  local suffix=" … full: $full_pointer"
  local budget=$(( max_chars - ${#suffix} ))
  (( budget < 20 )) && budget=20  # pathological cap: still produce something

  # Trim to budget; back off to a word boundary if possible.
  local head="${text:0:$budget}"
  local back="${head% *}"
  # If backing off to a word boundary removed too much (< half), keep the
  # char cut. This protects against a single-long-token paragraph.
  if (( ${#back} >= budget / 2 )); then
    head="$back"
  fi
  # Strip trailing punctuation/whitespace we're about to replace with the
  # ellipsis pointer.
  head="${head%% }"
  head="${head%%.}"
  head="${head%%,}"
  printf '%s%s' "$head" "$suffix"
}

# -----------------------------------------------------------------------------
# gather data
# -----------------------------------------------------------------------------
# Completed in window: result in (merged, pr_opened). Split by whether a PR
# was auto-merged versus pending review.
merged_count="$(count_logs_matching '.result == "merged"')"
pending_count="$(count_logs_matching '.result == "pr_opened"')"
shipped_count=$(( merged_count + pending_count ))
pending_refs="$(collect_refs_for_result pr_opened | sed 's/ *$//')"

# Stuck workers: active.json entries with status in (paused-on-question, failed).
stuck_count="$(count_active_matching '.status == "paused-on-question" or .status == "failed"')"
stuck_refs="$(collect_active_refs_matching '.status == "paused-on-question" or .status == "failed"')"

# Autopickup signals — best-effort snapshot of current values.
autopickup_file="$STATE_DIR/autopickup.json"
picked="$(json_or_default "$autopickup_file" '.last_picked_count' 0)"
rl_hits="$(json_or_default "$autopickup_file" '.consecutive_rate_limit_hits' 0)"

retro_status="$(describe_retro_state)"

# -----------------------------------------------------------------------------
# compose paragraph
# -----------------------------------------------------------------------------
# Everything-zero path: emit a minimal-but-valid paragraph so subscribers
# never receive a half-written sentence.
if (( shipped_count == 0 && stuck_count == 0 && picked == 0 && rl_hits == 0 )); then
  paragraph="Overnight: quiet. Retro ${retro_status}. Full: ${full_pointer}."
  truncate_to_cap "$paragraph"
  printf '\n'
  exit 0
fi

# Build the shipped-clause. "shipped 3 PRs (2 auto-merged, 1 pending your
# review → #501)" — only mention the review pointer if pending > 0.
shipped_clause=""
if (( shipped_count > 0 )); then
  shipped_clause="shipped ${shipped_count} PR"
  (( shipped_count == 1 )) || shipped_clause="${shipped_clause}s"
  shipped_clause="${shipped_clause} (${merged_count} auto-merged, ${pending_count} pending your review"
  if (( pending_count > 0 )) && [[ -n "$pending_refs" ]]; then
    shipped_clause="${shipped_clause} → ${pending_refs}"
  fi
  shipped_clause="${shipped_clause})"
fi

stuck_clause=""
if (( stuck_count > 0 )); then
  stuck_clause="${stuck_count} worker"
  (( stuck_count == 1 )) || stuck_clause="${stuck_clause}s"
  stuck_clause="${stuck_clause} stuck"
  if [[ -n "$stuck_refs" ]]; then
    stuck_clause="${stuck_clause} on ${stuck_refs}"
  fi
fi

picked_clause=""
if (( picked > 0 )); then
  picked_clause="autopickup picked ${picked} ticket"
  (( picked == 1 )) || picked_clause="${picked_clause}s"
fi

rl_clause=""
if (( rl_hits > 0 )); then
  rl_clause="${rl_hits} rate-limit hit"
  (( rl_hits == 1 )) || rl_clause="${rl_clause}s"
fi

# Join the non-empty clauses with ", ".
clauses=()
[[ -n "$shipped_clause" ]] && clauses+=("$shipped_clause")
[[ -n "$stuck_clause"   ]] && clauses+=("$stuck_clause")
[[ -n "$picked_clause"  ]] && clauses+=("$picked_clause")
[[ -n "$rl_clause"      ]] && clauses+=("$rl_clause")

body=""
if (( ${#clauses[@]} > 0 )); then
  # Join with ", ". We can't use $IFS here because "${array[*]}" only uses
  # the first char of IFS as the separator — ", " would come out as ",".
  for c in "${clauses[@]}"; do
    if [[ -z "$body" ]]; then
      body="$c"
    else
      body="${body}, ${c}"
    fi
  done
fi

paragraph="Overnight: ${body}. Retro ${retro_status}. Full: ${full_pointer}."

truncate_to_cap "$paragraph"
printf '\n'

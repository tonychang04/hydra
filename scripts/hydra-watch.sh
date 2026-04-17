#!/usr/bin/env bash
#
# hydra-watch.sh — live auto-refreshing terminal dashboard. Three panes:
#   • Top line: Commander state (workers count / autopickup / today's tally)
#   • Middle table: Active workers (poll state/active.json)
#   • Bottom table: Recent completions, last 10 by mtime (poll logs/*.json)
#
# Pure bash + tput. No ncurses / blessed / rich / python deps. Works over SSH
# on macOS and Linux. Non-blocking input via `read -t 0.1` so the loop yields
# instead of burning a CPU core.
#
# Usage:
#   ./hydra watch                         Launch the dashboard (interactive)
#   ./hydra watch --once                  Print single snapshot and exit
#   ./hydra watch --interval N            Refresh every N seconds (1..60, default 2)
#   ./hydra watch --logs-dir <path>       Override logs dir (test / fixture use)
#   ./hydra watch --state-dir <path>      Override state/ dir
#   ./hydra watch -h | --help             Print this banner.
#
# Key bindings (interactive mode only):
#   q / Q / Ctrl-C  quit (cleanup + restore cursor)
#   r / R           force immediate redraw
#   p / P           toggle PAUSE (delegates to ./hydra pause | ./hydra resume)
#   ? / h           toggle help overlay
#
# Spec: docs/specs/2026-04-17-hydra-watch.md (ticket #130)
#
# Exit codes:
#   0   OK
#   2   usage error (bad flag, unknown arg, interval out of range)

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"

# shellcheck disable=SC1091
[[ -f "$ROOT_DIR/.hydra.env" ]] && source "$ROOT_DIR/.hydra.env"

usage() {
  cat <<'EOF'
Usage: ./hydra watch [options]

Live auto-refreshing terminal dashboard (three panes):
  Top line: Commander state (workers count / autopickup / today's tally)
  Middle:   Active workers table (state/active.json)
  Bottom:   Recent completions, last 10 by mtime (logs/*.json)

Options:
  --once                     Print a single snapshot and exit (for scripting).
  --interval N               Refresh every N seconds (default 2, min 1, max 60).
  --logs-dir <path>          Override logs dir (default $ROOT/logs).
  --state-dir <path>         Override state dir (default $ROOT/state).
  -h, --help                 Show this help.

Key bindings (interactive mode only):
  q / Q / Ctrl-C             quit (restores cursor + clears screen)
  r / R                      force immediate redraw
  p / P                      toggle PAUSE (via ./hydra pause | ./hydra resume)
  ? / h                      toggle help overlay

Does NOT launch a Claude session. Does NOT write to any state file.
Safe for scripts / cron / SSH (use --once).
EOF
}

# -----------------------------------------------------------------------------
# argument parsing
# -----------------------------------------------------------------------------
mode="interactive"
interval=2
logs_dir_override=""
state_dir_override=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --once) mode="once"; shift ;;
    --interval)
      [[ $# -ge 2 ]] || { echo "✗ --interval requires a value" >&2; exit 2; }
      interval="$2"; shift 2
      ;;
    --logs-dir)
      [[ $# -ge 2 ]] || { echo "✗ --logs-dir requires a path" >&2; exit 2; }
      logs_dir_override="$2"; shift 2
      ;;
    --state-dir)
      [[ $# -ge 2 ]] || { echo "✗ --state-dir requires a path" >&2; exit 2; }
      state_dir_override="$2"; shift 2
      ;;
    *)
      echo "✗ unknown arg: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

# sanity: interval must be an integer in [1, 60]
if ! [[ "$interval" =~ ^[1-9][0-9]*$ ]] || [[ "$interval" -lt 1 ]] || [[ "$interval" -gt 60 ]]; then
  echo "✗ --interval must be an integer in [1, 60] (got: $interval)" >&2
  exit 2
fi

LOGS_DIR="${logs_dir_override:-$ROOT_DIR/logs}"
STATE_DIR="${state_dir_override:-$ROOT_DIR/state}"

# -----------------------------------------------------------------------------
# color / tput — only in interactive mode. --once is pipe-friendly (no escapes).
# -----------------------------------------------------------------------------
if [[ "$mode" == "interactive" ]] && [[ -t 1 ]] && [[ "${NO_COLOR:-}" != "1" ]]; then
  C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'; C_GREEN=$'\033[32m'; C_RED=$'\033[31m'
  C_YELLOW=$'\033[33m'; C_RESET=$'\033[0m'
else
  C_BOLD=""; C_DIM=""; C_GREEN=""; C_RED=""; C_YELLOW=""; C_RESET=""
fi

# tput wrappers — fall back to ANSI escapes if tput is absent (minimal container).
# We only ever call these in interactive mode.
t_clear() {
  if command -v tput >/dev/null 2>&1; then
    tput clear 2>/dev/null || printf '\033[2J\033[H'
  else
    printf '\033[2J\033[H'
  fi
}
t_hide_cursor() { command -v tput >/dev/null 2>&1 && tput civis 2>/dev/null || true; }
t_show_cursor() { command -v tput >/dev/null 2>&1 && tput cnorm 2>/dev/null || true; }

# -----------------------------------------------------------------------------
# helpers — mirror hydra-activity.sh idioms (jq_or, age_minutes, truncate_field)
# -----------------------------------------------------------------------------

# jq_or <file> <filter> <fallback>  — defensive jq that never errors out
jq_or() {
  local f="$1" filter="$2" fb="$3"
  if [[ -f "$f" ]] && jq empty "$f" 2>/dev/null; then
    jq -r "$filter" "$f" 2>/dev/null || printf '%s' "$fb"
  else
    printf '%s' "$fb"
  fi
}

# age_minutes <iso_timestamp>  — minutes elapsed, or "" if unparseable. Portable
# across GNU date (Linux) and BSD date (macOS).
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

# time_hm <iso_timestamp>  — "HH:MM" or "—" if unparseable.
time_hm() {
  local ts="$1"
  [[ -z "$ts" || "$ts" == "null" ]] && { printf '—'; return; }
  if date -d "$ts" '+%H:%M' >/dev/null 2>&1; then
    date -d "$ts" '+%H:%M'
  elif date -j -f "%Y-%m-%dT%H:%M:%SZ" "$ts" '+%H:%M' >/dev/null 2>&1; then
    date -j -f "%Y-%m-%dT%H:%M:%SZ" "$ts" '+%H:%M'
  else
    printf '—'
  fi
}

# time_hm_from_epoch <epoch_seconds>  — "HH:MM"
time_hm_from_epoch() {
  local e="$1"
  if date -r "$e" '+%H:%M' >/dev/null 2>&1; then
    date -r "$e" '+%H:%M'
  else
    # GNU date
    date -d "@$e" '+%H:%M' 2>/dev/null || printf '—'
  fi
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
# data fetchers — all defensive, all read-only
# -----------------------------------------------------------------------------
fetch_commander_state() {
  # Populates globals: C_ACTIVE_COUNT, C_MAX_WORKERS, C_TODAY_DONE,
  # C_TODAY_FAILED, C_AUTO_ENABLED, C_AUTO_INTERVAL, C_PAUSE_STATE.
  local active_file="$STATE_DIR/active.json"
  local budget_file="$STATE_DIR/budget-used.json"
  local auto_file="$STATE_DIR/autopickup.json"
  local budget_cfg="$ROOT_DIR/budget.json"

  C_ACTIVE_COUNT="$(jq_or "$active_file" '(.workers // []) | map(select(.status == "running")) | length' "0")"
  C_TODAY_DONE="$(jq_or "$budget_file" '.tickets_completed_today // 0' "0")"
  C_TODAY_FAILED="$(jq_or "$budget_file" '.tickets_failed_today // 0' "0")"
  C_AUTO_ENABLED="$(jq_or "$auto_file" '.enabled // false' "false")"
  C_AUTO_INTERVAL="$(jq_or "$auto_file" '.interval_min // 30' "30")"
  C_MAX_WORKERS="$(jq_or "$budget_cfg" '.phase1_subscription_caps.max_concurrent_workers // 5' "5")"

  if [[ -f "$ROOT_DIR/PAUSE" ]] || [[ -f "$ROOT_DIR/commander/PAUSE" ]]; then
    C_PAUSE_STATE="on"
  else
    C_PAUSE_STATE="off"
  fi
}

fetch_active_workers() {
  # Populates ACTIVE_ROWS (tab-separated rows, one per worker) and ACTIVE_COUNT.
  # Row shape: id \t ticket \t tier \t started_at \t status
  local active_file="$STATE_DIR/active.json"
  ACTIVE_ROWS=""
  ACTIVE_COUNT=0
  if [[ -f "$active_file" ]] && jq empty "$active_file" 2>/dev/null; then
    while IFS= read -r row; do
      [[ -z "$row" ]] && continue
      ACTIVE_COUNT=$((ACTIVE_COUNT + 1))
      ACTIVE_ROWS+="$row"$'\n'
    done < <(jq -r '(.workers // [])
      | .[]
      | [
          (.id // "—"),
          (.ticket // "—"),
          (.tier // "—"),
          (.started_at // ""),
          (.status // "—")
        ]
      | @tsv' "$active_file")
  fi
}

fetch_recent_completions() {
  # Populates COMPLETIONS_ROWS (tab-separated) and COMPLETIONS_COUNT. Keeps only
  # the 10 most recent log files by mtime.
  # Row shape: time_hm \t ticket \t repo \t tier \t result \t pr
  COMPLETIONS_ROWS=""
  COMPLETIONS_COUNT=0
  [[ -d "$LOGS_DIR" ]] || return 0

  # Portable "N most recent files by mtime": ls -t is in POSIX and honors mtime
  # by default. We only want regular files with .json extension.
  local files=()
  while IFS= read -r f; do
    [[ -n "$f" ]] && files+=("$f")
  done < <(
    # shellcheck disable=SC2012  # ls is fine here: we control the directory + suffix
    ls -t "$LOGS_DIR"/*.json 2>/dev/null | head -10
  )

  local f
  for f in ${files[@]+"${files[@]}"}; do
    [[ -f "$f" ]] || continue
    jq empty "$f" 2>/dev/null || continue

    # Get mtime as epoch for the time column. Portable across GNU/BSD.
    local epoch=""
    if stat -c %Y "$f" >/dev/null 2>&1; then
      epoch="$(stat -c %Y "$f")"
    elif stat -f %m "$f" >/dev/null 2>&1; then
      epoch="$(stat -f %m "$f")"
    fi
    local time_col="—"
    [[ -n "$epoch" ]] && time_col="$(time_hm_from_epoch "$epoch")"

    local row
    row="$(jq -r \
      --arg file "$(basename "$f")" \
      --arg time "$time_col" \
      '[
        $time,
        (.ticket // $file),
        (.repo // "—"),
        (.tier // "—"),
        (.result // "—"),
        (if (.pr_url // null) == null or (.pr_url // "") == "" then "—" else (.pr_url | sub("https://github.com/"; "") | sub("/pull/"; "#")) end)
      ] | @tsv' "$f" 2>/dev/null)"
    [[ -z "$row" ]] && continue
    COMPLETIONS_COUNT=$((COMPLETIONS_COUNT + 1))
    COMPLETIONS_ROWS+="$row"$'\n'
  done
}

# -----------------------------------------------------------------------------
# render — builds the full frame as a string, writes it in one printf. This
# reduces mid-frame flicker on slow terminals and SSH connections.
# -----------------------------------------------------------------------------
render_frame() {
  local show_help="${1:-0}"
  local buf=""
  local now; now="$(date '+%H:%M:%S')"

  # -- banner --
  buf+="${C_BOLD}▸ Hydra watch — ${now} (refresh: ${interval}s)${C_RESET}"$'\n'
  buf+="━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"$'\n'

  # -- top line: commander state --
  local auto_str
  if [[ "$C_AUTO_ENABLED" == "true" ]]; then
    auto_str="on (${C_AUTO_INTERVAL}m)"
  else
    auto_str="off"
  fi
  local pause_str="off"
  if [[ "$C_PAUSE_STATE" == "on" ]]; then
    pause_str="${C_RED}on${C_RESET}"
  fi
  buf+="Commander: online · ${C_ACTIVE_COUNT}/${C_MAX_WORKERS} workers · autopickup: ${auto_str} · today: ${C_TODAY_DONE} done, ${C_TODAY_FAILED} failed · pause: ${pause_str}"$'\n'
  buf+=$'\n'

  # -- middle: active workers table --
  buf+="${C_BOLD}Active workers (${ACTIVE_COUNT})${C_RESET}"$'\n'
  if [[ "$ACTIVE_COUNT" -gt 0 ]]; then
    local table=""
    table+="ID"$'\t'"TICKET"$'\t'"TIER"$'\t'"STARTED"$'\t'"AGE"$'\t'"STATUS"$'\n'
    local id ticket tier started_at status age_min started_hm
    while IFS=$'\t' read -r id ticket tier started_at status; do
      [[ -z "$id" ]] && continue
      age_min="$(age_minutes "$started_at")"
      [[ -z "$age_min" ]] && age_min="—"
      started_hm="$(time_hm "$started_at")"
      id="$(truncate_field "$id" 10)"
      ticket="$(truncate_field "$ticket" 16)"
      table+="${id}"$'\t'"${ticket}"$'\t'"${tier}"$'\t'"${started_hm}"$'\t'"${age_min}m"$'\t'"${status}"$'\n'
    done <<<"$ACTIVE_ROWS"
    # column -t honors tabs as the column separator with -s $'\t'.
    buf+="$(printf '%s' "$table" | column -t -s $'\t' | sed 's/^/  /')"$'\n'
  else
    buf+="  ${C_DIM}(no running workers)${C_RESET}"$'\n'
  fi
  buf+=$'\n'

  # -- bottom: recent completions table --
  buf+="${C_BOLD}Recent completions (last 10)${C_RESET}"$'\n'
  if [[ "$COMPLETIONS_COUNT" -gt 0 ]]; then
    local table=""
    table+="TIME"$'\t'"TICKET"$'\t'"REPO"$'\t'"TIER"$'\t'"RESULT"$'\t'"PR"$'\n'
    local t ticket repo tier result pr
    while IFS=$'\t' read -r t ticket repo tier result pr; do
      [[ -z "$t" ]] && continue
      ticket="$(truncate_field "$ticket" 14)"
      repo="$(truncate_field "$repo" 16)"
      result="$(truncate_field "$result" 14)"
      table+="${t}"$'\t'"${ticket}"$'\t'"${repo}"$'\t'"${tier}"$'\t'"${result}"$'\t'"${pr}"$'\n'
    done <<<"$COMPLETIONS_ROWS"
    buf+="$(printf '%s' "$table" | column -t -s $'\t' | sed 's/^/  /')"$'\n'
  else
    buf+="  ${C_DIM}(no recent completions)${C_RESET}"$'\n'
  fi
  buf+=$'\n'
  buf+="━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"$'\n'

  # -- status / help line --
  if [[ "$show_help" == "1" ]]; then
    buf+="${C_BOLD}Help — keys:${C_RESET}"$'\n'
    buf+="  ${C_BOLD}q${C_RESET} / ${C_BOLD}Q${C_RESET} / Ctrl-C  quit"$'\n'
    buf+="  ${C_BOLD}r${C_RESET} / ${C_BOLD}R${C_RESET}           force redraw"$'\n'
    buf+="  ${C_BOLD}p${C_RESET} / ${C_BOLD}P${C_RESET}           toggle PAUSE (delegates to ./hydra pause | resume)"$'\n'
    buf+="  ${C_BOLD}?${C_RESET} / ${C_BOLD}h${C_RESET}           toggle this help overlay"$'\n'
    buf+=$'\n'
    buf+="Flags: --once · --interval N (1-60) · --logs-dir · --state-dir"$'\n'
  else
    buf+="${C_DIM}q to quit · p to pause · r to refresh · ? for help${C_RESET}"$'\n'
  fi

  printf '%s' "$buf"
}

# -----------------------------------------------------------------------------
# --once mode: render one frame and exit. No cursor / terminal state change.
# -----------------------------------------------------------------------------
if [[ "$mode" == "once" ]]; then
  fetch_commander_state
  fetch_active_workers
  fetch_recent_completions
  render_frame 0
  exit 0
fi

# -----------------------------------------------------------------------------
# interactive mode: main loop
# -----------------------------------------------------------------------------

# Cleanup handler — restores cursor + moves to a fresh line on any catchable
# exit signal. Ctrl-C (SIGINT) trips EXIT via set -e; we also register INT/TERM
# explicitly so the cleanup runs before the shell terminates.
HELP_MODE=0
NEED_RESIZE=0

cleanup() {
  t_show_cursor
  # Leave the terminal on a fresh line so the shell prompt is clean.
  printf '\n'
  # Reset stty to sane in case a partial read left things weird.
  stty sane 2>/dev/null || true
}
trap cleanup EXIT
trap 'exit 0' INT TERM
trap 'NEED_RESIZE=1' WINCH

# Hide cursor during the loop so it doesn't blink over table rows.
t_hide_cursor

# Initial fetch + render before the first read, so the operator doesn't stare
# at a blank screen for `interval` seconds.
fetch_commander_state
fetch_active_workers
fetch_recent_completions
t_clear
render_frame "$HELP_MODE"

# Main loop: on each iteration, do `interval * 10` × 100ms blocking reads for
# a keypress. This keeps the loop at effectively 0% CPU while remaining
# responsive to key events within 100ms.
while true; do
  # break-to-redraw flag — set by keypress handlers below
  REDRAW=0

  # inner input-wait loop — bash 3.2 portable (no `read -t $fractional` on
  # some systems; bash >= 3.2.57 accepts 0.1, which is every macOS default).
  # $STDIN_IS_TTY was set at startup; when stdin is not a TTY we skip `read`
  # entirely and just `sleep` the interval — otherwise `read` returns
  # immediately on EOF and the loop spins CPU-bound.
  local_i=0
  local_total=$(( interval * 10 ))
  while [[ "$local_i" -lt "$local_total" ]]; do
    # Non-blocking-ish 100ms read. `|| true` prevents set -e tripping on the
    # expected timeout exit code.
    key=""
    if [[ "$STDIN_IS_TTY" -eq 0 ]]; then
      # No TTY — we can't read keys, so just sleep and rely on SIGWINCH /
      # SIGTERM / SIGINT to break the loop.
      sleep 0.1
    elif read -rs -t 0.1 -n 1 key 2>/dev/null; then
      case "$key" in
        q|Q)
          exit 0
          ;;
        r|R)
          REDRAW=1
          break
          ;;
        p|P)
          # Delegate to the existing pause/resume helpers (reuses their
          # centralized state-write logic — we never touch PAUSE ourselves).
          if [[ "$C_PAUSE_STATE" == "on" ]]; then
            "$ROOT_DIR/hydra" resume >/dev/null 2>&1 || true
          else
            "$ROOT_DIR/hydra" pause >/dev/null 2>&1 || true
          fi
          REDRAW=1
          break
          ;;
        '?'|h|H)
          HELP_MODE=$(( 1 - HELP_MODE ))
          REDRAW=1
          break
          ;;
        *)
          # unknown key — ignore and keep waiting
          :
          ;;
      esac
    fi
    # Check resize — redraw immediately at new dimensions.
    if [[ "$NEED_RESIZE" == "1" ]]; then
      NEED_RESIZE=0
      REDRAW=1
      break
    fi
    local_i=$(( local_i + 1 ))
  done

  # -- end of interval (or early-break from keypress / resize) — refresh data --
  fetch_commander_state
  fetch_active_workers
  fetch_recent_completions
  t_clear
  render_frame "$HELP_MODE"
done

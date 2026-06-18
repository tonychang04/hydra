#!/usr/bin/env bash
#
# detect-worker-stalls.sh — forward-facing worker-stall detector + failure-trend
# rollup (ticket #306, P1 observability).
#
# READ-ONLY, REPORT-ONLY: this script never kills, rescues, labels, spawns, or
# mutates state/. It REPORTS; Commander acts (via scripts/rescue-worker.sh, which
# owns rescue/kill logic). Same verdict→nothing-to-act contract as
# scripts/autopickup-tick.sh. The ONLY write is appending an event line to the
# append-only log logs/stalls-YYYY-MM.jsonl (suppressible with --no-log) — a log,
# not validated state, so it has no state/schemas entry.
#
# Two modes:
#
#   default (stall-scan)
#     For each worker in state/active.json with status=="running", compute idle
#     minutes (now - started_at; started_at is the only activity signal in
#     active.json, mirroring scripts/audit-detect.sh) and flag any worker idle
#     >= --threshold-min (default 12). A paused-on-question worker is NOT a stall
#     (it is intentionally waiting on an operator answer). Appends one jsonl event
#     per flagged stall.
#
#   --trends
#     Count failure-mode frequencies from recent logs/*.json (result / surprises /
#     flaky_tool signals) PLUS the logs/stalls-*.jsonl events within --since-days
#     (default 30), and emit a top-N (--top, default 5) {mode,count} list.
#
# Usage:
#   scripts/detect-worker-stalls.sh [--json] [--threshold-min N] [--no-log]
#       [--state-dir <path>] [--logs-dir <path>] [--now <ISO8601>]
#   scripts/detect-worker-stalls.sh --trends [--json] [--top N] [--since-days N]
#       [--logs-dir <path>] [--now <ISO8601>]
#
# Output:
#   default human  grouped stall report
#   --json         {generated_at, threshold_min, active_workers, stalls:[...],
#                   stall_count, log_file}
#   --trends human  failure-mode top-N table
#   --trends --json {generated_at, window_days, top, trends:[{mode,count}]}
#
# Exit codes:
#   0   ran (report printed) — a stall being present is reported IN the output,
#       not via exit code (mirrors autopickup-tick.sh).
#   1   I/O error (jq missing, state-dir unreadable)
#   2   usage error (unknown flag / missing value / bad number)
#
# Spec: docs/specs/2026-06-18-worker-stall-observability.md (ticket #306)
# Style mirrors scripts/autopickup-tick.sh and scripts/audit-detect.sh.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"

usage() {
  cat <<'EOF'
Usage: detect-worker-stalls.sh [options]

Forward-facing worker-stall detector + failure-trend rollup. READ-ONLY,
REPORT-ONLY — never kills/rescues/spawns/mutates state. Commander acts on output.

Modes:
  (default)              Scan state/active.json for RUNNING workers idle past the
                         threshold and flag them; append one jsonl event per stall.
  --trends               Instead of scanning, count failure-mode frequencies from
                         recent logs/*.json + logs/stalls-*.jsonl, emit top-N.

Options:
  --json                 Emit machine-readable JSON.
  --threshold-min <N>    Idle threshold in minutes for a stall (default 12).
  --no-log               Do NOT append events to logs/stalls-YYYY-MM.jsonl.
  --state-dir <path>     Override state/ dir (default $ROOT/state).
  --logs-dir <path>      Override logs/ dir (default $ROOT/logs).
  --now <ISO8601>        Override "now" for deterministic tests (e.g.
                         2026-06-18T12:00:00Z). Default: live UTC clock.
  --top <N>              (--trends) top-N failure modes to emit (default 5).
  --since-days <N>       (--trends) window in days for log mtime / event ts
                         (default 30).
  -h, --help             Show this help.

Exit codes:
  0 ran · 1 I/O error · 2 usage error

Spec: docs/specs/2026-06-18-worker-stall-observability.md (ticket #306)
EOF
}

# -----------------------------------------------------------------------------
# argument parsing
# -----------------------------------------------------------------------------
json_mode=0
threshold_min=12
no_log=0
state_dir_override=""
logs_dir_override=""
now_override=""
trends_mode=0
top_n=5
since_days=30

need_val() {
  if [[ $# -lt 2 ]]; then
    echo "detect-worker-stalls: option '$1' requires a value" >&2
    usage >&2
    exit 2
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)          usage; exit 0 ;;
    --json)             json_mode=1; shift ;;
    --trends)           trends_mode=1; shift ;;
    --no-log)           no_log=1; shift ;;
    --threshold-min)    need_val "$@"; threshold_min="$2"; shift 2 ;;
    --threshold-min=*)  threshold_min="${1#--threshold-min=}"; shift ;;
    --state-dir)        need_val "$@"; state_dir_override="$2"; shift 2 ;;
    --state-dir=*)      state_dir_override="${1#--state-dir=}"; shift ;;
    --logs-dir)         need_val "$@"; logs_dir_override="$2"; shift 2 ;;
    --logs-dir=*)       logs_dir_override="${1#--logs-dir=}"; shift ;;
    --now)              need_val "$@"; now_override="$2"; shift 2 ;;
    --now=*)            now_override="${1#--now=}"; shift ;;
    --top)              need_val "$@"; top_n="$2"; shift 2 ;;
    --top=*)            top_n="${1#--top=}"; shift ;;
    --since-days)       need_val "$@"; since_days="$2"; shift 2 ;;
    --since-days=*)     since_days="${1#--since-days=}"; shift ;;
    *) echo "detect-worker-stalls: unknown arg '$1'" >&2; usage >&2; exit 2 ;;
  esac
done

if [[ ! "$threshold_min" =~ ^[0-9]+$ ]]; then
  echo "detect-worker-stalls: --threshold-min must be a non-negative integer, got '$threshold_min'" >&2; exit 2
fi
if [[ ! "$top_n" =~ ^[0-9]+$ ]]; then
  echo "detect-worker-stalls: --top must be a non-negative integer, got '$top_n'" >&2; exit 2
fi
if [[ ! "$since_days" =~ ^[0-9]+$ ]]; then
  echo "detect-worker-stalls: --since-days must be a non-negative integer, got '$since_days'" >&2; exit 2
fi

command -v jq >/dev/null 2>&1 || { echo "detect-worker-stalls: jq not found on PATH" >&2; exit 1; }

STATE_DIR="${state_dir_override:-$ROOT_DIR/state}"
LOGS_DIR="${logs_dir_override:-$ROOT_DIR/logs}"
ACTIVE_FILE="$STATE_DIR/active.json"

# -----------------------------------------------------------------------------
# portable epoch helpers (copied from scripts/audit-detect.sh — do not reinvent)
# -----------------------------------------------------------------------------
iso_to_epoch() {
  local iso="$1"
  iso="${iso%Z}"
  # Normalize "T" to a space for BSD date; strip fractional seconds.
  local norm="${iso/T/ }"
  norm="${norm%%.*}"
  if date -u -d "$norm" +%s >/dev/null 2>&1; then
    date -u -d "$norm" +%s            # GNU date
  elif date -u -j -f "%Y-%m-%d %H:%M:%S" "$norm" +%s >/dev/null 2>&1; then
    date -u -j -f "%Y-%m-%d %H:%M:%S" "$norm" +%s   # BSD date, full
  elif date -u -j -f "%Y-%m-%d %H:%M" "$norm" +%s >/dev/null 2>&1; then
    date -u -j -f "%Y-%m-%d %H:%M" "$norm" +%s       # BSD date, no seconds
  else
    printf ''
  fi
}

now_epoch() {
  if [[ -n "$now_override" ]]; then
    iso_to_epoch "$now_override"
  else
    date -u +%s
  fi
}

GEN_TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
# With --now, echo it back as the generated_at (normalize to exactly one trailing
# Z: strip any existing Z, then append one). %Z strips at most one trailing Z, so
# the result has precisely one — deterministic for tests.
[[ -n "$now_override" ]] && GEN_TS="${now_override%Z}Z"

now_e="$(now_epoch)"
if [[ -z "$now_e" ]]; then
  echo "detect-worker-stalls: could not resolve 'now' (bad --now '$now_override'?)" >&2
  exit 2
fi

# =============================================================================
# TRENDS MODE
# =============================================================================
# Counts failure-mode frequencies, cheaply, from two local sources within the
# --since-days window:
#   - recent logs/*.json — a normalized failure signal from result + any
#     surprises / flaky_tool string;
#   - logs/stalls-*.jsonl events — each stalled verdict is a worker-stall mode.
# No state writes, no network. Deterministic from on-disk state.
if [[ "$trends_mode" -eq 1 ]]; then
  window_secs=$(( since_days * 86400 ))
  cutoff_e=$(( now_e - window_secs ))

  modes_jsonl=""

  # --- source 1: logs/*.json completed-ticket logs (skip the jsonl stall logs).
  if [[ -d "$LOGS_DIR" ]]; then
    while IFS= read -r lf; do
      [[ -n "$lf" ]] || continue
      # window by event timestamp (completed_at) when present, else file mtime.
      ev_e=""
      ca="$(jq -r '.completed_at // empty' "$lf" 2>/dev/null || echo "")"
      [[ -n "$ca" ]] && ev_e="$(iso_to_epoch "$ca")"
      if [[ -z "$ev_e" ]]; then
        # portable mtime: GNU stat -c %Y, BSD stat -f %m.
        ev_e="$(stat -c %Y "$lf" 2>/dev/null || stat -f %m "$lf" 2>/dev/null || echo 0)"
      fi
      [[ "$ev_e" =~ ^[0-9]+$ ]] || ev_e=0
      (( ev_e < cutoff_e )) && continue

      # Derive a failure mode. result in {failed,stuck,error,...} contributes a
      # mode; a surprises/flaky_tool string contributes a "<tool> flaky" / the
      # raw surprise. A clean success contributes nothing.
      while IFS= read -r mode; do
        [[ -n "$mode" ]] || continue
        modes_jsonl+="$(jq -nc --arg m "$mode" '$m')"$'\n'
      done < <(jq -r '
        ( (.result // "") | ascii_downcase ) as $r
        | ( if ($r | test("fail|stuck|error|timeout|conflict")) then $r else empty end ),
        ( (.flaky_tool // empty) | if . != "" then "flaky-tool: " + . else empty end ),
        ( (.surprises // empty)
          | if type=="array" then .[] else . end
          | select(type=="string" and (ascii_downcase | test("fail|stuck|error|timeout|flaky|stall")))
        )
      ' "$lf" 2>/dev/null || true)
    done < <(find "$LOGS_DIR" -maxdepth 1 -type f -name '*.json' 2>/dev/null)
  fi

  # --- source 2: logs/stalls-*.jsonl events (each stalled verdict = a mode).
  if [[ -d "$LOGS_DIR" ]]; then
    while IFS= read -r sf; do
      [[ -n "$sf" ]] || continue
      while IFS= read -r ev; do
        [[ -n "$ev" ]] || continue
        ts="$(printf '%s' "$ev" | jq -r '.ts // empty' 2>/dev/null || echo "")"
        ev_e=""
        [[ -n "$ts" ]] && ev_e="$(iso_to_epoch "$ts")"
        [[ "$ev_e" =~ ^[0-9]+$ ]] || ev_e=0
        (( ev_e < cutoff_e )) && continue
        v="$(printf '%s' "$ev" | jq -r '.verdict // empty' 2>/dev/null || echo "")"
        [[ "$v" == "stalled" ]] && modes_jsonl+="$(jq -nc '"worker-stall"')"$'\n'
      done < "$sf"
    done < <(find "$LOGS_DIR" -maxdepth 1 -type f -name 'stalls-*.jsonl' 2>/dev/null)
  fi

  # Aggregate → top-N descending by count (ties: alphabetical for determinism).
  if [[ -n "${modes_jsonl//[$'\n']/}" ]]; then
    trends_array="$(printf '%s' "$modes_jsonl" | jq -s --argjson top "$top_n" '
      group_by(.) | map({mode: .[0], count: length})
      | sort_by([-.count, .mode]) | .[:$top]')"
  else
    trends_array='[]'
  fi

  if [[ "$json_mode" -eq 1 ]]; then
    jq -nc \
      --arg generated_at "$GEN_TS" \
      --argjson window_days "$since_days" \
      --argjson top "$top_n" \
      --argjson trends "$trends_array" \
      '{generated_at:$generated_at, window_days:$window_days, top:$top, trends:$trends}'
    exit 0
  fi

  echo "▸ Worker failure-mode trends — last ${since_days}d (top ${top_n})  ($GEN_TS)"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  if [[ "$(printf '%s' "$trends_array" | jq 'length')" -eq 0 ]]; then
    echo "  (no failure-mode events in window)"
  else
    printf '%s' "$trends_array" | jq -r '.[] | "  \(.count)×  \(.mode)"'
  fi
  exit 0
fi

# =============================================================================
# STALL-SCAN MODE (default)
# =============================================================================
threshold_secs=$(( threshold_min * 60 ))

active_workers=0
stalls_jsonl=""

if [[ -f "$ACTIVE_FILE" ]]; then
  active_workers="$(jq -r '(.workers // []) | length' "$ACTIVE_FILE" 2>/dev/null || echo 0)"
  [[ "$active_workers" =~ ^[0-9]+$ ]] || active_workers=0

  # Iterate RUNNING workers. A paused-on-question worker is excluded — it is
  # intentionally waiting on an operator answer ("no recent QUESTION").
  while IFS= read -r w; do
    [[ -n "$w" ]] || continue
    wid="$(printf '%s' "$w" | jq -r '.id // ""')"
    ticket="$(printf '%s' "$w" | jq -r '.ticket // ""')"
    wrepo="$(printf '%s' "$w" | jq -r '.repo // ""')"
    started="$(printf '%s' "$w" | jq -r '.started_at // ""')"
    [[ -n "$started" ]] || continue
    started_e="$(iso_to_epoch "$started")"
    [[ -n "$started_e" ]] || continue
    idle_secs=$(( now_e - started_e ))
    (( idle_secs < 0 )) && idle_secs=0
    idle_min=$(( idle_secs / 60 ))
    (( idle_secs < threshold_secs )) && continue   # under threshold → not a stall

    row="$(jq -nc \
      --arg worker_id "$wid" --arg ticket "$ticket" --arg repo "$wrepo" \
      --argjson idle_min "$idle_min" --arg status "running" \
      '{worker_id:$worker_id, ticket:$ticket, repo:$repo, idle_min:$idle_min,
        status:$status, verdict:"stalled"}')"
    stalls_jsonl+="$row"$'\n'
  done < <(jq -c '(.workers // [])[] | select(.status == "running")' "$ACTIVE_FILE" 2>/dev/null)
fi

if [[ -n "${stalls_jsonl//[$'\n']/}" ]]; then
  stalls_array="$(printf '%s' "$stalls_jsonl" | jq -sc '.')"
else
  stalls_array='[]'
fi
stall_count="$(printf '%s' "$stalls_array" | jq 'length')"

# --- append events to the append-only monthly jsonl (unless --no-log) ---------
log_file=""
if [[ "$no_log" -eq 0 && "$stall_count" -gt 0 ]]; then
  month="$(date -u +%Y-%m)"
  [[ -n "$now_override" ]] && month="${now_override:0:7}"   # YYYY-MM from --now
  log_file="$LOGS_DIR/stalls-${month}.jsonl"
  mkdir -p "$LOGS_DIR"
  # one JSON object per line: ts, worker_id, ticket, repo, idle_min, verdict
  printf '%s' "$stalls_array" | jq -c --arg ts "$GEN_TS" \
    '.[] | {ts:$ts, worker_id, ticket, repo, idle_min, verdict}' >> "$log_file"
fi
# report the path regardless (so consumers know where events land), even when
# nothing was written this run.
[[ -z "$log_file" ]] && {
  month="$(date -u +%Y-%m)"
  [[ -n "$now_override" ]] && month="${now_override:0:7}"
  log_file="$LOGS_DIR/stalls-${month}.jsonl"
}

# =============================================================================
# OUTPUT
# =============================================================================
if [[ "$json_mode" -eq 1 ]]; then
  jq -nc \
    --arg generated_at "$GEN_TS" \
    --argjson threshold_min "$threshold_min" \
    --argjson active_workers "$active_workers" \
    --argjson stalls "$stalls_array" \
    --argjson stall_count "$stall_count" \
    --arg log_file "$log_file" \
    '{generated_at:$generated_at, threshold_min:$threshold_min,
      active_workers:$active_workers, stalls:$stalls, stall_count:$stall_count,
      log_file:$log_file}'
  exit 0
fi

echo "▸ Worker-stall scan  ($GEN_TS)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  threshold: ${threshold_min}min · active workers: ${active_workers} · stalls: ${stall_count}"
if [[ "$stall_count" -eq 0 ]]; then
  echo "  (no stalled workers)"
else
  printf '%s' "$stalls_array" | jq -r '.[] | "  \(.worker_id // "?") on \(.ticket // "?") [\(.repo // "?")]  idle \(.idle_min)m  → \(.verdict)"'
  echo "  ↳ Commander: cross-check with rescue-worker.sh --probe before acting (idle is a started_at proxy)."
fi
exit 0

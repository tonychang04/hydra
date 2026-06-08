#!/usr/bin/env bash
#
# quota-watch.sh — report-only cost + quota visibility rollup for the operator.
#
# P1/observability (ticket #273). Hydra already has per-ticket cost plumbing
# (cost-rollup.sh, cost-per-pr.sh, trace-cost.sh) and daily counters
# (state/budget-used.json), but no SINGLE operator-facing "how is the fleet
# doing right now?" summary. This aggregates the existing signals — it does NOT
# recompute cost (delegated to cost-per-pr.sh) and adds no token/pricing math.
#
# It is REPORT-ONLY by default: pure stdout, zero side effects. Only `--write`
# refreshes the durable state/quota-health.json (the file the CLAUDE.md preflight
# and hydra-status-output.schema.json already reference). NO soft quotas /
# throttling / auto-pause logic lives here — visibility only (v1 ship principle).
#
# Reads:
#   state/budget-used.json   → tickets/wall-clock/rate-limit counters (missing ⇒ 0)
#   state/autopickup.json    → consecutive_rate_limit_hits (missing ⇒ 0)
#   cost-per-pr.sh --json    → total_cost_usd / cost_per_merged_pr / tickets_counted
#                              (delegated; failures degrade cost fields to null,
#                              exit stays 0 — visibility never blocks on gh/online)
#
# Derives:
#   est_cost_per_ticket = total_cost_usd / tickets_completed_today (null if 0)
#   operator_line       = one-line health string for the greeting / autopickup tick
#
# Pure bash + jq, offline-capable. Style mirrors scripts/cost-per-pr.sh.
#
# Usage:
#   quota-watch.sh [--json | --operator-line] [options]
#
# Output:
#   default          grouped human-readable lines
#   --json           one stable additive JSON object
#   --operator-line  ONLY the one-line health string (greeting / tick consumer)
#
# Options:
#   --state-dir <dir>      State dir (default: $HYDRA_STATE_DIR or ./state).
#                          budget-used.json + autopickup.json resolve under it
#                          unless overridden by --budget-file / --autopickup-file.
#   --budget-file <f>      Override path to budget-used.json.
#   --autopickup-file <f>  Override path to autopickup.json.
#   --logs-dir <dir>       Logs dir passed to cost-per-pr.sh (default $HYDRA_LOGS_DIR
#                          or ./logs).
#   --merged-prs <file>    Offline merged-PR list passed to cost-per-pr.sh (no gh).
#   --write                Also write the snapshot to state/quota-health.json
#                          (or --out). The ONLY side-effecting flag.
#   --out <file>           Destination for --write (default:
#                          <state-dir>/quota-health.json).
#   -h, --help             Show this help.
#
# Exit codes:
#   0  report produced (cost fields may be null if cost-per-pr.sh failed)
#   2  usage error / jq missing
#
# Spec: docs/specs/2026-06-07-quota-watch-cost-visibility.md (ticket #273)

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"
COST_PER_PR="$SCRIPT_DIR/cost-per-pr.sh"

STATE_DEFAULT="${HYDRA_STATE_DIR:-$ROOT_DIR/state}"
LOGS_DEFAULT="${HYDRA_LOGS_DIR:-$ROOT_DIR/logs}"

usage() {
  cat <<'EOF'
Usage: quota-watch.sh [--json | --operator-line] [options]

Report-only cost + quota rollup for the operator. Aggregates today's counters
(state/budget-used.json), consecutive-rate-limit state (state/autopickup.json),
and cost (delegated to cost-per-pr.sh). Pure stdout unless --write is given.

Output modes:
  (default)        human-readable lines
  --json           one stable additive JSON object
  --operator-line  ONLY the one-line health string

Options:
  --state-dir <dir>      State dir (default: $HYDRA_STATE_DIR or ./state).
  --budget-file <f>      Override path to budget-used.json.
  --autopickup-file <f>  Override path to autopickup.json.
  --logs-dir <dir>       Logs dir for cost-per-pr.sh (default $HYDRA_LOGS_DIR or ./logs).
  --merged-prs <file>    Offline merged-PR list for cost-per-pr.sh (no gh).
  --write                Also write the snapshot to state/quota-health.json.
  --out <file>           Destination for --write (default <state-dir>/quota-health.json).
  -h, --help             Show this help.

Exit codes:
  0  report produced  ·  2  usage error / jq missing
EOF
}

command -v jq >/dev/null 2>&1 || { echo "quota-watch: jq required but not found" >&2; exit 2; }

mode="human"          # human | json | operator-line
state_dir="$STATE_DEFAULT"
budget_file=""
autopickup_file=""
logs_dir="$LOGS_DEFAULT"
merged_file=""
do_write=0
out_file=""

die_usage() { echo "quota-watch: $1" >&2; usage >&2; exit 2; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --json)            mode="json"; shift ;;
    --operator-line)   mode="operator-line"; shift ;;
    --state-dir)       [[ $# -ge 2 ]] || die_usage "--state-dir needs a value"; state_dir="$2"; shift 2 ;;
    --state-dir=*)     state_dir="${1#--state-dir=}"; shift ;;
    --budget-file)     [[ $# -ge 2 ]] || die_usage "--budget-file needs a value"; budget_file="$2"; shift 2 ;;
    --budget-file=*)   budget_file="${1#--budget-file=}"; shift ;;
    --autopickup-file) [[ $# -ge 2 ]] || die_usage "--autopickup-file needs a value"; autopickup_file="$2"; shift 2 ;;
    --autopickup-file=*) autopickup_file="${1#--autopickup-file=}"; shift ;;
    --logs-dir)        [[ $# -ge 2 ]] || die_usage "--logs-dir needs a value"; logs_dir="$2"; shift 2 ;;
    --logs-dir=*)      logs_dir="${1#--logs-dir=}"; shift ;;
    --merged-prs)      [[ $# -ge 2 ]] || die_usage "--merged-prs needs a value"; merged_file="$2"; shift 2 ;;
    --merged-prs=*)    merged_file="${1#--merged-prs=}"; shift ;;
    --write)           do_write=1; shift ;;
    --out)             [[ $# -ge 2 ]] || die_usage "--out needs a value"; out_file="$2"; shift 2 ;;
    --out=*)           out_file="${1#--out=}"; shift ;;
    -h|--help)         usage; exit 0 ;;
    *)                 die_usage "unknown argument: $1" ;;
  esac
done

[[ -n "$budget_file" ]]     || budget_file="$state_dir/budget-used.json"
[[ -n "$autopickup_file" ]] || autopickup_file="$state_dir/autopickup.json"
[[ -n "$out_file" ]]        || out_file="$state_dir/quota-health.json"

# --- today's counters from budget-used.json (missing/invalid ⇒ zeros) --------
read_budget() {
  local f="$1" key="$2" default="$3"
  [[ -f "$f" ]] || { printf '%s' "$default"; return; }
  # `jq empty` exits 0 on valid JSON (no output). NB: `jq -e empty` would exit 1
  # because -e treats "no output" as falsy — do NOT use -e here.
  jq empty "$f" >/dev/null 2>&1 || { printf '%s' "$default"; return; }
  jq -r --arg k "$key" --arg d "$default" '(.[$k] // ($d|tonumber))' "$f" 2>/dev/null || printf '%s' "$default"
}

budget_date="$( [[ -f "$budget_file" ]] && jq -r '.date // ""' "$budget_file" 2>/dev/null || true )"
tickets_completed="$(read_budget "$budget_file" tickets_completed_today 0)"
tickets_failed="$(read_budget "$budget_file" tickets_failed_today 0)"
wall_clock_min="$(read_budget "$budget_file" total_worker_wall_clock_minutes_today 0)"
rate_limit_hits="$(read_budget "$budget_file" rate_limit_hits_today 0)"

# --- consecutive-rate-limit state from autopickup.json (missing ⇒ 0) ---------
consecutive_rl=0
if [[ -f "$autopickup_file" ]] && jq empty "$autopickup_file" >/dev/null 2>&1; then
  consecutive_rl="$(jq -r '.consecutive_rate_limit_hits // 0' "$autopickup_file" 2>/dev/null || echo 0)"
fi

# --- cost (delegated to cost-per-pr.sh; degrade to null on any failure) ------
# Never let an online gh lookup block visibility: failures ⇒ cost fields null,
# exit stays 0.
total_cost_usd="null"
cost_per_merged_pr="null"
tickets_counted=0
if [[ -x "$COST_PER_PR" ]] && [[ -d "$logs_dir" ]]; then
  cpp_args=( --json --logs-dir "$logs_dir" )
  [[ -n "$merged_file" ]] && cpp_args+=( --merged-prs "$merged_file" )
  if cpp_json="$("$COST_PER_PR" "${cpp_args[@]}" 2>/dev/null)" && \
     jq empty <<<"$cpp_json" >/dev/null 2>&1; then
    total_cost_usd="$(jq -r '.total_cost_usd // 0' <<<"$cpp_json")"
    cost_per_merged_pr="$(jq -r 'if .cost_per_merged_pr == null then "null" else .cost_per_merged_pr end' <<<"$cpp_json")"
    tickets_counted="$(jq -r '.tickets_counted // 0' <<<"$cpp_json")"
  fi
fi

# --- assemble the snapshot JSON ----------------------------------------------
# est_cost_per_ticket = total_cost_usd / tickets_completed_today (null when 0
# tickets or when cost is unavailable). Rounded to 6 decimals like cost-per-pr.
generated_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

snapshot="$(jq -nc \
  --arg generated_at "$generated_at" \
  --arg date "$budget_date" \
  --argjson tickets_completed "$tickets_completed" \
  --argjson tickets_failed "$tickets_failed" \
  --argjson wall_clock_min "$wall_clock_min" \
  --argjson rate_limit_hits "$rate_limit_hits" \
  --argjson consecutive_rl "$consecutive_rl" \
  --argjson total_cost_usd "$total_cost_usd" \
  --argjson cost_per_merged_pr "$cost_per_merged_pr" \
  --argjson tickets_counted "$tickets_counted" \
  '
  ($total_cost_usd) as $tc
  | (if $tc != null and $tickets_completed > 0
       then (($tc / $tickets_completed) * 1000000 | round) / 1000000
       else null end) as $est
  | {
      generated_at: $generated_at,
      date: (if $date == "" then null else $date end),
      tickets_completed_today: $tickets_completed,
      tickets_failed_today: $tickets_failed,
      wall_clock_min_today: $wall_clock_min,
      rate_limit_hits_today: $rate_limit_hits,
      consecutive_rate_limit_hits: $consecutive_rl,
      github_rate_limit_ok: ($rate_limit_hits == 0),
      linear_rate_limit_ok: ($rate_limit_hits == 0),
      total_cost_usd: $tc,
      cost_per_merged_pr: $cost_per_merged_pr,
      tickets_counted: $tickets_counted,
      est_cost_per_ticket: $est
    }
  ')"

# --- operator one-liner -------------------------------------------------------
# e.g. "Quota: 6 done / 0 failed today · 240 min wall-clock · 0 rate-limit hits
#       (0 consecutive) · $0.42/ticket est · $0.50/merged-PR"
operator_line="$(jq -r '
  "Quota: \(.tickets_completed_today) done / \(.tickets_failed_today) failed today"
  + " · \(.wall_clock_min_today) min wall-clock"
  + " · \(.rate_limit_hits_today) rate-limit hits (\(.consecutive_rate_limit_hits) consecutive)"
  + " · " + (if .est_cost_per_ticket == null then "$n/a/ticket" else "$\(.est_cost_per_ticket)/ticket est" end)
  + " · " + (if .cost_per_merged_pr == null then "$n/a/merged-PR" else "$\(.cost_per_merged_pr)/merged-PR" end)
' <<<"$snapshot")"

snapshot="$(jq -c --arg ol "$operator_line" '. + {operator_line: $ol}' <<<"$snapshot")"

# --- optional durable write (the ONLY side effect) ---------------------------
if [[ "$do_write" -eq 1 ]]; then
  mkdir -p "$(dirname "$out_file")"
  tmp="$(mktemp "${out_file}.XXXXXX")"
  jq . <<<"$snapshot" > "$tmp"
  mv "$tmp" "$out_file"
  echo "quota-watch: wrote snapshot to $out_file" >&2
fi

# --- emit ---------------------------------------------------------------------
case "$mode" in
  json)
    jq . <<<"$snapshot"
    ;;
  operator-line)
    printf '%s\n' "$operator_line"
    ;;
  human)
    jq -r '
      "Tickets today:      \(.tickets_completed_today) done · \(.tickets_failed_today) failed",
      "Wall-clock today:   \(.wall_clock_min_today) min",
      "Rate-limit hits:    \(.rate_limit_hits_today) today · \(.consecutive_rate_limit_hits) consecutive",
      "Total cost:         \(if .total_cost_usd == null then "n/a (cost lookup unavailable)" else "$\(.total_cost_usd)" end)",
      "Cost / ticket:      \(if .est_cost_per_ticket == null then "n/a" else "$\(.est_cost_per_ticket)" end)",
      "Cost / merged PR:   \(if .cost_per_merged_pr == null then "n/a (no merged PRs)" else "$\(.cost_per_merged_pr)" end)",
      "",
      .operator_line
    ' <<<"$snapshot"
    ;;
esac

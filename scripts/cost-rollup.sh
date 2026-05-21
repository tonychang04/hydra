#!/usr/bin/env bash
#
# cost-rollup.sh — write a per-ticket cost rollup into logs/<ticket>.json.
#
# Computes the per-ticket cost from a worker's session trace
# (logs/traces/<ticket>.jsonl, ticket #197) via scripts/trace-cost.sh, then
# MERGES the result into the existing logs/<ticket>.json without clobbering the
# fields the worker already wrote (ticket, pr_url, tests_run, etc.).
#
# It writes both:
#   - a top-level "cost_usd" (the headline number cost-per-pr.sh reads), and
#   - a "cost" object {input_tokens, output_tokens, cost_usd, by_model}.
#
# If logs/<ticket>.json doesn't exist yet, a minimal {ticket, cost_usd, cost}
# object is created (so cost can be recorded before the worker's full log lands).
#
# Pure bash + jq, offline. Atomic write (tmp + mv), matching state-put.sh.
#
# Spec: docs/specs/2026-05-21-per-ticket-cost-and-cost-per-pr.md (ticket #195)

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
TRACE_COST="$SCRIPT_DIR/trace-cost.sh"

LOGS_DEFAULT="${HYDRA_LOGS_DIR:-./logs}"
TRACE_DIR_DEFAULT="${HYDRA_TRACE_DIR:-./logs/traces}"
PRICING_DEFAULT="${HYDRA_PRICING_FILE:-./state/pricing.json}"

usage() {
  cat <<'EOF'
Usage: cost-rollup.sh --ticket <n> [options]

Computes the per-ticket cost from the worker's session trace and merges it into
logs/<ticket>.json (top-level cost_usd + a cost object). Existing fields are
preserved. Creates a minimal log object if none exists.

Required:
  --ticket <n>      Ticket number/ref. Log file is <logs-dir>/<n>.json,
                    trace file is <trace-dir>/<n>.jsonl (unless --trace given).

Options:
  --trace <file>    Trace JSONL (default: <trace-dir>/<ticket>.jsonl).
  --logs-dir <dir>  Logs directory (default: $HYDRA_LOGS_DIR or ./logs).
  --trace-dir <dir> Trace directory (default: $HYDRA_TRACE_DIR or ./logs/traces).
  --pricing <file>  Pricing table (default: $HYDRA_PRICING_FILE or
                    ./state/pricing.json).
  --model <id>      Model for spans without gen_ai.request.model (passed through
                    to trace-cost.sh).
  --dry-run         Print the merged JSON to stdout; do not write the log file.
  -h, --help        Show this help.

Exit codes:
  0  log written (or printed with --dry-run)
  2  usage error / trace not found / jq missing / pricing not found
EOF
}

command -v jq >/dev/null 2>&1 || { echo "cost-rollup: jq required but not found" >&2; exit 2; }
[[ -x "$TRACE_COST" ]] || { echo "cost-rollup: $TRACE_COST not found or not executable" >&2; exit 2; }

ticket=""
trace_file=""
logs_dir="$LOGS_DEFAULT"
trace_dir="$TRACE_DIR_DEFAULT"
pricing_file="$PRICING_DEFAULT"
model_override=""
dry_run=0

die_usage() { echo "cost-rollup: $1" >&2; usage >&2; exit 2; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --ticket)    [[ $# -ge 2 ]] || die_usage "--ticket needs a value"; ticket="$2"; shift 2 ;;
    --trace)     [[ $# -ge 2 ]] || die_usage "--trace needs a value"; trace_file="$2"; shift 2 ;;
    --logs-dir)  [[ $# -ge 2 ]] || die_usage "--logs-dir needs a value"; logs_dir="$2"; shift 2 ;;
    --trace-dir) [[ $# -ge 2 ]] || die_usage "--trace-dir needs a value"; trace_dir="$2"; shift 2 ;;
    --pricing)   [[ $# -ge 2 ]] || die_usage "--pricing needs a value"; pricing_file="$2"; shift 2 ;;
    --model)     [[ $# -ge 2 ]] || die_usage "--model needs a value"; model_override="$2"; shift 2 ;;
    --dry-run)   dry_run=1; shift ;;
    -h|--help)   usage; exit 0 ;;
    *)           die_usage "unknown argument: $1" ;;
  esac
done

[[ -n "$ticket" ]] || die_usage "--ticket is required"
[[ -f "$pricing_file" ]] || die_usage "pricing file not found: $pricing_file"
[[ -n "$trace_file" ]] || trace_file="$trace_dir/$ticket.jsonl"
[[ -f "$trace_file" ]] || die_usage "trace file not found: $trace_file"

# --- compute the cost rollup -------------------------------------------------
cost_args=( rollup --json --pricing "$pricing_file" )
[[ -n "$model_override" ]] && cost_args+=( --model "$model_override" )
cost_json="$("$TRACE_COST" "${cost_args[@]}" "$trace_file")"

# --- merge into logs/<ticket>.json -------------------------------------------
log_file="$logs_dir/$ticket.json"

if [[ -f "$log_file" ]]; then
  base_json="$(cat "$log_file")"
else
  # Minimal log object keyed by the ticket so cost is recordable pre-log.
  base_json="$(jq -nc --arg t "$ticket" '{ticket: $t}')"
fi

merged="$(jq -n \
  --argjson base "$base_json" \
  --argjson cost "$cost_json" \
  '$base + {cost_usd: $cost.cost_usd, cost: $cost}')"

if [[ "$dry_run" -eq 1 ]]; then
  jq . <<<"$merged"
  exit 0
fi

mkdir -p "$logs_dir"
tmp="$(mktemp "${log_file}.XXXXXX")"
jq . <<<"$merged" > "$tmp"
mv "$tmp" "$log_file"

echo "cost-rollup: wrote cost_usd=$(jq -r '.cost_usd' <<<"$merged") to $log_file" >&2

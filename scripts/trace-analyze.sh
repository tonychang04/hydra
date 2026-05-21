#!/usr/bin/env bash
#
# trace-analyze.sh — jq-based analysis over a worker session trace
# (logs/traces/<ticket>.jsonl, produced by scripts/trace-append.sh).
#
# The read path for ticket #197's trace substrate. Pure bash + jq, offline,
# no daemon. Future consumers (#195 cost, #206 watchdog) build on the same
# format; this is the operator/debug helper.
#
# Subcommands:
#   durations   Pair start/end events by span_id → duration in ms. Spans with a
#               start but no end are reported as "incomplete". Instantaneous
#               events (no attrs.phase) are reported as "instant".
#   errors      Spans whose attrs."error.type" is set (the causal-chain failures).
#   tools       Ordered sequence of gen_ai.tool.name from execute_tool start
#               events — the tool-call timeline.
#   summary     Counts: total events, distinct spans, tool calls, errors, and
#               the overall wall-clock span (first ts → last ts).
#
# Input: a trace file as the last positional arg, or trace JSONL on stdin.
# Output: human-readable lines by default; --json for machine-readable output.
#
# Spec: docs/specs/2026-05-21-worker-session-trace.md (ticket #197)

set -euo pipefail

usage() {
  cat <<'EOF'
Usage: trace-analyze.sh <subcommand> [--json] [<trace-file>]

Subcommands:
  durations   Per-span duration (ms). Unpaired starts → "incomplete";
              phase-less events → "instant".
  errors      Spans with attrs."error.type" set.
  tools       Ordered gen_ai.tool.name sequence (execute_tool start events).
  summary     Counts + overall wall-clock span.

Options:
  --json      Emit JSON instead of human-readable lines.
  -h, --help  Show this help.

Input:
  Trace JSONL as the last positional arg (a file), OR on stdin.

Exit codes:
  0  success
  2  usage error / file not found / jq missing
EOF
}

command -v jq >/dev/null 2>&1 || { echo "trace-analyze: jq required but not found" >&2; exit 2; }

subcmd=""
json=0
input_file=""

die_usage() { echo "trace-analyze: $1" >&2; usage >&2; exit 2; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    durations|errors|tools|summary)
      [[ -z "$subcmd" ]] || die_usage "only one subcommand allowed (got '$subcmd' and '$1')"
      subcmd="$1"; shift ;;
    --json)     json=1; shift ;;
    -h|--help)  usage; exit 0 ;;
    -*)         die_usage "unknown option: $1" ;;
    *)
      [[ -z "$input_file" ]] || die_usage "unexpected extra argument: $1"
      input_file="$1"; shift ;;
  esac
done

[[ -n "$subcmd" ]] || die_usage "a subcommand is required"

# Resolve input: file arg, else stdin. Read all events into a jq slurp once;
# each subcommand is then a pure jq transform over the slurped array. (Avoid an
# empty bash array here — `${arr[@]}` on an empty array trips `set -u` on bash
# 3.2 / macOS.)
if [[ -n "$input_file" ]]; then
  [[ -f "$input_file" ]] || die_usage "trace file not found: $input_file"
  events_json="$(jq -s '.' "$input_file")"
else
  events_json="$(jq -s '.')"
fi

# --- jq programs -------------------------------------------------------------
# epoch-ms from an ISO-8601 "...HH:MM:SS.mmmZ" timestamp. jq's fromdateiso8601
# does not parse fractional seconds, so split off the .mmm and add it back.
read -r -d '' EPOCH_MS_DEF <<'JQ' || true
def epoch_ms($ts):
  ($ts | capture("^(?<base>[^.]+)(?:\\.(?<frac>[0-9]+))?Z?$")) as $m
  | (($m.base + "Z") | fromdateiso8601) * 1000
    + (($m.frac // "0") | (. + "000")[0:3] | tonumber);
JQ

# durations: group by span_id; pair start/end; phase-less single → instant.
read -r -d '' DURATIONS_JQ <<JQ || true
$EPOCH_MS_DEF
group_by(.span_id)
| map(
    (.[0].span_id) as \$sid
    | (map(select(.attrs.phase == "start"))[0]) as \$start
    | (map(select(.attrs.phase == "end"))[0]) as \$end
    | (map(select(.attrs.phase == null))[0]) as \$instant
    | if \$instant != null and \$start == null then
        {span_id: \$sid, kind: \$instant.kind, status: "instant", duration_ms: null}
      elif \$start != null and \$end != null then
        {span_id: \$sid, kind: \$start.kind, status: "complete",
         duration_ms: (epoch_ms(\$end.ts) - epoch_ms(\$start.ts))}
      elif \$start != null and \$end == null then
        {span_id: \$sid, kind: \$start.kind, status: "incomplete", duration_ms: null}
      else
        {span_id: \$sid, kind: (.[0].kind), status: "unknown", duration_ms: null}
      end
  )
JQ

read -r -d '' ERRORS_JQ <<'JQ' || true
map(select(.attrs."error.type" != null))
| map({span_id, kind, ts, error_type: .attrs."error.type",
       tool: .attrs."gen_ai.tool.name", test: .attrs."hydra.test.name"})
JQ

read -r -d '' TOOLS_JQ <<'JQ' || true
map(select(.kind == "execute_tool" and .attrs.phase == "start"))
| map({span_id, tool: .attrs."gen_ai.tool.name", ts})
JQ

read -r -d '' SUMMARY_JQ <<JQ || true
$EPOCH_MS_DEF
{
  events: length,
  spans: ([.[].span_id] | unique | length),
  tool_calls: (map(select(.kind == "execute_tool" and .attrs.phase == "start")) | length),
  errors: (map(select(.attrs."error.type" != null)) | length),
  wall_ms: (
    if length == 0 then 0
    else (epoch_ms([.[].ts] | max) - epoch_ms([.[].ts] | min))
    end
  )
}
JQ

# --- run + render ------------------------------------------------------------
case "$subcmd" in
  durations) result="$(jq -c "$DURATIONS_JQ" <<<"$events_json")" ;;
  errors)    result="$(jq -c "$ERRORS_JQ"    <<<"$events_json")" ;;
  tools)     result="$(jq -c "$TOOLS_JQ"     <<<"$events_json")" ;;
  summary)   result="$(jq -c "$SUMMARY_JQ"   <<<"$events_json")" ;;
esac

if [[ "$json" -eq 1 ]]; then
  jq . <<<"$result"
  exit 0
fi

# Human-readable rendering.
case "$subcmd" in
  durations)
    jq -r '.[] | "\(.span_id)\t\(.kind)\t\(.status)\t\(if .duration_ms == null then "-" else "\(.duration_ms)ms" end)"' <<<"$result"
    ;;
  errors)
    jq -r '.[] | "\(.span_id)\t\(.error_type)\t\(.tool // "-")\t\(.test // "-")"' <<<"$result"
    ;;
  tools)
    jq -r '.[] | "\(.tool)"' <<<"$result"
    ;;
  summary)
    jq -r '"events:     \(.events)\nspans:      \(.spans)\ntool_calls: \(.tool_calls)\nerrors:     \(.errors)\nwall_ms:    \(.wall_ms)"' <<<"$result"
    ;;
esac

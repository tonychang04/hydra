#!/usr/bin/env bash
#
# trace-append.sh — append one span event to a worker's session trace.
#
# A worker calls this at known points in its run (tool start/end, test run,
# the root invoke_agent span) to build an append-only, replayable record at
# logs/traces/<ticket>.jsonl — one JSON object per line, one line per event.
#
# Vocabulary is OpenTelemetry GenAI semantic-convention attribute names
# (gen_ai.operation.name, gen_ai.tool.name, gen_ai.usage.*_tokens, error.type),
# so the format is recognizable to the future consumers (#195 cost, #206
# watchdog) and to external OTel tooling. No daemon, no backend: pure bash+jq.
#
# Output line shape (the five top-level keys are stable):
#   {
#     "ts": "2026-05-21T18:30:00.123Z",
#     "span_id": "<id>",
#     "parent_span_id": "<id>" | null,
#     "kind": "invoke_agent" | "execute_tool" | "chat",
#     "attrs": { "gen_ai.operation.name": "...", ... }
#   }
#
# Duration-bearing spans (a tool call, the whole run) emit two events sharing
# one span_id: --phase start then --phase end. trace-analyze.sh pairs them.
# Instantaneous events omit --phase (single line). phase, when given, lives in
# attrs.phase so the five top-level keys stay stable for #206's tail-reader.
#
# Content safety: gen_ai.prompt / gen_ai.completion are sensitive (OTel marks
# message content sensitive; Hydra's secrets hard-rail forbids leaking prompts).
# They are DROPPED with a stderr warning unless --with-content (or
# HYDRA_TRACE_CONTENT=1) is set. The event is still written.
#
# Spec: docs/specs/2026-05-21-worker-session-trace.md (ticket #197)

set -euo pipefail

TRACE_DIR_DEFAULT="${HYDRA_TRACE_DIR:-./logs/traces}"

# Attribute names treated as sensitive (content). Dropped unless --with-content.
SENSITIVE_ATTRS=("gen_ai.prompt" "gen_ai.completion")

usage() {
  cat <<'EOF'
Usage: trace-append.sh --ticket <n> --kind <k> [options]

Appends one span event to <trace-dir>/<ticket>.jsonl and prints the span_id
on stdout (so a caller can reuse it as --parent-span-id or to pair start/end).

Required:
  --ticket <n>          Ticket number/ref. Trace file is <trace-dir>/<n>.jsonl.
  --kind <k>            Span kind: invoke_agent | execute_tool | chat.
                        Copied into attrs["gen_ai.operation.name"].

Options:
  --span-id <id>        Span id. Generated if omitted (printed on stdout).
  --parent-span-id <id> Parent span's id. Omit for a root span.
  --phase <p>           start | end for a duration-bearing span (stored as
                        attrs.phase). Omit for an instantaneous single event.
  --attr k=v            Add attribute k=v to attrs. Repeatable. Values are
                        stored as strings; integer-looking values are stored
                        as numbers (so gen_ai.usage.*_tokens are numeric).
  --with-content        Allow sensitive content attrs (gen_ai.prompt,
                        gen_ai.completion). Default: drop them with a warning.
  --trace-dir <path>    Trace directory (default: $HYDRA_TRACE_DIR or
                        ./logs/traces). Auto-created.
  -h, --help            Show this help.

Exit codes:
  0  event written
  2  usage error
EOF
}

# --- argument parsing --------------------------------------------------------
ticket=""
kind=""
span_id=""
parent_span_id=""
phase=""
trace_dir="$TRACE_DIR_DEFAULT"
with_content=0
attr_keys=()
attr_vals=()

die_usage() { echo "trace-append: $1" >&2; usage >&2; exit 2; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --ticket)          [[ $# -ge 2 ]] || die_usage "--ticket needs a value"; ticket="$2"; shift 2 ;;
    --kind)            [[ $# -ge 2 ]] || die_usage "--kind needs a value"; kind="$2"; shift 2 ;;
    --span-id)         [[ $# -ge 2 ]] || die_usage "--span-id needs a value"; span_id="$2"; shift 2 ;;
    --parent-span-id)  [[ $# -ge 2 ]] || die_usage "--parent-span-id needs a value"; parent_span_id="$2"; shift 2 ;;
    --phase)           [[ $# -ge 2 ]] || die_usage "--phase needs a value"; phase="$2"; shift 2 ;;
    --trace-dir)       [[ $# -ge 2 ]] || die_usage "--trace-dir needs a value"; trace_dir="$2"; shift 2 ;;
    --with-content)    with_content=1; shift ;;
    --attr)
      [[ $# -ge 2 ]] || die_usage "--attr needs a k=v value"
      case "$2" in
        *=*) attr_keys+=("${2%%=*}"); attr_vals+=("${2#*=}") ;;
        *)   die_usage "--attr value must be k=v (got '$2')" ;;
      esac
      shift 2
      ;;
    -h|--help)         usage; exit 0 ;;
    *)                 die_usage "unknown argument: $1" ;;
  esac
done

[[ -n "$ticket" ]] || die_usage "--ticket is required"
[[ -n "$kind" ]]   || die_usage "--kind is required"
case "$kind" in
  invoke_agent|execute_tool|chat) ;;
  *) die_usage "--kind must be invoke_agent | execute_tool | chat (got '$kind')" ;;
esac
if [[ -n "$phase" ]]; then
  case "$phase" in
    start|end) ;;
    *) die_usage "--phase must be start | end (got '$phase')" ;;
  esac
fi
if [[ "${HYDRA_TRACE_CONTENT:-}" == "1" ]]; then with_content=1; fi

command -v jq >/dev/null 2>&1 || { echo "trace-append: jq required but not found" >&2; exit 2; }

# This script never reads stdin. Close it so the `jq -n` (null-input) calls
# below can never block waiting on an inherited interactive/pipe stdin
# (Apple jq 1.7.x can drain stdin even with -n in some invocations).
exec </dev/null

# --- generate span_id + timestamp -------------------------------------------
gen_id() {
  # 16 hex chars. uuidgen if present, else urandom, else $RANDOM fallback.
  if command -v uuidgen >/dev/null 2>&1; then
    uuidgen | tr -d '-' | tr 'A-Z' 'a-z' | cut -c1-16
  elif [[ -r /dev/urandom ]]; then
    head -c 8 /dev/urandom | od -An -tx1 | tr -d ' \n'
  else
    printf '%04x%04x%04x%04x' "$RANDOM" "$RANDOM" "$RANDOM" "$RANDOM"
  fi
}
[[ -n "$span_id" ]] || span_id="$(gen_id)"

iso_now() {
  # ISO-8601 UTC with millisecond precision.
  if date -u +%Y-%m-%dT%H:%M:%S.%3NZ 2>/dev/null | grep -q '\.[0-9]\{3\}Z$'; then
    date -u +%Y-%m-%dT%H:%M:%S.%3NZ
  else
    # macOS/BSD date lacks %N — synthesize milliseconds.
    local secs ms
    secs="$(date -u +%Y-%m-%dT%H:%M:%S)"
    ms="$(printf '%03d' $(( (RANDOM % 1000) )) )"
    printf '%s.%sZ\n' "$secs" "$ms"
  fi
}
ts="$(iso_now)"

# --- build attrs object ------------------------------------------------------
# Start from gen_ai.operation.name = kind so OTel readers + our jq agree.
attrs='{"gen_ai.operation.name": '"$(jq -nc --arg k "$kind" '$k')"'}'
if [[ -n "$phase" ]]; then
  attrs="$(jq -c --arg p "$phase" '. + {"phase": $p}' <<<"$attrs")"
fi

is_sensitive() {
  local key="$1" s
  for s in "${SENSITIVE_ATTRS[@]}"; do
    [[ "$key" == "$s" ]] && return 0
  done
  return 1
}

# Guard the empty case explicitly: bash 3.2 (macOS) trips `set -u` on
# ${!arr[@]} when the array is empty, and `${!arr[@]:-}` mis-collapses a
# non-empty index list to a single empty element. A length check sidesteps both.
for (( i = 0; i < ${#attr_keys[@]}; i++ )); do
  k="${attr_keys[$i]}"
  v="${attr_vals[$i]}"
  if is_sensitive "$k" && [[ "$with_content" -ne 1 ]]; then
    echo "trace-append: dropping sensitive attr '$k' (use --with-content to keep)" >&2
    continue
  fi
  # Numeric if it's a plain integer (so token counts stay numeric); else string.
  if [[ "$v" =~ ^-?[0-9]+$ ]]; then
    attrs="$(jq -c --arg k "$k" --argjson v "$v" '. + {($k): $v}' <<<"$attrs")"
  else
    attrs="$(jq -c --arg k "$k" --arg v "$v" '. + {($k): $v}' <<<"$attrs")"
  fi
done

# --- assemble the event line -------------------------------------------------
# Pass parent_span_id as a jq string arg, or JSON null when absent. Use a
# single --argjson so we never have to expand a possibly-empty bash array
# (which trips `set -u` on bash 3.2 / macOS).
if [[ -n "$parent_span_id" ]]; then
  parent_json="$(jq -nc --arg p "$parent_span_id" '$p')"
else
  parent_json='null'
fi

line="$(jq -nc \
  --arg ts "$ts" \
  --arg span "$span_id" \
  --argjson parent "$parent_json" \
  --arg kind "$kind" \
  --argjson attrs "$attrs" \
  '{ts: $ts, span_id: $span, parent_span_id: $parent, kind: $kind, attrs: $attrs}')"

# --- append (atomic single-line append; single writer per ticket file) -------
mkdir -p "$trace_dir"
trace_file="$trace_dir/$ticket.jsonl"
printf '%s\n' "$line" >> "$trace_file"

# Echo the span_id so callers can pair start/end or set parent_span_id.
printf '%s\n' "$span_id"

#!/usr/bin/env bash
#
# trace-cost.sh — compute USD cost from a worker session trace.
#
# Reads a logs/traces/<ticket>.jsonl (produced by scripts/trace-append.sh,
# ticket #197), sums the OTel-GenAI token-usage attrs that the substrate already
# captures as JSON numbers (gen_ai.usage.input_tokens / output_tokens), and
# multiplies by a per-model pricing table (state/pricing.json) to produce a
# cost_usd per span and a per-ticket rollup.
#
# This is the #195 cost CONSUMER of the #197 trace substrate. It only READS
# token attrs — trace-append.sh already emits them numerically. Pure bash + jq,
# offline, no daemon.
#
# Subcommands:
#   spans    Per token-bearing span: {span_id, model, input_tokens,
#            output_tokens, cost_usd}.
#   rollup   Per-ticket total: {input_tokens, output_tokens, cost_usd,
#            by_model: {<model>: {input_tokens, output_tokens, cost_usd}}}.
#
# Cost: cost_usd = input_tokens/1e6 * input_rate + output_tokens/1e6 * output_rate.
# Model per span: attrs."gen_ai.request.model" if set, else --model, else the
# pricing table "default" entry (so an unknown model is never silently $0).
#
# Spec: docs/specs/2026-05-21-per-ticket-cost-and-cost-per-pr.md (ticket #195)

set -euo pipefail

PRICING_DEFAULT="${HYDRA_PRICING_FILE:-./state/pricing.json}"

usage() {
  cat <<'EOF'
Usage: trace-cost.sh <subcommand> [options] [<trace-file>]

Subcommands:
  spans     Per token-bearing span cost.
  rollup    Per-ticket cost rollup (totals + by_model breakdown).

Options:
  --pricing <file>  Pricing table (default: $HYDRA_PRICING_FILE or
                    ./state/pricing.json).
  --model <id>      Model id for spans that don't carry
                    attrs."gen_ai.request.model". Default: the table "default".
  --json            Emit JSON instead of human-readable lines.
  -h, --help        Show this help.

Input:
  Trace JSONL as the last positional arg (a file), OR on stdin.

Exit codes:
  0  success
  2  usage error / file not found / jq missing / pricing file not found
EOF
}

command -v jq >/dev/null 2>&1 || { echo "trace-cost: jq required but not found" >&2; exit 2; }

subcmd=""
json=0
input_file=""
pricing_file="$PRICING_DEFAULT"
model_override=""

die_usage() { echo "trace-cost: $1" >&2; usage >&2; exit 2; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    spans|rollup)
      [[ -z "$subcmd" ]] || die_usage "only one subcommand allowed (got '$subcmd' and '$1')"
      subcmd="$1"; shift ;;
    --pricing)  [[ $# -ge 2 ]] || die_usage "--pricing needs a value"; pricing_file="$2"; shift 2 ;;
    --model)    [[ $# -ge 2 ]] || die_usage "--model needs a value"; model_override="$2"; shift 2 ;;
    --json)     json=1; shift ;;
    -h|--help)  usage; exit 0 ;;
    -*)         die_usage "unknown option: $1" ;;
    *)
      [[ -z "$input_file" ]] || die_usage "unexpected extra argument: $1"
      input_file="$1"; shift ;;
  esac
done

[[ -n "$subcmd" ]] || die_usage "a subcommand is required"
[[ -f "$pricing_file" ]] || die_usage "pricing file not found: $pricing_file"

# Resolve input: file arg, else stdin. Slurp the events into a single array once.
if [[ -n "$input_file" ]]; then
  [[ -f "$input_file" ]] || die_usage "trace file not found: $input_file"
  events_json="$(jq -s '.' "$input_file")"
else
  events_json="$(jq -s '.')"
fi

pricing_json="$(cat "$pricing_file")"

# --- jq programs -------------------------------------------------------------
# Shared cost helper: given $pricing, $default_model, derive per-span cost.
# A span "bears tokens" if either usage attr is present and > 0. The model is
# the span's gen_ai.request.model, else $default_model, else "default".
read -r -d '' COST_DEFS <<'JQ' || true
def rate($pricing; $model):
  ($pricing.models[$model] // $pricing.models["default"]) as $r
  | {input: ($r.input // 0), output: ($r.output // 0)};

# Treat "" (jq-truthy but meaningless here) like null so the fallback chain
# reaches the literal "default" when neither the span nor --model names a model.
def nz($v): if ($v == null or $v == "") then null else $v end;

def span_model($default):
  (nz(.attrs."gen_ai.request.model")) // (nz($default)) // "default";

def span_cost($pricing; $default):
  (.attrs."gen_ai.usage.input_tokens" // 0) as $in
  | (.attrs."gen_ai.usage.output_tokens" // 0) as $out
  | span_model($default) as $m
  | rate($pricing; $m) as $r
  | (($in / 1000000) * $r.input + ($out / 1000000) * $r.output) as $c
  | {span_id, model: $m, input_tokens: $in, output_tokens: $out,
     cost_usd: (($c * 1000000 | round) / 1000000)};

# A span carries usage iff at least one usage attr key is present.
def bears_tokens:
  (.attrs | has("gen_ai.usage.input_tokens") or has("gen_ai.usage.output_tokens"));
JQ

SPANS_JQ="$COST_DEFS"'
map(select(bears_tokens) | span_cost($pricing; $default))'

ROLLUP_JQ="$COST_DEFS"'
[ .[] | select(bears_tokens) | span_cost($pricing; $default) ] as $spans
| {
    input_tokens:  ([$spans[].input_tokens]  | add // 0),
    output_tokens: ([$spans[].output_tokens] | add // 0),
    cost_usd: ((([$spans[].cost_usd] | add // 0) * 1000000 | round) / 1000000),
    by_model: (
      $spans
      | group_by(.model)
      | map({
          key: .[0].model,
          value: {
            input_tokens:  ([.[].input_tokens]  | add // 0),
            output_tokens: ([.[].output_tokens] | add // 0),
            cost_usd: ((([.[].cost_usd] | add // 0) * 1000000 | round) / 1000000)
          }
        })
      | from_entries
    )
  }'

# --- run + render ------------------------------------------------------------
default_arg="${model_override:-}"
case "$subcmd" in
  spans)  result="$(jq -c --argjson pricing "$pricing_json" --arg default "$default_arg" "$SPANS_JQ"  <<<"$events_json")" ;;
  rollup) result="$(jq -c --argjson pricing "$pricing_json" --arg default "$default_arg" "$ROLLUP_JQ" <<<"$events_json")" ;;
esac

if [[ "$json" -eq 1 ]]; then
  jq . <<<"$result"
  exit 0
fi

case "$subcmd" in
  spans)
    jq -r '.[] | "\(.span_id)\t\(.model)\t\(.input_tokens)in\t\(.output_tokens)out\t$\(.cost_usd * 10000 | round / 10000)"' <<<"$result"
    ;;
  rollup)
    jq -r '
      "input_tokens:  \(.input_tokens)",
      "output_tokens: \(.output_tokens)",
      "cost_usd:      $\((.cost_usd * 10000 | round) / 10000)",
      "by_model:",
      (.by_model | to_entries[] | "  \(.key): $\((.value.cost_usd * 10000 | round) / 10000) (\(.value.input_tokens)in/\(.value.output_tokens)out)")
    ' <<<"$result"
    ;;
esac

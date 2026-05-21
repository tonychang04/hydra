#!/usr/bin/env bash
#
# test-cost.sh — regression test for the cost-attribution consumers:
#   scripts/trace-cost.sh   (per-span + per-ticket cost from trace token attrs)
#   scripts/cost-rollup.sh  (merge cost_usd into logs/<ticket>.json)
#   scripts/cost-per-pr.sh  (cost ÷ merged-PRs headline metric)
#
# Exercises (all offline, bash + jq, no network/docker):
#   TRACE-COST
#     - exact pricing math (1M in + 1M out at opus 15/75 → $90)
#     - per-model rollup (opus span + default span; by_model has both)
#     - --model override re-prices a model-less trace
#     - degrade-safe: a trace with no usage attrs → cost_usd 0, exit 0
#     - spans subcommand emits one record per token-bearing span
#     - unknown model falls back to the table "default" rate (never $0)
#     - usage errors: no subcommand / missing file / missing pricing → exit 2
#   COST-ROLLUP
#     - merges cost_usd + cost into an existing log, preserving other fields
#     - --dry-run prints without writing
#     - creates a minimal {ticket, cost_usd, cost} when no log exists
#     - missing trace → exit 2
#   COST-PER-PR
#     - offline --merged-prs join: total over merged, merged count, per-PR
#     - handles string-or-int ticket + null pr_url
#     - divide-by-zero guard: no merged PRs → cost_per_merged_pr null, exit 0
#     - --include-unmerged surfaces unmerged spend
#     - missing logs dir → exit 2
#
# Style: matches scripts/test-trace.sh — bash, colored output, pass/fail
# counter, mktemp fixtures, no external harness.
#
# Spec: docs/specs/2026-05-21-per-ticket-cost-and-cost-per-pr.md (ticket #195)

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"
TRACE_COST="$SCRIPT_DIR/trace-cost.sh"
COST_ROLLUP="$SCRIPT_DIR/cost-rollup.sh"
COST_PER_PR="$SCRIPT_DIR/cost-per-pr.sh"
PRICING="$ROOT_DIR/state/pricing.json"
FIXDIR="$ROOT_DIR/self-test/fixtures/cost-attribution"

for f in "$TRACE_COST" "$COST_ROLLUP" "$COST_PER_PR"; do
  [[ -x "$f" ]] || { echo "test-cost: $f not found or not executable" >&2; exit 2; }
done
[[ -f "$PRICING" ]] || { echo "test-cost: pricing table missing: $PRICING" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "test-cost: jq required" >&2; exit 2; }

if [[ -t 1 ]] && [[ "${NO_COLOR:-}" != "1" ]]; then
  C_GREEN=$'\033[32m'; C_RED=$'\033[31m'; C_BOLD=$'\033[1m'; C_RESET=$'\033[0m'
else
  C_GREEN=""; C_RED=""; C_BOLD=""; C_RESET=""
fi

passed=0
failed=0
say() { printf "\n${C_BOLD}▸ %s${C_RESET}\n" "$*"; }
ok()  { printf "  ${C_GREEN}✓${C_RESET} %s\n" "$*"; passed=$((passed + 1)); }
bad() { printf "  ${C_RED}✗${C_RESET} %s\n" "$*"; failed=$((failed + 1)); }

# assert_eq <label> <expected> <actual>
assert_eq() {
  if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1 (expected [$2], got [$3])"; fi
}

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

tc() { "$TRACE_COST" "$@" --pricing "$PRICING"; }

# =============================================================================
say "TRACE-COST: exact pricing math (1M in + 1M out @ opus 15/75 = \$90)"
# =============================================================================
opus1m="$tmpdir/opus1m.jsonl"
cat > "$opus1m" <<'JSON'
{"ts":"2026-05-21T18:00:00.000Z","span_id":"c1","parent_span_id":null,"kind":"chat","attrs":{"gen_ai.operation.name":"chat","gen_ai.request.model":"claude-opus-4-7","gen_ai.usage.input_tokens":1000000,"gen_ai.usage.output_tokens":1000000}}
JSON
assert_eq "1M+1M opus → cost_usd 90" "90" "$(tc rollup --json "$opus1m" | jq -r '.cost_usd')"

# =============================================================================
say "TRACE-COST: per-model rollup (opus span + default/model-less span)"
# =============================================================================
mixed="$tmpdir/mixed.jsonl"
cat > "$mixed" <<'JSON'
{"ts":"2026-05-21T18:00:00.000Z","span_id":"c1","parent_span_id":null,"kind":"chat","attrs":{"gen_ai.operation.name":"chat","gen_ai.request.model":"claude-opus-4-7","gen_ai.usage.input_tokens":1000000,"gen_ai.usage.output_tokens":0}}
{"ts":"2026-05-21T18:00:01.000Z","span_id":"c2","parent_span_id":null,"kind":"chat","attrs":{"gen_ai.operation.name":"chat","gen_ai.usage.input_tokens":2000000,"gen_ai.usage.output_tokens":0}}
JSON
mixed_json="$(tc rollup --json "$mixed")"
# opus: 1M*15 = 15 ; default(opus rate): 2M*15 = 30 ; total 45
assert_eq "mixed total cost_usd" "45" "$(jq -r '.cost_usd' <<<"$mixed_json")"
assert_eq "by_model has opus entry" "15" "$(jq -r '.by_model."claude-opus-4-7".cost_usd' <<<"$mixed_json")"
assert_eq "by_model has default entry" "30" "$(jq -r '.by_model.default.cost_usd' <<<"$mixed_json")"
assert_eq "total input_tokens summed" "3000000" "$(jq -r '.input_tokens' <<<"$mixed_json")"

# =============================================================================
say "TRACE-COST: --model override re-prices a model-less trace"
# =============================================================================
modelless="$tmpdir/modelless.jsonl"
cat > "$modelless" <<'JSON'
{"ts":"2026-05-21T18:00:00.000Z","span_id":"c1","parent_span_id":null,"kind":"chat","attrs":{"gen_ai.operation.name":"chat","gen_ai.usage.input_tokens":1000000,"gen_ai.usage.output_tokens":1000000}}
JSON
# sonnet 3/15 → 1M*3 + 1M*15 = 18
assert_eq "--model sonnet re-prices to 18" "18" "$(tc rollup --json --model claude-sonnet-4-5 "$modelless" | jq -r '.cost_usd')"
assert_eq "model-less defaults to 'default' name" "default" "$(tc rollup --json "$modelless" | jq -r '.by_model | keys[0]')"

# =============================================================================
say "TRACE-COST: degrade-safe (no usage attrs → cost 0) + spans + unknown model"
# =============================================================================
notok="$tmpdir/notok.jsonl"
cat > "$notok" <<'JSON'
{"ts":"2026-05-21T18:00:00.000Z","span_id":"t1","parent_span_id":null,"kind":"execute_tool","attrs":{"gen_ai.operation.name":"execute_tool","gen_ai.tool.name":"Bash"}}
JSON
set +e; notok_json="$(tc rollup --json "$notok")"; rc_notok=$?; set -e
assert_eq "no-usage trace exits 0" "0" "$rc_notok"
assert_eq "no-usage trace cost 0" "0" "$(jq -r '.cost_usd' <<<"$notok_json")"
assert_eq "spans emits one record per token span" "1" "$(tc spans --json "$opus1m" | jq 'length')"
unknown="$tmpdir/unknown.jsonl"
cat > "$unknown" <<'JSON'
{"ts":"2026-05-21T18:00:00.000Z","span_id":"c1","parent_span_id":null,"kind":"chat","attrs":{"gen_ai.operation.name":"chat","gen_ai.request.model":"some-future-model","gen_ai.usage.input_tokens":1000000,"gen_ai.usage.output_tokens":0}}
JSON
# unknown model → default rate 15 → 1M*15 = 15 (never silently 0)
assert_eq "unknown model priced at default rate" "15" "$(tc rollup --json "$unknown" | jq -r '.cost_usd')"

# =============================================================================
say "TRACE-COST: usage errors → exit 2"
# =============================================================================
set +e
# Call the script directly (not via tc, which appends a valid --pricing).
"$TRACE_COST" rollup --pricing /no/such/pricing.json "$opus1m" >/dev/null 2>&1; rc_badprice=$?
tc rollup "$tmpdir/nope.jsonl" >/dev/null 2>&1; rc_badtrace=$?
tc "$opus1m" >/dev/null 2>&1; rc_nosub=$?
set -e
assert_eq "missing pricing → exit 2" "2" "$rc_badprice"
assert_eq "missing trace → exit 2" "2" "$rc_badtrace"
assert_eq "no subcommand → exit 2" "2" "$rc_nosub"

# =============================================================================
say "COST-ROLLUP: merge into existing log preserves fields"
# =============================================================================
logs="$tmpdir/logs"
mkdir -p "$logs"
cat > "$logs/197.json" <<'JSON'
{"ticket":197,"tier":"T2","pr_url":"https://github.com/o/r/pull/207","tests_run":[{"cmd":"x","result":"pass"}]}
JSON
"$COST_ROLLUP" --ticket 197 --logs-dir "$logs" --trace "$opus1m" --pricing "$PRICING" 2>/dev/null
merged_log="$(cat "$logs/197.json")"
assert_eq "rollup adds cost_usd" "90" "$(jq -r '.cost_usd' <<<"$merged_log")"
assert_eq "rollup preserves tier" "T2" "$(jq -r '.tier' <<<"$merged_log")"
assert_eq "rollup preserves pr_url" "https://github.com/o/r/pull/207" "$(jq -r '.pr_url' <<<"$merged_log")"
assert_eq "rollup preserves tests_run" "pass" "$(jq -r '.tests_run[0].result' <<<"$merged_log")"
assert_eq "rollup writes cost.by_model" "90" "$(jq -r '.cost.by_model."claude-opus-4-7".cost_usd' <<<"$merged_log")"

# --dry-run does not write
cat > "$logs/198.json" <<'JSON'
{"ticket":198,"tier":"T1"}
JSON
"$COST_ROLLUP" --ticket 198 --logs-dir "$logs" --trace "$opus1m" --pricing "$PRICING" --dry-run >/dev/null 2>&1
assert_eq "--dry-run leaves log unchanged" "null" "$(jq -r '.cost_usd // "null"' "$logs/198.json")"

# minimal-create when no log exists
"$COST_ROLLUP" --ticket 999 --logs-dir "$logs" --trace "$opus1m" --pricing "$PRICING" 2>/dev/null
assert_eq "minimal log records ticket" "999" "$(jq -r '.ticket' "$logs/999.json")"
assert_eq "minimal log records cost_usd" "90" "$(jq -r '.cost_usd' "$logs/999.json")"

set +e
"$COST_ROLLUP" --ticket 197 --logs-dir "$logs" --trace "$tmpdir/nope.jsonl" --pricing "$PRICING" >/dev/null 2>&1; rc_rollup_missing=$?
"$COST_ROLLUP" --logs-dir "$logs" --trace "$opus1m" --pricing "$PRICING" >/dev/null 2>&1; rc_rollup_noticket=$?
set -e
assert_eq "missing trace → exit 2" "2" "$rc_rollup_missing"
assert_eq "missing --ticket → exit 2" "2" "$rc_rollup_noticket"

# =============================================================================
say "COST-PER-PR: offline merged join + string/int tickets + null pr_url"
# =============================================================================
plogs="$tmpdir/plogs"
mkdir -p "$plogs"
cat > "$plogs/100.json" <<'JSON'
{"ticket":100,"pr_url":"https://github.com/o/r/pull/1","cost_usd":2.0}
JSON
cat > "$plogs/101.json" <<'JSON'
{"ticket":"o/r#101","pr_url":"https://github.com/o/r/pull/2","cost_usd":1.0}
JSON
cat > "$plogs/102.json" <<'JSON'
{"ticket":102,"cost_usd":0.5}
JSON
echo "https://github.com/o/r/pull/1" > "$tmpdir/merged.txt"
ppr_json="$("$COST_PER_PR" --logs-dir "$plogs" --merged-prs "$tmpdir/merged.txt" --json)"
assert_eq "total over merged PRs" "2" "$(jq -r '.total_cost_usd' <<<"$ppr_json")"
assert_eq "merged PR count" "1" "$(jq -r '.merged_prs' <<<"$ppr_json")"
assert_eq "cost per merged PR" "2" "$(jq -r '.cost_per_merged_pr' <<<"$ppr_json")"
assert_eq "tickets counted" "3" "$(jq -r '.tickets_counted' <<<"$ppr_json")"
assert_eq "unmerged + no-PR spend" "1.5" "$(jq -r '.unmerged_cost_usd' <<<"$ppr_json")"

# =============================================================================
say "COST-PER-PR: divide-by-zero guard + include-unmerged + usage error"
# =============================================================================
: > "$tmpdir/none.txt"
set +e; dz_json="$("$COST_PER_PR" --logs-dir "$plogs" --merged-prs "$tmpdir/none.txt" --json)"; rc_dz=$?; set -e
assert_eq "no merged PRs exits 0" "0" "$rc_dz"
assert_eq "no merged PRs → cost_per_merged_pr null" "null" "$(jq -r '.cost_per_merged_pr' <<<"$dz_json")"
assert_eq "no merged PRs → merged_prs 0" "0" "$(jq -r '.merged_prs' <<<"$dz_json")"

unm="$("$COST_PER_PR" --logs-dir "$plogs" --merged-prs "$tmpdir/merged.txt" --include-unmerged | grep -c 'unmerged/no-PR spend')"
assert_eq "--include-unmerged prints a spend line" "1" "$unm"

set +e
"$COST_PER_PR" --logs-dir "$tmpdir/no-such-dir" --merged-prs "$tmpdir/merged.txt" >/dev/null 2>&1; rc_ppr_baddir=$?
set -e
assert_eq "missing logs dir → exit 2" "2" "$rc_ppr_baddir"

# =============================================================================
say "FIXTURE: committed cost-attribution fixture round-trips"
# =============================================================================
if [[ -f "$FIXDIR/sample-trace.jsonl" ]]; then
  fix_cost="$(tc rollup --json "$FIXDIR/sample-trace.jsonl" | jq -r '.cost_usd')"
  if [[ -n "$fix_cost" && "$fix_cost" != "null" ]]; then ok "fixture trace yields a cost_usd ($fix_cost)"; else bad "fixture trace cost_usd missing"; fi
else
  bad "fixture sample-trace.jsonl missing at $FIXDIR"
fi
if [[ -d "$FIXDIR/logs" && -f "$FIXDIR/merged-prs.txt" ]]; then
  fix_ppr="$("$COST_PER_PR" --logs-dir "$FIXDIR/logs" --merged-prs "$FIXDIR/merged-prs.txt" --json)"
  fix_merged="$(jq -r '.merged_prs' <<<"$fix_ppr")"
  if [[ "$fix_merged" -ge 1 ]]; then ok "fixture cost-per-pr sees >=1 merged PR ($fix_merged)"; else bad "fixture cost-per-pr saw 0 merged PRs"; fi
else
  bad "fixture logs/ or merged-prs.txt missing at $FIXDIR"
fi

# =============================================================================
printf "\n${C_BOLD}%d passed, %d failed${C_RESET}\n" "$passed" "$failed"
[[ "$failed" -eq 0 ]]

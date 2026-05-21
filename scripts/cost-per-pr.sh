#!/usr/bin/env bash
#
# cost-per-pr.sh — the headline efficiency metric: cost ÷ merged-PRs.
#
# Scans logs/<ticket>.json files for per-ticket cost_usd (written by
# cost-rollup.sh) and the ticket's pr_url, determines which PRs merged, and
# emits total-cost-over-merged-PRs ÷ merged-PR-count — the number the community
# settled on for proving an autonomous fleet is worth it (cost per merged PR,
# not raw spend).
#
# Merged status:
#   - Default (online): `gh pr view <pr_url> --json mergedAt` per distinct PR;
#     a PR is merged iff mergedAt != null. A lookup failure or missing `gh`
#     treats that PR as unmerged + warns on stderr (the aggregate still runs).
#   - Offline (--merged-prs <file>): a newline list of merged PR URLs. NO `gh`
#     is called. This is the deterministic path used by tests / CI.
#
# Pure bash + jq, offline-capable. Spec:
# docs/specs/2026-05-21-per-ticket-cost-and-cost-per-pr.md (ticket #195)

set -euo pipefail

LOGS_DEFAULT="${HYDRA_LOGS_DIR:-./logs}"

usage() {
  cat <<'EOF'
Usage: cost-per-pr.sh [options]

Joins per-ticket cost_usd (from logs/<ticket>.json) against merged-PR status and
reports total cost over merged PRs ÷ merged-PR count.

Options:
  --logs-dir <dir>      Logs directory (default: $HYDRA_LOGS_DIR or ./logs).
  --merged-prs <file>   Offline merged-PR list (one PR URL per line). When set,
                        `gh` is NOT called — fully deterministic. Without it,
                        merged status comes from `gh pr view <url> --json mergedAt`.
  --include-unmerged    Also report cost spent on tickets whose PR is unmerged
                        (or has no PR) as a separate line.
  --json                Emit JSON instead of human-readable lines.
  -h, --help            Show this help.

Output (JSON shape):
  {
    "total_cost_usd":      <sum of cost_usd over MERGED-PR tickets>,
    "merged_prs":          <count of distinct merged PR URLs>,
    "cost_per_merged_pr":  <total_cost_usd / merged_prs, or null if 0 merged>,
    "tickets_counted":     <number of log files read>,
    "unmerged_cost_usd":   <sum of cost_usd over unmerged/no-PR tickets>,
    "by_ticket": [ {ticket, pr_url, cost_usd, merged} ... ]
  }

Exit codes:
  0  success
  2  usage error / logs dir not found / jq missing
EOF
}

command -v jq >/dev/null 2>&1 || { echo "cost-per-pr: jq required but not found" >&2; exit 2; }

logs_dir="$LOGS_DEFAULT"
merged_file=""
include_unmerged=0
json=0

die_usage() { echo "cost-per-pr: $1" >&2; usage >&2; exit 2; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --logs-dir)        [[ $# -ge 2 ]] || die_usage "--logs-dir needs a value"; logs_dir="$2"; shift 2 ;;
    --merged-prs)      [[ $# -ge 2 ]] || die_usage "--merged-prs needs a value"; merged_file="$2"; shift 2 ;;
    --include-unmerged) include_unmerged=1; shift ;;
    --json)            json=1; shift ;;
    -h|--help)         usage; exit 0 ;;
    *)                 die_usage "unknown argument: $1" ;;
  esac
done

[[ -d "$logs_dir" ]] || die_usage "logs dir not found: $logs_dir"
if [[ -n "$merged_file" ]]; then
  [[ -f "$merged_file" ]] || die_usage "merged-prs file not found: $merged_file"
fi

# --- collect (ticket, pr_url, cost_usd) from every log file ------------------
# Read each *.json that is a valid JSON object; default cost_usd to 0 and
# pr_url to null so heterogeneous / partial logs never break the join.
records="$(
  shopt -s nullglob
  first=1
  printf '['
  for f in "$logs_dir"/*.json; do
    jq empty "$f" >/dev/null 2>&1 || continue
    obj="$(jq -c '{ticket: (.ticket // null), pr_url: (.pr_url // null), cost_usd: (.cost_usd // 0)}' "$f" 2>/dev/null)" || continue
    [[ -n "$obj" ]] || continue
    if [[ "$first" -eq 1 ]]; then first=0; else printf ','; fi
    printf '%s' "$obj"
  done
  printf ']'
)"

# --- determine merged status per record --------------------------------------
# Build a JSON array of merged PR URLs, then annotate each record with merged.
if [[ -n "$merged_file" ]]; then
  # Offline: merged set = the file's non-empty, non-comment lines. `grep -v`
  # exits 1 when nothing matches (e.g. an empty file); `|| true` keeps that
  # benign case from tripping `set -o pipefail`.
  merged_lines="$(grep -vE '^[[:space:]]*(#|$)' "$merged_file" 2>/dev/null || true)"
  merged_set="$(printf '%s' "$merged_lines" | grep -vE '^[[:space:]]*$' | jq -R . | jq -sc '.' || true)"
  [[ -n "$merged_set" ]] || merged_set='[]'
else
  # Online: query gh per distinct, non-null pr_url.
  if ! command -v gh >/dev/null 2>&1; then
    echo "cost-per-pr: gh not found; treating all PRs as unmerged (use --merged-prs for offline)" >&2
    merged_set='[]'
  else
    urls="$(jq -r '[.[].pr_url] | map(select(. != null)) | unique[]' <<<"$records")"
    merged_lines=""
    while IFS= read -r url; do
      [[ -n "$url" ]] || continue
      if mergedAt="$(gh pr view "$url" --json mergedAt --jq '.mergedAt' 2>/dev/null)"; then
        if [[ -n "$mergedAt" && "$mergedAt" != "null" ]]; then
          merged_lines+="$url"$'\n'
        fi
      else
        echo "cost-per-pr: could not resolve $url (treating as unmerged)" >&2
      fi
    done <<<"$urls"
    merged_set="$(printf '%s' "$merged_lines" | grep -vE '^[[:space:]]*$' | jq -R . | jq -sc '.' || true)"
    [[ -n "$merged_set" ]] || merged_set='[]'
  fi
fi

# --- aggregate ---------------------------------------------------------------
result="$(jq -nc \
  --argjson recs "$records" \
  --argjson merged "$merged_set" \
  '
  ($merged | map({(.): true}) | add // {}) as $mset
  | ($recs | map(. + {merged: (.pr_url != null and ($mset[.pr_url] == true))})) as $annot
  | ([$annot[] | select(.merged) | .cost_usd] | add // 0) as $merged_cost
  | ([$annot[] | select(.merged | not) | .cost_usd] | add // 0) as $unmerged_cost
  | ([$annot[] | select(.merged) | .pr_url] | unique | length) as $merged_count
  | {
      total_cost_usd: (($merged_cost * 1000000 | round) / 1000000),
      merged_prs: $merged_count,
      cost_per_merged_pr: (if $merged_count > 0
                           then ((($merged_cost / $merged_count) * 1000000 | round) / 1000000)
                           else null end),
      tickets_counted: ($annot | length),
      unmerged_cost_usd: (($unmerged_cost * 1000000 | round) / 1000000),
      by_ticket: $annot
    }
  ')"

if [[ "$json" -eq 1 ]]; then
  jq . <<<"$result"
  exit 0
fi

# Human-readable.
jq -r '
  "total cost over merged PRs:  $\((.total_cost_usd * 10000 | round) / 10000)",
  "merged PRs:                  \(.merged_prs)",
  "cost per merged PR:          \(if .cost_per_merged_pr == null then "n/a (no merged PRs)" else "$\((.cost_per_merged_pr * 10000 | round) / 10000)" end)",
  "tickets counted:             \(.tickets_counted)"
' <<<"$result"

if [[ "$include_unmerged" -eq 1 ]]; then
  jq -r '"unmerged/no-PR spend:        $\((.unmerged_cost_usd * 10000 | round) / 10000)"' <<<"$result"
fi

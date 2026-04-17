#!/usr/bin/env bash
#
# file-proposed-issues.sh — consume propose-improvements.sh output and file
# real GitHub issues via `gh issue create`, respecting:
#   - 3/week rate limit across all repos
#   - state/declined-proposals.json 90-day decline TTL
#   - state/proposed-issues.json dedup of already-filed pattern hashes
#
# Input JSON (on stdin or in a file) matches the propose-improvements.sh schema:
#   {
#     "generated_at": "<iso or fixture>",
#     "proposals": [
#       {pattern_hash, source, repo, title, body, labels, confidence, evidence_refs}, ...
#     ]
#   }
#
# Default is DRY RUN. The operator (or a commander procedure) must pass
# --execute to actually file issues. Matches the opt-in-destructive pattern
# from scripts/memory-mount.sh.
#
# Spec: docs/specs/2026-04-16-self-improvement-cycle.md

set -euo pipefail

# ---------------------------------------------------------------------------
# defaults
# ---------------------------------------------------------------------------
STATE_DIR_DEFAULT="./state"
PROPOSED_FILE_NAME="proposed-issues.json"
DECLINED_FILE_NAME="declined-proposals.json"

WEEKLY_RATE_LIMIT=3
DECLINE_TTL_DAYS=90

usage() {
  cat <<'EOF'
Usage: file-proposed-issues.sh [options] [<proposals-file>]

Consume proposals JSON (from propose-improvements.sh) and file them as GitHub
issues via `gh issue create`, enforcing rate limits + dedup.

Input:
  - If <proposals-file> is given, read from that path.
  - Else read from stdin.

Options:
  --state-dir <path>    State dir (default ./state). Reads/writes
                        proposed-issues.json and declined-proposals.json.
  --execute             Actually run `gh issue create` (default is dry-run).
  --max-per-week <N>    Override 3/week rate limit (testing / dogfood only).
  --now <iso-ts>        Override "now" for rate-limit + TTL arithmetic.
                        Useful in tests / fixtures.
  -h, --help            Show this help

Exit codes:
  0   success — may have filed 0+ proposals (rate limit / decline TTL hits
       are normal, not failures)
  1   state file corruption / gh failure
  2   usage error / malformed input
EOF
}

# ---------------------------------------------------------------------------
# arg parsing
# ---------------------------------------------------------------------------
state_dir=""
execute=0
max_per_week="$WEEKLY_RATE_LIMIT"
now_override=""
input_file=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --state-dir)
      [[ $# -ge 2 ]] || { echo "file-proposed-issues: --state-dir needs a value" >&2; exit 2; }
      state_dir="$2"; shift 2 ;;
    --state-dir=*)
      state_dir="${1#--state-dir=}"; shift ;;
    --execute)
      execute=1; shift ;;
    --max-per-week)
      [[ $# -ge 2 ]] || { echo "file-proposed-issues: --max-per-week needs a value" >&2; exit 2; }
      max_per_week="$2"; shift 2 ;;
    --max-per-week=*)
      max_per_week="${1#--max-per-week=}"; shift ;;
    --now)
      [[ $# -ge 2 ]] || { echo "file-proposed-issues: --now needs a value" >&2; exit 2; }
      now_override="$2"; shift 2 ;;
    --now=*)
      now_override="${1#--now=}"; shift ;;
    -h|--help)
      usage; exit 0 ;;
    --) shift; break ;;
    -*)
      echo "file-proposed-issues: unknown option: $1" >&2; usage >&2; exit 2 ;;
    *)
      if [[ -n "$input_file" ]]; then
        echo "file-proposed-issues: only one positional <proposals-file> argument allowed" >&2
        exit 2
      fi
      input_file="$1"; shift ;;
  esac
done

[[ -z "$state_dir" ]] && state_dir="$STATE_DIR_DEFAULT"

if ! [[ "$max_per_week" =~ ^[0-9]+$ ]] || (( max_per_week < 0 )); then
  echo "file-proposed-issues: --max-per-week must be a non-negative integer" >&2
  exit 2
fi

# ---------------------------------------------------------------------------
# read input
# ---------------------------------------------------------------------------
if [[ -n "$input_file" ]]; then
  if [[ ! -f "$input_file" ]]; then
    echo "file-proposed-issues: input file not found: $input_file" >&2
    exit 2
  fi
  proposals_json="$(cat "$input_file")"
else
  proposals_json="$(cat)"
fi

if [[ -z "$proposals_json" ]]; then
  echo "file-proposed-issues: no input received" >&2
  exit 2
fi

if ! jq empty <<<"$proposals_json" 2>/dev/null; then
  echo "file-proposed-issues: input is not valid JSON" >&2
  exit 2
fi

# ---------------------------------------------------------------------------
# resolve "now" (ISO 8601 UTC). GNU date + BSD date syntax differ; fall back
# to the provided override if the native `date -u -d` doesn't work.
# ---------------------------------------------------------------------------
now_iso=""
now_epoch=""
if [[ -n "$now_override" ]]; then
  now_iso="$now_override"
  # best-effort epoch conversion — try GNU then BSD syntax
  now_epoch="$(date -u -d "$now_override" '+%s' 2>/dev/null \
    || date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$now_override" '+%s' 2>/dev/null \
    || echo "")"
  if [[ -z "$now_epoch" ]]; then
    echo "file-proposed-issues: cannot parse --now '$now_override' (expect ISO 8601 UTC)" >&2
    exit 2
  fi
else
  now_iso="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  now_epoch="$(date -u '+%s')"
fi

# Week boundary = 7 days before now (rolling window — simpler + more honest
# than an ISO-week-start cutoff).
week_ago_epoch=$(( now_epoch - 7 * 86400 ))
ttl_ago_epoch=$(( now_epoch - DECLINE_TTL_DAYS * 86400 ))

# ---------------------------------------------------------------------------
# load / initialize state files
# ---------------------------------------------------------------------------
proposed_file="$state_dir/$PROPOSED_FILE_NAME"
declined_file="$state_dir/$DECLINED_FILE_NAME"

if [[ -f "$proposed_file" ]]; then
  if ! jq empty "$proposed_file" 2>/dev/null; then
    echo "file-proposed-issues: corrupt $proposed_file — refuse to proceed" >&2
    exit 1
  fi
  proposed_state="$(cat "$proposed_file")"
else
  proposed_state='{"filed": []}'
fi

if [[ -f "$declined_file" ]]; then
  if ! jq empty "$declined_file" 2>/dev/null; then
    echo "file-proposed-issues: corrupt $declined_file — refuse to proceed" >&2
    exit 1
  fi
  declined_state="$(cat "$declined_file")"
else
  declined_state='{"declined": []}'
fi

# ---------------------------------------------------------------------------
# rate-limit check — count filings in the last 7 days
# ---------------------------------------------------------------------------
parse_epoch() {
  local iso="$1"
  date -u -d "$iso" '+%s' 2>/dev/null \
    || date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$iso" '+%s' 2>/dev/null \
    || echo 0
}

filed_last_week=0
while IFS= read -r filed_at; do
  [[ -z "$filed_at" ]] && continue
  e="$(parse_epoch "$filed_at")"
  if (( e >= week_ago_epoch )); then
    filed_last_week=$((filed_last_week + 1))
  fi
done < <(jq -r '.filed[]?.filed_at // empty' <<<"$proposed_state")

if (( filed_last_week >= max_per_week )); then
  echo "file-proposed-issues: rate limit hit ($filed_last_week / $max_per_week per 7-day window). Refuse to file anything this run." >&2
  # Still emit a result document so callers can introspect.
  jq -n \
    --arg now "$now_iso" \
    --argjson filed_last_week "$filed_last_week" \
    --argjson max_per_week "$max_per_week" \
    '{status: "rate-limited", now: $now, filed_last_week: $filed_last_week, max_per_week: $max_per_week, filed_this_run: []}'
  exit 0
fi

# ---------------------------------------------------------------------------
# dedup vs declined + already-filed; respect rate limit per-proposal
# ---------------------------------------------------------------------------
declined_hashes="$(jq -r '.declined[]?.pattern_hash // empty' <<<"$declined_state")"
declined_until_map="$(
  jq -r '.declined[]? | select(.declined_at != null) | "\(.pattern_hash)\t\(.declined_at)"' \
    <<<"$declined_state"
)"

is_declined_active() {
  local phash="$1"
  # If the pattern has any declined entry within TTL, it's active-declined.
  local line
  while IFS=$'\t' read -r ph dat; do
    [[ "$ph" != "$phash" ]] && continue
    local dep
    dep="$(parse_epoch "$dat")"
    if (( dep >= ttl_ago_epoch )); then
      return 0
    fi
  done <<<"$declined_until_map"
  return 1
}

already_filed_hashes="$(jq -r '.filed[]?.pattern_hash // empty' <<<"$proposed_state")"

is_already_filed() {
  local phash="$1"
  while IFS= read -r ph; do
    [[ "$ph" == "$phash" ]] && return 0
  done <<<"$already_filed_hashes"
  return 1
}

# ---------------------------------------------------------------------------
# iterate proposals
# ---------------------------------------------------------------------------
n_proposals="$(jq -r '(.proposals // []) | length' <<<"$proposals_json")"
filed_this_run_json="[]"
budget_remaining=$(( max_per_week - filed_last_week ))

i=0
while (( i < n_proposals )); do
  prop="$(jq -c ".proposals[$i]" <<<"$proposals_json")"
  phash="$(jq -r '.pattern_hash' <<<"$prop")"
  repo="$(jq -r '.repo' <<<"$prop")"
  title="$(jq -r '.title' <<<"$prop")"
  body="$(jq -r '.body' <<<"$prop")"
  # labels array -> comma-separated
  labels_csv="$(jq -r '(.labels // ["commander-proposed"]) | join(",")' <<<"$prop")"

  if (( budget_remaining <= 0 )); then
    echo "file-proposed-issues: rate limit exhausted after $i proposals; stopping." >&2
    break
  fi

  if is_declined_active "$phash"; then
    echo "file-proposed-issues: skip $phash — declined within $DECLINE_TTL_DAYS days" >&2
    i=$((i + 1))
    continue
  fi
  if is_already_filed "$phash"; then
    echo "file-proposed-issues: skip $phash — already filed previously" >&2
    i=$((i + 1))
    continue
  fi

  if (( execute == 1 )); then
    # Real gh call.
    issue_url="$(gh issue create \
      --repo "$repo" \
      --title "$title" \
      --body "$body" \
      --label "$labels_csv" \
      --assignee "@me" 2>&1)" || {
        echo "file-proposed-issues: gh issue create failed for $phash — aborting remaining filings to avoid partial state" >&2
        exit 1
      }
    # Append one entry to proposed_state, persist immediately (safe against mid-batch failure).
    proposed_state="$(jq \
      --arg phash "$phash" \
      --arg url "$issue_url" \
      --arg filed_at "$now_iso" \
      --arg repo "$repo" \
      --arg title "$title" \
      '.filed += [{pattern_hash: $phash, issue_url: $url, filed_at: $filed_at, repo: $repo, title: $title}]' \
      <<<"$proposed_state")"
    mkdir -p "$state_dir"
    printf '%s\n' "$proposed_state" > "$proposed_file.new"
    mv "$proposed_file.new" "$proposed_file"

    filed_this_run_json="$(jq \
      --arg phash "$phash" \
      --arg url "$issue_url" \
      --arg repo "$repo" \
      --arg title "$title" \
      '. += [{pattern_hash: $phash, issue_url: $url, repo: $repo, title: $title}]' \
      <<<"$filed_this_run_json")"
  else
    # Dry run. Log to stderr so stdout stays clean JSON for pipelines.
    echo "DRY-RUN: would file: repo=$repo title=\"$title\" labels=$labels_csv pattern_hash=$phash" >&2
    filed_this_run_json="$(jq \
      --arg phash "$phash" \
      --arg repo "$repo" \
      --arg title "$title" \
      '. += [{pattern_hash: $phash, repo: $repo, title: $title, dry_run: true}]' \
      <<<"$filed_this_run_json")"
  fi

  budget_remaining=$(( budget_remaining - 1 ))
  i=$((i + 1))
done

# ---------------------------------------------------------------------------
# emit result summary
# ---------------------------------------------------------------------------
status="ok"
(( execute == 1 )) || status="dry-run"

jq -n \
  --arg status "$status" \
  --arg now "$now_iso" \
  --argjson filed_last_week "$filed_last_week" \
  --argjson max_per_week "$max_per_week" \
  --argjson filed_this_run "$filed_this_run_json" \
  '{
    status: $status,
    now: $now,
    filed_last_week: $filed_last_week,
    max_per_week: $max_per_week,
    filed_this_run: $filed_this_run
  }'

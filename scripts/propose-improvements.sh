#!/usr/bin/env bash
#
# propose-improvements.sh — detect patterns in logs/retros/memory and emit
# structured self-improvement proposal JSON.
#
# Reads (each optional, each with a flag to override the default path):
#   --logs-dir <path>     (default $HYDRA_LOGS_DIR, fallback ./logs)
#   --citations <path>    (default ./state/memory-citations.json)
#   --faq <path>          (default $HYDRA_EXTERNAL_MEMORY_DIR/escalation-faq.md
#                          fallback ./memory/escalation-faq.md)
#   --retros <path>       (default $HYDRA_EXTERNAL_MEMORY_DIR/retros
#                          fallback ./memory/retros)
#   --window-days <N>     (default 30; windows the log-based rules)
#   --fixture             (fixture mode — deterministic output, no wall-clock
#                          timestamp, treats --logs-dir etc. as if the data is
#                          self-contained)
#   --repo <owner/name>   (default tonychang04/hydra — the repo proposals target
#                          when not specified per-rule)
#
# Writes a JSON document to stdout:
#   {
#     "generated_at": "<iso ts or 'fixture'>",
#     "proposals": [ {pattern_hash, source, repo, title, body, labels,
#                     confidence, evidence_refs}, ... ]
#   }
#
# Does NOT call gh. Does NOT write anywhere. Stateless.
#
# Spec: docs/specs/2026-04-16-self-improvement-cycle.md
# Commander wiring: CLAUDE.md "Self-improvement proposals"

set -euo pipefail

# ---------------------------------------------------------------------------
# defaults
# ---------------------------------------------------------------------------
LOGS_DIR_DEFAULT="${HYDRA_LOGS_DIR:-./logs}"
CITATIONS_DEFAULT="./state/memory-citations.json"
FAQ_DEFAULT="${HYDRA_EXTERNAL_MEMORY_DIR:-./memory}/escalation-faq.md"
RETROS_DEFAULT="${HYDRA_EXTERNAL_MEMORY_DIR:-./memory}/retros"

# Threshold constants (matches memory promotion rule + CLAUDE.md policy)
STUCK_OCCURRENCE_THRESHOLD=3
STUCK_DISTINCT_TICKETS_THRESHOLD=2
CITATION_HOT_THRESHOLD=5
FAQ_THEME_THRESHOLD=3

usage() {
  cat <<'EOF'
Usage: propose-improvements.sh [options]

Scans logs/retros/memory for patterns that warrant a new self-improvement
issue, emits proposal JSON on stdout. Does NOT file anything — pipe into
scripts/file-proposed-issues.sh for that.

Options:
  --logs-dir <path>     Override logs dir (default: $HYDRA_LOGS_DIR or ./logs)
  --citations <path>    Override citations JSON (default ./state/memory-citations.json)
  --faq <path>          Override escalation-faq.md path
                        (default: $HYDRA_EXTERNAL_MEMORY_DIR/escalation-faq.md or
                         ./memory/escalation-faq.md)
  --retros <path>       Override retros dir
                        (default: $HYDRA_EXTERNAL_MEMORY_DIR/retros or ./memory/retros)
  --window-days <N>     Rolling window for log-based rules (default 30)
  --fixture             Deterministic output (no wall-clock in generated_at;
                         produces identical JSON for identical inputs, so the
                         self-test can diff bit-for-bit)
  --repo <owner/name>   Default repo to target with proposals (default
                         tonychang04/hydra)
  -h, --help            Show this help

Exit codes:
  0   success (may emit empty proposals array if nothing tripped a threshold)
  2   usage error / malformed input
EOF
}

# ---------------------------------------------------------------------------
# arg parsing
# ---------------------------------------------------------------------------
logs_dir=""
citations=""
faq=""
retros=""
window_days=30
fixture=0
default_repo="tonychang04/hydra"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --logs-dir)
      [[ $# -ge 2 ]] || { echo "propose-improvements: --logs-dir needs a value" >&2; exit 2; }
      logs_dir="$2"; shift 2 ;;
    --logs-dir=*)
      logs_dir="${1#--logs-dir=}"; shift ;;
    --citations)
      [[ $# -ge 2 ]] || { echo "propose-improvements: --citations needs a value" >&2; exit 2; }
      citations="$2"; shift 2 ;;
    --citations=*)
      citations="${1#--citations=}"; shift ;;
    --faq)
      [[ $# -ge 2 ]] || { echo "propose-improvements: --faq needs a value" >&2; exit 2; }
      faq="$2"; shift 2 ;;
    --faq=*)
      faq="${1#--faq=}"; shift ;;
    --retros)
      [[ $# -ge 2 ]] || { echo "propose-improvements: --retros needs a value" >&2; exit 2; }
      retros="$2"; shift 2 ;;
    --retros=*)
      retros="${1#--retros=}"; shift ;;
    --window-days)
      [[ $# -ge 2 ]] || { echo "propose-improvements: --window-days needs a value" >&2; exit 2; }
      window_days="$2"; shift 2 ;;
    --window-days=*)
      window_days="${1#--window-days=}"; shift ;;
    --fixture)
      fixture=1; shift ;;
    --repo)
      [[ $# -ge 2 ]] || { echo "propose-improvements: --repo needs a value" >&2; exit 2; }
      default_repo="$2"; shift 2 ;;
    --repo=*)
      default_repo="${1#--repo=}"; shift ;;
    -h|--help)
      usage; exit 0 ;;
    --) shift; break ;;
    -*)
      echo "propose-improvements: unknown option: $1" >&2; usage >&2; exit 2 ;;
    *)
      echo "propose-improvements: unexpected positional argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

[[ -z "$logs_dir" ]]  && logs_dir="$LOGS_DIR_DEFAULT"
[[ -z "$citations" ]] && citations="$CITATIONS_DEFAULT"
[[ -z "$faq" ]]       && faq="$FAQ_DEFAULT"
[[ -z "$retros" ]]    && retros="$RETROS_DEFAULT"

if ! [[ "$window_days" =~ ^[0-9]+$ ]] || (( window_days < 1 )); then
  echo "propose-improvements: --window-days must be a positive integer" >&2
  exit 2
fi

# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------
# pattern_hash: stable SHA1 over source|repo|normalized_title.
# Normalization strips digits, whitespace-runs, and common variable tokens so
# that a proposal for "3 stuck runs on repo/42" hashes the same as one for
# "5 stuck runs on repo/53" if they target the same repo+source.
pattern_hash() {
  local source="$1" repo="$2" title="$3"
  local normalized
  normalized="$(printf '%s' "$title" \
    | tr '[:upper:]' '[:lower:]' \
    | sed -E 's/[0-9]+//g; s/#+//g; s/[[:space:]]+/ /g; s/^[[:space:]]+|[[:space:]]+$//g')"
  printf '%s|%s|%s' "$source" "$repo" "$normalized" \
    | shasum -a 1 \
    | awk '{print $1}'
}

generated_at() {
  if (( fixture == 1 )); then
    printf 'fixture'
  else
    date -u '+%Y-%m-%dT%H:%M:%SZ'
  fi
}

# Emit a single proposal JSON object to stdout (one line, for jq to absorb).
emit_proposal() {
  local source="$1" repo="$2" title="$3" body="$4" confidence="$5"
  shift 5
  local evidence_refs_json="$1"

  local phash
  phash="$(pattern_hash "$source" "$repo" "$title")"

  jq -n \
    --arg phash "$phash" \
    --arg source "$source" \
    --arg repo "$repo" \
    --arg title "$title" \
    --arg body "$body" \
    --arg confidence "$confidence" \
    --argjson evidence_refs "$evidence_refs_json" \
    '{
      pattern_hash: $phash,
      source: $source,
      repo: $repo,
      title: $title,
      body: $body,
      labels: ["commander-proposed"],
      confidence: $confidence,
      evidence_refs: $evidence_refs
    }'
}

# ---------------------------------------------------------------------------
# rule 1: stuck-pattern detection from logs/
# ---------------------------------------------------------------------------
# A log file is considered "stuck" if its top-level JSON has
# result == "stuck" and optionally stuck_pattern + repo. We group by
# (repo, stuck_pattern) and fire when count >= STUCK_OCCURRENCE_THRESHOLD and
# distinct tickets >= STUCK_DISTINCT_TICKETS_THRESHOLD.
rule_logs_stuck() {
  [[ -d "$logs_dir" ]] || return 0

  local logs_json
  logs_json="$(
    find "$logs_dir" -maxdepth 1 -type f -name '*.json' 2>/dev/null \
      | sort \
      | while IFS= read -r f; do
          # tolerant: skip invalid JSON
          jq -c '. + {_log_file: input_filename}' "$f" 2>/dev/null || true
        done \
      | jq -s '.'
  )"

  if [[ -z "$logs_json" ]] || [[ "$logs_json" == "null" ]]; then
    return 0
  fi

  # Group stuck entries by (repo, stuck_pattern). Emit aggregates that clear
  # both thresholds.
  local aggregates_json
  aggregates_json="$(
    jq --argjson occ "$STUCK_OCCURRENCE_THRESHOLD" \
       --argjson distinct "$STUCK_DISTINCT_TICKETS_THRESHOLD" \
       '
       map(select(.result == "stuck"))
       | map(select((.stuck_pattern // "") != "" and (.repo // "") != ""))
       | group_by([.repo, .stuck_pattern])
       | map({
           repo: .[0].repo,
           stuck_pattern: .[0].stuck_pattern,
           occurrences: length,
           distinct_tickets: (map(.ticket // "unknown") | unique | length),
           evidence_refs: (map(._log_file) | map(sub("^.*/"; "")))
         })
       | map(select(.occurrences >= $occ and .distinct_tickets >= $distinct))
       ' <<<"$logs_json"
  )"

  local n_groups
  n_groups="$(jq -r 'length' <<<"$aggregates_json")"
  (( n_groups == 0 )) && return 0

  local i=0
  while (( i < n_groups )); do
    local repo stuck_pattern occurrences distinct_tickets evidence_refs_json title body
    repo="$(jq -r ".[$i].repo" <<<"$aggregates_json")"
    stuck_pattern="$(jq -r ".[$i].stuck_pattern" <<<"$aggregates_json")"
    occurrences="$(jq -r ".[$i].occurrences" <<<"$aggregates_json")"
    distinct_tickets="$(jq -r ".[$i].distinct_tickets" <<<"$aggregates_json")"
    evidence_refs_json="$(jq -c ".[$i].evidence_refs" <<<"$aggregates_json")"

    title="[auto-proposed] Fix root cause of \"$stuck_pattern\" in $repo"
    body="$(cat <<BODY
## Summary

Commander detected the same stuck pattern on \`$repo\` $occurrences times across $distinct_tickets distinct tickets. Workers keep hitting the same wall; fix the root cause so the next worker doesn't.

## Evidence

- Pattern: \`$stuck_pattern\`
- Occurrences: $occurrences (threshold: $STUCK_OCCURRENCE_THRESHOLD)
- Distinct tickets: $distinct_tickets (threshold: $STUCK_DISTINCT_TICKETS_THRESHOLD)
- Source logs: see \`evidence_refs\` in the proposal JSON

## Suggested tier

T2 — new change addressing a repo-specific repeat failure. Commander review gate applies.

## Notes for the worker head

- Read the evidence logs before planning. The pattern string is the literal signal; the fix should address whatever the workers actually hit.
- If the fix is a new skill or doc rather than code, that's fine — the bar is "next worker doesn't hit this," not "code must change."
- If in doubt, escalate.
BODY
)"

    emit_proposal "logs-stuck" "$repo" "$title" "$body" "high" "$evidence_refs_json"
    i=$((i + 1))
  done
}

# ---------------------------------------------------------------------------
# rule 2: memory citation promotion candidates
# ---------------------------------------------------------------------------
# Any entry with count >= CITATION_HOT_THRESHOLD gets a promotion proposal.
# Skips entries that are already marked promotion_threshold_reached AND have
# count < threshold (defensive — shouldn't happen but keeps the rule pure).
rule_citations_hot() {
  [[ -f "$citations" ]] || return 0

  # Tolerant: skip malformed citations files, don't fail the whole run.
  if ! jq empty "$citations" 2>/dev/null; then
    echo "propose-improvements: warning: citations file not valid JSON, skipping: $citations" >&2
    return 0
  fi

  local hot_json
  hot_json="$(
    jq --argjson thresh "$CITATION_HOT_THRESHOLD" \
       '
       (.citations // {})
       | to_entries
       | map(select(.value.count >= $thresh))
       | sort_by(-.value.count)
       ' "$citations"
  )"

  local n
  n="$(jq -r 'length' <<<"$hot_json")"
  (( n == 0 )) && return 0

  local i=0
  while (( i < n )); do
    local key count tickets_json last_cited title body source_file
    key="$(jq -r ".[$i].key" <<<"$hot_json")"
    count="$(jq -r ".[$i].value.count" <<<"$hot_json")"
    tickets_json="$(jq -c ".[$i].value.tickets // []" <<<"$hot_json")"
    last_cited="$(jq -r ".[$i].value.last_cited // \"unknown\"" <<<"$hot_json")"
    source_file="${key%%#*}"

    title="[auto-proposed] Promote memory entry \"$key\" to repo skill"
    body="$(cat <<BODY
## Summary

Memory entry \`$key\` has been cited $count times (threshold: $CITATION_HOT_THRESHOLD). It is a promotion candidate — move it from commander memory to the target repo's \`.claude/skills/\` so every agent inherits it, not just commander workers.

## Evidence

- Key: \`$key\`
- Cited count: $count
- Last cited: $last_cited
- Tickets: see \`evidence_refs\` in the proposal JSON
- Source file: \`$source_file\`

## Suggested tier

T1 — documentation / skill promotion. Clean flow once the target repo is known.

## Notes for the worker head

See \`memory/memory-lifecycle.md\` "Promotion flow (memory → repo skill)" for the mechanics. The skill file goes in the target repo's \`.claude/skills/\`; once that PR merges, commander removes the entry from \`learnings-<repo>.md\` with a trailing back-link.
BODY
)"

    emit_proposal "citations-hot" "$default_repo" "$title" "$body" "high" "$tickets_json"
    i=$((i + 1))
  done
}

# ---------------------------------------------------------------------------
# rule 3: recurring FAQ themes
# ---------------------------------------------------------------------------
# Simple grep-by-topic: count third-level headings (### ) per keyword bucket.
# Thresholds fire on FAQ_THEME_THRESHOLD occurrences. Keyword buckets are
# intentionally narrow — missing a theme is fine; inventing one is not.
rule_faq_themes() {
  [[ -f "$faq" ]] || return 0

  # Count per keyword bucket. Each bucket is a grep pattern; the FAQ section
  # headings (level 3) get matched for the keyword.
  local buckets=(
    "lockfile:lockfile|package-lock|peer marker"
    "test-procedure:test procedure|test command|test runner"
    "linear-mcp:linear mcp|linear_"
    "tier-classification:tier|T[123]|reclassify"
  )

  local faq_headings
  faq_headings="$(grep -E '^### ' "$faq" || true)"
  [[ -z "$faq_headings" ]] && return 0

  for b in "${buckets[@]}"; do
    local bname bpat count
    bname="${b%%:*}"
    bpat="${b#*:}"
    count="$(grep -Eic "$bpat" <<<"$faq_headings" || true)"
    [[ -z "$count" ]] && count=0

    if (( count >= FAQ_THEME_THRESHOLD )); then
      local title body refs_json
      title="[auto-proposed] Add repo-native skill for \"$bname\" pattern"
      body="$(cat <<BODY
## Summary

The escalation FAQ has $count entries matching the \`$bname\` theme. That's signal that workers keep asking the same class of question — the right fix is a repo-native skill so the next worker doesn't escalate.

## Evidence

- Theme: \`$bname\`
- Matching FAQ headings: $count (threshold: $FAQ_THEME_THRESHOLD)
- Source: \`$faq\`
- Match pattern: \`$bpat\`

## Suggested tier

T1 — documentation addition. Worker reads the FAQ section, distills to a skill, opens PR on the target repo.

## Notes for the worker head

Match the existing \`.claude/skills/\` convention in whichever target repo — if it uses frontmatter, follow that; if plain markdown, follow that. The skill body should compress the FAQ answers into a "what to do" list, not a "what happened" transcript.
BODY
)"
      refs_json="$(jq -nc --arg faq "$faq" --arg pat "$bpat" '[$faq, "pattern:" + $pat]')"
      emit_proposal "faq-theme" "$default_repo" "$title" "$body" "medium" "$refs_json"
    fi
  done
}

# ---------------------------------------------------------------------------
# rule 4: recurring patterns across retros
# ---------------------------------------------------------------------------
# If the same stuck-pattern keyword shows up in the "## Stuck" section of two
# or more retros, that's a cross-week trend — propose investigating.
# Heuristic: bucket by first line word tokens, threshold on 2+ retros with the
# same word. Deliberately loose — the operator still decides whether to file.
rule_retros_recurring() {
  [[ -d "$retros" ]] || return 0

  local retro_files
  retro_files=()
  while IFS= read -r f; do
    retro_files+=("$f")
  done < <(find "$retros" -maxdepth 1 -type f -name '*.md' 2>/dev/null | sort)

  (( ${#retro_files[@]} < 2 )) && return 0

  # Extract "## Stuck" bullet lines per retro; collect words of length >= 6
  # (heuristic: topical tokens).
  declare -a per_retro_tokens_list=()
  local idx=0
  for f in "${retro_files[@]}"; do
    local stuck_section tokens
    stuck_section="$(awk '
      /^## Stuck/ {in_stuck=1; next}
      /^## / && in_stuck {in_stuck=0}
      in_stuck {print}
    ' "$f")"
    tokens="$(printf '%s' "$stuck_section" \
      | tr '[:upper:]' '[:lower:]' \
      | tr -c 'a-z0-9_-' '\n' \
      | awk 'length($0) >= 6' \
      | sort -u)"
    per_retro_tokens_list[idx]="$tokens"
    idx=$((idx + 1))
  done

  # For each token, count across retros. threshold = 2.
  local all_tokens
  all_tokens="$(printf '%s\n' "${per_retro_tokens_list[@]}" | sort -u | awk 'NF>0')"
  [[ -z "$all_tokens" ]] && return 0

  while IFS= read -r tok; do
    [[ -z "$tok" ]] && continue
    local occurrences=0
    for t in "${per_retro_tokens_list[@]}"; do
      if grep -qxF "$tok" <<<"$t"; then
        occurrences=$((occurrences + 1))
      fi
    done
    if (( occurrences >= 2 )); then
      local title body refs_json
      title="[auto-proposed] Investigate recurring retro pattern: \"$tok\""
      body="$(cat <<BODY
## Summary

The word \`$tok\` shows up in the \`## Stuck\` section of $occurrences or more retros. That's a pattern persisting across weeks — either the mitigation proposed previously didn't stick, or it was never acted on.

## Evidence

- Token: \`$tok\`
- Retros containing it: $occurrences (threshold: 2)
- Source retros: see \`evidence_refs\` in the proposal JSON

## Suggested tier

T2 — investigation. Worker reads the retros, identifies whether the earlier mitigation shipped, decides on a concrete fix.

## Notes for the worker head

The token was extracted mechanically (length >= 6, from \`## Stuck\` bullets). Some hits will be noise. Your first task is to confirm whether the keyword actually names a real pattern before proposing a fix.
BODY
)"
      refs_json="$(printf '%s\n' "${retro_files[@]}" | jq -R . | jq -s 'map(sub("^.*/"; ""))')"
      emit_proposal "retro-recurring" "$default_repo" "$title" "$body" "low" "$refs_json"
    fi
  done <<<"$all_tokens"
}

# ---------------------------------------------------------------------------
# run all rules, collect proposals, emit final JSON document
# ---------------------------------------------------------------------------
proposals_raw="$(
  {
    rule_logs_stuck
    rule_citations_hot
    rule_faq_themes
    rule_retros_recurring
  } | jq -s '.'
)"

gen_at="$(generated_at)"

jq -n \
  --arg generated_at "$gen_at" \
  --argjson proposals "$proposals_raw" \
  '{
    generated_at: $generated_at,
    proposals: $proposals
  }'

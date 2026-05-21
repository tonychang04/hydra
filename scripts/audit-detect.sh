#!/usr/bin/env bash
#
# audit-detect.sh — deterministic drift-detection engine for worker-auditor.
#
# The worker-auditor subagent (.claude/agents/worker-auditor.md) is a read-only
# drift scanner whose only write action is `gh issue create`. Until now its
# detection was free-form prose ("look for schedule-claims-without-schedulers,
# etc."), which is hard to test and prone to false positives. This script moves
# the LOW-false-positive, mechanically-checkable rules into deterministic bash
# so they can be unit-tested with positive + negative fixtures and re-run
# idempotently on the Monday autopickup tick.
#
# It DOES NOT file issues. It DOES NOT modify any file. It emits a JSON array of
# candidate findings to stdout; the auditor (or a caller) dedups against open
# issues, applies the ≤3 cap, renders docs/templates/auto-filed-issue.md, and
# files via `gh issue create`. Keeping detection (this script) separate from
# filing (the agent) keeps the agent's write surface tiny and the rules testable.
#
# Each finding object has the shape:
#   {
#     "rule":     "<stable-rule-id>",       # one of the RULE_* ids below
#     "title":    "<drift-shape>: <phrase>", # proposed issue title (dedup key)
#     "tier":     "T1" | "T2",               # auto-tier per policy.md
#     "evidence": "<grep-able one-liner>",   # file:line + verbatim excerpt
#     "marker":   "<idempotency marker>"     # stable substring for title-dedup
#   }
#
# Rules (deliberately conservative — a finding fires ONLY on unambiguous drift):
#
#   RULE_claude_md_ceiling   CLAUDE.md is at/over the WARN band (>= 95% of the
#                            ceiling) per scripts/check-claude-md-size.sh. T1.
#                            Reuses the graduated guard from ticket #176 so the
#                            two stay in lockstep; never fires below WARN.
#
#   RULE_promotion_stale     scripts/promote-citations.sh has not run in >= 7
#                            days (state/autopickup.json:last_promotion_run)
#                            AND at least one citation entry has
#                            promotion_threshold_reached=true. T2. Fires only
#                            when there is concrete promotable work being
#                            starved — never on an empty/healthy citation file.
#
#   RULE_worker_stalled      A state/active.json worker with status "running",
#                            started_at older than the watchdog threshold
#                            (default 12 min, per the worker-timeout-watchdog
#                            spec), and NO logs/<ticket>.json completion log.
#                            T2. Mirrors the watchdog's own detection predicate
#                            so the auditor only surfaces what the watchdog also
#                            considers a rescue candidate.
#
#   RULE_broken_spec_pointer A docs/specs/<file>.md path referenced by CLAUDE.md
#                            that does not exist on disk (a dangling one-line
#                            spec pointer). T1. Pointers are the load-bearing
#                            index of the "thin CLAUDE.md" design — a broken one
#                            is unambiguous docs drift.
#
# Usage:
#   audit-detect.sh [options]
#
# Options:
#   --root <path>          repo root to scan (default: the script's repo root)
#   --now <ISO8601>        override "now" for deterministic tests
#                          (e.g. 2026-05-21T09:00:00). Default: current time.
#   --stale-days <N>       promotion-staleness window in days (default: 7)
#   --watchdog-min <N>     worker-stall threshold in minutes (default: 12)
#   --claude-warn-pct <N>  CLAUDE.md band floor that trips the rule (default: 95)
#   --only <rule-id>       run only one rule (for tests). Repeatable.
#   -h, --help             show this help
#
# Exit codes:
#   0  ran successfully (zero or more findings emitted; empty-list is success)
#   2  usage error / unreadable input
#
# Specs: docs/specs/2026-04-17-worker-auditor-subagent.md (detection rules + Monday hook),
#        docs/specs/2026-04-17-claudemd-size-guard.md,
#        docs/specs/2026-05-20-claudemd-size-graduated-bands.md,
#        docs/specs/2026-04-16-worker-timeout-watchdog.md,
#        docs/specs/2026-04-17-skill-promotion-automation.md

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"

usage() { sed -n '56,72p' "$0" | sed 's/^# \{0,1\}//'; }

root=""
now_override=""
stale_days=7
watchdog_min=12
claude_warn_pct=95
declare -a only_rules=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --root)            [[ $# -ge 2 ]] || { echo "audit-detect: --root needs a value" >&2; exit 2; }; root="$2"; shift 2 ;;
    --root=*)          root="${1#--root=}"; shift ;;
    --now)             [[ $# -ge 2 ]] || { echo "audit-detect: --now needs a value" >&2; exit 2; }; now_override="$2"; shift 2 ;;
    --now=*)           now_override="${1#--now=}"; shift ;;
    --stale-days)      [[ $# -ge 2 ]] || { echo "audit-detect: --stale-days needs a value" >&2; exit 2; }; stale_days="$2"; shift 2 ;;
    --stale-days=*)    stale_days="${1#--stale-days=}"; shift ;;
    --watchdog-min)    [[ $# -ge 2 ]] || { echo "audit-detect: --watchdog-min needs a value" >&2; exit 2; }; watchdog_min="$2"; shift 2 ;;
    --watchdog-min=*)  watchdog_min="${1#--watchdog-min=}"; shift ;;
    --claude-warn-pct) [[ $# -ge 2 ]] || { echo "audit-detect: --claude-warn-pct needs a value" >&2; exit 2; }; claude_warn_pct="$2"; shift 2 ;;
    --claude-warn-pct=*) claude_warn_pct="${1#--claude-warn-pct=}"; shift ;;
    --only)            [[ $# -ge 2 ]] || { echo "audit-detect: --only needs a value" >&2; exit 2; }; only_rules+=("$2"); shift 2 ;;
    --only=*)          only_rules+=("${1#--only=}"); shift ;;
    -h|--help)         usage; exit 0 ;;
    --)                shift; break ;;
    -*)                echo "audit-detect: unknown option: $1" >&2; usage >&2; exit 2 ;;
    *)                 echo "audit-detect: no positional args accepted: $1" >&2; exit 2 ;;
  esac
done

[[ -z "$root" ]] && root="$DEFAULT_ROOT"

for n in "$stale_days" "$watchdog_min" "$claude_warn_pct"; do
  [[ "$n" =~ ^[0-9]+$ ]] || { echo "audit-detect: numeric option got non-integer: $n" >&2; exit 2; }
done

if [[ ! -d "$root" ]]; then
  echo "audit-detect: --root is not a directory: $root" >&2
  exit 2
fi

command -v jq >/dev/null 2>&1 || { echo "audit-detect: jq is required" >&2; exit 2; }

# Should this rule run? (no --only filter ⇒ all rules run)
rule_enabled() {
  local id="$1"
  [[ ${#only_rules[@]} -eq 0 ]] && return 0
  local r
  for r in "${only_rules[@]}"; do [[ "$r" == "$id" ]] && return 0; done
  return 1
}

# Epoch seconds for "now" (override-aware). Cross-platform (GNU + BSD date).
now_epoch() {
  if [[ -n "$now_override" ]]; then
    iso_to_epoch "$now_override"
  else
    date -u +%s
  fi
}

# ISO-8601 (e.g. 2026-05-21T09:00:00 or ...Z) → epoch seconds. Tolerant of a
# trailing Z and of a missing seconds field. Returns empty on parse failure.
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

# Collect findings as JSON objects, one per line, into this temp file.
findings_file="$(mktemp)"
trap 'rm -f "$findings_file"' EXIT

emit_finding() {
  # args: rule title tier evidence marker
  jq -cn \
    --arg rule "$1" --arg title "$2" --arg tier "$3" \
    --arg evidence "$4" --arg marker "$5" \
    '{rule:$rule, title:$title, tier:$tier, evidence:$evidence, marker:$marker}' \
    >> "$findings_file"
}

# -----------------------------------------------------------------------------
# RULE_claude_md_ceiling — CLAUDE.md at/over the WARN band.
# -----------------------------------------------------------------------------
rule_claude_md_ceiling() {
  local claude_md="$root/CLAUDE.md"
  local checker="$root/scripts/check-claude-md-size.sh"
  [[ -f "$claude_md" ]] || return 0
  [[ -f "$checker" ]] || return 0

  # Drive the existing guard in --quiet mode so the band classification stays
  # in lockstep with preflight. We FORCE the WARN floor to --claude-warn-pct so
  # the rule fires exactly when the file enters WARN/FAIL. --quiet prints a
  # "CLAUDE.md: ..." line at WARN/FAIL and is silent at OK/NOTICE.
  local out ec
  # Collapse the NOTICE band into the WARN floor (NOTICE_PCT == WARN_PCT) so
  # --quiet stays silent until the file actually reaches --claude-warn-pct.
  # Without this the default NOTICE_PCT=85 would make --quiet print a NOTICE
  # line at 85-95%, which we must NOT treat as drift (false positive).
  set +e
  out="$(HYDRA_CLAUDEMD_NOTICE_PCT="$claude_warn_pct" \
        HYDRA_CLAUDEMD_WARN_PCT="$claude_warn_pct" NO_COLOR=1 \
        bash "$checker" --path "$claude_md" --quiet 2>&1)"
  ec=$?
  set -e

  # Silent (no output) ⇒ OK/NOTICE band ⇒ no drift. Output ⇒ WARN or FAIL.
  [[ -z "$out" ]] && return 0

  local band="WARN"
  [[ "$ec" -eq 1 ]] && band="FAIL"
  local one_line
  one_line="$(printf '%s' "$out" | head -n1)"

  emit_finding \
    "claude-md-ceiling" \
    "claude-md size near ceiling: CLAUDE.md in $band band (>= ${claude_warn_pct}%)" \
    "T1" \
    "CLAUDE.md: $one_line (via scripts/check-claude-md-size.sh --quiet)" \
    "CLAUDE.md in $band band"
}

# -----------------------------------------------------------------------------
# RULE_promotion_stale — promote-citations.sh starved while work is ready.
# -----------------------------------------------------------------------------
rule_promotion_stale() {
  local autopickup="$root/state/autopickup.json"
  local citations="$root/state/memory-citations.json"
  # No autopickup state OR no citations file ⇒ nothing to assert. Conservative.
  [[ -f "$autopickup" ]] || return 0
  [[ -f "$citations" ]] || return 0

  # Promotion-ready work present? (count>=3 AND distinct tickets>=3, OR an
  # explicit promotion_threshold_reached flag). If none, never fire.
  local ready
  ready="$(jq -r '
    [ (.citations // {}) | to_entries[]
      | select((.key | startswith("_")) | not)
      | select(
          (.value.promotion_threshold_reached == true)
          or ((.value.count // 0) >= 3
              and ((.value.tickets // []) | unique | length) >= 3)
        )
    ] | length
  ' "$citations" 2>/dev/null || echo 0)"
  [[ "$ready" =~ ^[0-9]+$ ]] || ready=0
  [[ "$ready" -gt 0 ]] || return 0

  local last_promotion now_e last_e age_days
  last_promotion="$(jq -r '.last_promotion_run // empty' "$autopickup" 2>/dev/null || true)"
  now_e="$(now_epoch)"
  [[ -z "$now_e" ]] && return 0

  if [[ -z "$last_promotion" ]]; then
    # Never run, but promotable work exists ⇒ stale by definition.
    age_days=">= never"
  else
    last_e="$(iso_to_epoch "$last_promotion")"
    [[ -z "$last_e" ]] && return 0
    local age_secs=$(( now_e - last_e ))
    [[ "$age_secs" -lt $(( stale_days * 86400 )) ]] && return 0
    age_days="$(( age_secs / 86400 ))"
  fi

  emit_finding \
    "promotion-stale" \
    "promotion pipeline stale: $ready promotion-ready citation(s), last run $age_days day(s) ago" \
    "T2" \
    "state/autopickup.json:last_promotion_run='${last_promotion:-null}' is >= ${stale_days}d old; state/memory-citations.json has $ready promotion_threshold_reached entr(ies)" \
    "promotion pipeline stale"
}

# -----------------------------------------------------------------------------
# RULE_worker_stalled — running worker past the watchdog threshold, no log.
# -----------------------------------------------------------------------------
rule_worker_stalled() {
  local active="$root/state/active.json"
  [[ -f "$active" ]] || return 0

  local now_e
  now_e="$(now_epoch)"
  [[ -z "$now_e" ]] && return 0
  local threshold_secs=$(( watchdog_min * 60 ))

  # Emit TSV: id \t ticket \t started_at for status==running workers.
  local rows
  rows="$(jq -r '
    (.workers // [])[]
    | select(.status == "running")
    | [(.id // ""), (.ticket // ""), (.started_at // "")]
    | @tsv
  ' "$active" 2>/dev/null || true)"
  [[ -z "$rows" ]] && return 0

  local wid ticket started started_e age_secs age_min log_basename log_path
  while IFS=$'\t' read -r wid ticket started; do
    [[ -z "$started" ]] && continue
    started_e="$(iso_to_epoch "$started")"
    [[ -z "$started_e" ]] && continue
    age_secs=$(( now_e - started_e ))
    [[ "$age_secs" -lt "$threshold_secs" ]] && continue

    # A completion log clears the candidate (mirror the watchdog predicate).
    # logs/<ticket>.json — ticket may be "owner/repo#42" or "#42"; the log file
    # is keyed on the trailing issue number when present, else the raw ticket.
    log_basename="$(printf '%s' "$ticket" | sed -E 's#.*[#/]##')"
    log_path="$root/logs/${log_basename}.json"
    [[ -f "$log_path" ]] && continue
    # Also accept logs/<raw-ticket>.json (back-compat with raw keys).
    [[ -f "$root/logs/${ticket}.json" ]] && continue

    age_min=$(( age_secs / 60 ))
    emit_finding \
      "worker-stalled" \
      "stalled worker: ${wid} on ${ticket} running ${age_min}m with no completion log" \
      "T2" \
      "state/active.json worker id='${wid}' ticket='${ticket}' status=running started_at='${started}' age=${age_min}m (> ${watchdog_min}m watchdog); no logs/${log_basename}.json" \
      "stalled worker: ${wid} on ${ticket}"
  done <<< "$rows"
}

# -----------------------------------------------------------------------------
# RULE_broken_spec_pointer — CLAUDE.md cites a docs/specs/*.md that's missing.
# -----------------------------------------------------------------------------
rule_broken_spec_pointer() {
  local claude_md="$root/CLAUDE.md"
  [[ -f "$claude_md" ]] || return 0

  # Pull every docs/specs/<...>.md token referenced anywhere in CLAUDE.md.
  # Pointers appear as `docs/specs/2026-..-slug.md` (often inside backticks /
  # parens). grep -oE extracts the bare path; sort -u dedupes.
  local refs
  refs="$(grep -oE 'docs/specs/[A-Za-z0-9._/-]+\.md' "$claude_md" 2>/dev/null | sort -u || true)"
  [[ -z "$refs" ]] && return 0

  local ref lineno
  while IFS= read -r ref; do
    [[ -z "$ref" ]] && continue
    [[ -f "$root/$ref" ]] && continue   # exists ⇒ healthy pointer
    lineno="$(grep -nF "$ref" "$claude_md" 2>/dev/null | head -n1 | cut -d: -f1 || true)"
    emit_finding \
      "broken-spec-pointer" \
      "broken spec pointer: CLAUDE.md cites missing $ref" \
      "T1" \
      "CLAUDE.md:L${lineno:-?} references '$ref' which does not exist on disk" \
      "broken spec pointer: CLAUDE.md cites missing $ref"
  done <<< "$refs"
}

# -----------------------------------------------------------------------------
# Run enabled rules, then emit the collected findings as a JSON array.
# -----------------------------------------------------------------------------
rule_enabled "claude-md-ceiling"     && rule_claude_md_ceiling
rule_enabled "promotion-stale"       && rule_promotion_stale
rule_enabled "worker-stalled"        && rule_worker_stalled
rule_enabled "broken-spec-pointer"   && rule_broken_spec_pointer

if [[ -s "$findings_file" ]]; then
  jq -s '.' "$findings_file"
else
  printf '[]\n'
fi

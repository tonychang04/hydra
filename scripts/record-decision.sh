#!/usr/bin/env bash
#
# record-decision.sh — append one validated decision entry to the Decision Record.
#
# Hydra observes outcomes (logs/<ticket>.json, logs/traces/<ticket>.jsonl) but
# not REASONING. This helper makes Commander's WHY durable: it appends one JSON
# object per line to logs/decisions/<YYYY-MM-DD>.jsonl, the append-only,
# human-reviewable record of every consequential decision (tier-classify,
# ticket-pick, subagent-route, scope, merge-surface, escalate, rescue, gc,
# pause). The reader is scripts/decisions.sh ("why did Commander do X?").
#
# Pure bash + jq — no daemon, no backend. Mirrors scripts/trace-append.sh.
# The entry is VALIDATED before it is written: an invalid entry exits 1 and
# writes NOTHING (the completion-gate philosophy of #255 — never persist an
# unproven artifact).
#
# Output line shape (required keys; see state/schemas/decision-entry.schema.json):
#   {
#     "ts": "2026-06-08T18:30:00Z",
#     "decision_type": "merge-surface",
#     "subject": "tonychang04/hydra#501",
#     "decided": "surface-for-human",
#     "why": "t3-never: T3 is never auto-merge-eligible (safety rail)",
#     "alternatives": [{"option":"auto-merge","why_rejected":"..."}],   (optional)
#     "confidence": "high",                                             (optional)
#     "what_would_reverse": "...",                                      (optional)
#     "approval_ref": null                                              (#268 seam)
#   }
#
# Spec: docs/specs/2026-06-08-decision-record.md (ticket #267)

set -euo pipefail

DECISIONS_DIR_DEFAULT="${HYDRA_DECISIONS_DIR:-./logs/decisions}"

# Allowed enum values (kept in lockstep with the schema).
VALID_TYPES=(tier-classify ticket-pick subagent-route scope merge-surface escalate rescue gc pause)
VALID_CONFIDENCE=(low medium high)

usage() {
  cat <<'EOF'
Usage:
  record-decision.sh --type <t> --subject <s> --decided <d> --why <w> [options]
  record-decision.sh --json [options]      # read a complete entry from stdin

Appends one VALIDATED decision entry to <decisions-dir>/<date>.jsonl.
An invalid entry exits 1 and writes nothing.

Required (flags mode):
  --type <t>            Decision type. One of:
                          tier-classify ticket-pick subagent-route scope
                          merge-surface escalate rescue gc pause
  --subject <s>         What the decision is about (ticket/PR/worker ref).
  --decided <d>         What was chosen.
  --why <w>             Rule/policy clause + concrete evidence.

Optional:
  --confidence <c>      low | medium | high
  --what-would-reverse <s>  The new fact that flips this decision.
  --approval-ref <r>    Link/ref to an approval record (#268 seam). Default null.
  --alternative 'opt::why'  A rejected option and why. Repeatable.

JSON mode:
  --json                Read a complete entry object from stdin instead of flags.
                        ts is injected if the object omits it. The same
                        validation applies.

Common:
  --date <YYYY-MM-DD>   Target daily file (default: today, UTC). Test seam.
  --decisions-dir <p>   Directory (default: $HYDRA_DECISIONS_DIR or
                        ./logs/decisions). Auto-created.
  -h, --help            Show this help.

Exit codes:
  0  entry appended
  1  invalid entry (validation failed; nothing written)
  2  usage error
EOF
}

die_usage() { echo "record-decision: $1" >&2; usage >&2; exit 2; }
die_invalid() { echo "record-decision: invalid entry — $1" >&2; exit 1; }

# --- argument parsing --------------------------------------------------------
json_mode=0
dtype=""
subject=""
decided=""
why=""
confidence=""
what_would_reverse=""
approval_ref=""
approval_ref_set=0
decisions_dir="$DECISIONS_DIR_DEFAULT"
date_override=""
alt_opts=()
alt_whys=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --json)                json_mode=1; shift ;;
    --type)                [[ $# -ge 2 ]] || die_usage "--type needs a value"; dtype="$2"; shift 2 ;;
    --subject)             [[ $# -ge 2 ]] || die_usage "--subject needs a value"; subject="$2"; shift 2 ;;
    --decided)             [[ $# -ge 2 ]] || die_usage "--decided needs a value"; decided="$2"; shift 2 ;;
    --why)                 [[ $# -ge 2 ]] || die_usage "--why needs a value"; why="$2"; shift 2 ;;
    --confidence)          [[ $# -ge 2 ]] || die_usage "--confidence needs a value"; confidence="$2"; shift 2 ;;
    --what-would-reverse)  [[ $# -ge 2 ]] || die_usage "--what-would-reverse needs a value"; what_would_reverse="$2"; shift 2 ;;
    --approval-ref)        [[ $# -ge 2 ]] || die_usage "--approval-ref needs a value"; approval_ref="$2"; approval_ref_set=1; shift 2 ;;
    --alternative)
      [[ $# -ge 2 ]] || die_usage "--alternative needs an 'opt::why' value"
      case "$2" in
        *"::"*) alt_opts+=("${2%%::*}"); alt_whys+=("${2#*::}") ;;
        *)      alt_opts+=("$2");        alt_whys+=("") ;;
      esac
      shift 2
      ;;
    --date)                [[ $# -ge 2 ]] || die_usage "--date needs a value"; date_override="$2"; shift 2 ;;
    --decisions-dir)       [[ $# -ge 2 ]] || die_usage "--decisions-dir needs a value"; decisions_dir="$2"; shift 2 ;;
    -h|--help)             usage; exit 0 ;;
    *)                     die_usage "unknown argument: $1" ;;
  esac
done

command -v jq >/dev/null 2>&1 || { echo "record-decision: jq required but not found" >&2; exit 2; }

# --- helpers -----------------------------------------------------------------
in_list() {  # in_list <needle> <items...>
  local needle="$1"; shift
  local x
  for x in "$@"; do [[ "$x" == "$needle" ]] && return 0; done
  return 1
}

iso_now_utc() {
  # ISO-8601 UTC, second precision. Portable (no %N dependency).
  date -u +%Y-%m-%dT%H:%M:%SZ
}

target_date() {
  if [[ -n "$date_override" ]]; then printf '%s' "$date_override"; else date -u +%Y-%m-%d; fi
}

# --- build the candidate entry object ---------------------------------------
# entry holds a single-line JSON object built with jq; we validate it before
# appending. Both flags-mode and json-mode converge on `entry`.
entry=""

if [[ "$json_mode" -eq 1 ]]; then
  # Read a complete object from stdin.
  raw="$(cat)"
  [[ -n "${raw//[[:space:]]/}" ]] || die_usage "--json given but stdin was empty"
  printf '%s' "$raw" | jq -e 'type == "object"' >/dev/null 2>&1 \
    || die_usage "--json input is not a JSON object"
  entry="$(printf '%s' "$raw" | jq -c '.')"
  # Inject ts if absent or empty.
  has_ts="$(printf '%s' "$entry" | jq -r 'if (.ts // "") == "" then "no" else "yes" end')"
  if [[ "$has_ts" != "yes" ]]; then
    entry="$(printf '%s' "$entry" | jq -c --arg ts "$(iso_now_utc)" '.ts = $ts')"
  fi
else
  # Flags mode: stdin is irrelevant — close it so the jq -n calls never block.
  exec </dev/null
  # Build alternatives array (may be empty). Guard the empty-array case for
  # bash 3.2 / set -u (same pattern as trace-append.sh).
  alts_json='[]'
  for (( i = 0; i < ${#alt_opts[@]}; i++ )); do
    a_opt="${alt_opts[$i]}"
    a_why="${alt_whys[$i]}"
    if [[ -n "$a_why" ]]; then
      one="$(jq -nc --arg o "$a_opt" --arg w "$a_why" '{option:$o, why_rejected:$w}')"
    else
      one="$(jq -nc --arg o "$a_opt" '{option:$o}')"
    fi
    alts_json="$(jq -c --argjson one "$one" '. + [$one]' <<<"$alts_json")"
  done

  # approval_ref: explicit value, else JSON null (the #268 seam default).
  if [[ "$approval_ref_set" -eq 1 ]]; then
    approval_json="$(jq -nc --arg r "$approval_ref" '$r')"
  else
    approval_json='null'
  fi

  entry="$(jq -nc \
    --arg ts "$(iso_now_utc)" \
    --arg type "$dtype" \
    --arg subject "$subject" \
    --arg decided "$decided" \
    --arg why "$why" \
    --argjson approval "$approval_json" \
    '{ts:$ts, decision_type:$type, subject:$subject, decided:$decided, why:$why, approval_ref:$approval}')"

  # Attach optional fields only when present.
  [[ -n "$confidence" ]] && entry="$(jq -c --arg c "$confidence" '.confidence = $c' <<<"$entry")"
  [[ -n "$what_would_reverse" ]] && entry="$(jq -c --arg w "$what_would_reverse" '.what_would_reverse = $w' <<<"$entry")"
  # Alternatives: include only if non-empty.
  if [[ "$(jq -r 'length' <<<"$alts_json")" != "0" ]]; then
    entry="$(jq -c --argjson a "$alts_json" '.alternatives = $a' <<<"$entry")"
  fi
fi

# --- validate (the gate: invalid -> exit 1, write nothing) -------------------
# Required fields present + non-empty strings.
for field in ts decision_type subject decided why; do
  v="$(printf '%s' "$entry" | jq -r --arg f "$field" '.[$f] // ""')"
  [[ -n "${v//[[:space:]]/}" ]] || die_invalid "missing or empty required field '$field'"
done

# decision_type enum.
dt="$(printf '%s' "$entry" | jq -r '.decision_type')"
in_list "$dt" "${VALID_TYPES[@]}" || die_invalid "decision_type '$dt' not in {${VALID_TYPES[*]}}"

# confidence enum (only if present).
conf="$(printf '%s' "$entry" | jq -r '.confidence // ""')"
if [[ -n "$conf" ]]; then
  in_list "$conf" "${VALID_CONFIDENCE[@]}" || die_invalid "confidence '$conf' not in {${VALID_CONFIDENCE[*]}}"
fi

# ts shape (ISO-8601 UTC second precision).
ts_v="$(printf '%s' "$entry" | jq -r '.ts')"
[[ "$ts_v" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] \
  || die_invalid "ts '$ts_v' is not ISO-8601 UTC second precision (YYYY-MM-DDTHH:MM:SSZ)"

# alternatives, if present, must be an array of objects with an 'option'.
alt_ok="$(printf '%s' "$entry" | jq -r '
  if has("alternatives")
  then (if (.alternatives | type) == "array"
          and (all(.alternatives[]; (type=="object") and ((.option // "") != "")))
        then "ok" else "bad" end)
  else "ok" end')"
[[ "$alt_ok" == "ok" ]] || die_invalid "alternatives must be an array of objects each with a non-empty 'option'"

# --- append (atomic single-line append; single writer per daily file) --------
the_date="$(target_date)"
mkdir -p "$decisions_dir"
out_file="$decisions_dir/$the_date.jsonl"
printf '%s\n' "$entry" >> "$out_file"

exit 0

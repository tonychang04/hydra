#!/usr/bin/env bash
#
# approvals.sh — read the Approval Record: "was approval obtained for #N, by
# whom, why?" Answers from state/approvals.json alone (the durable record
# written by scripts/approve.sh, #268).
#
# Modes:
#   approvals.sh                      every subject's current status (newest first)
#   approvals.sh <subject>            one subject's current status + full history
#   approvals.sh --status <s>         only subjects whose status == s
#                                       (awaiting | approved | rejected)
#   approvals.sh ... --json           machine output (the matching subset object)
#
# <subject> accepts #N, <owner>/<repo>#N, or worker-abc; a bare #N matches any
# subject key ending in #N (so `#501` finds `tonychang04/hydra#501`).
#
# Pure bash + jq. Mirrors scripts/decisions.sh (the Decision Record reader).
#
# Spec: docs/specs/2026-06-08-approval-record.md (ticket #268)

set -euo pipefail

APPROVALS_FILE_DEFAULT="${HYDRA_APPROVALS_FILE:-./state/approvals.json}"

usage() {
  cat <<'EOF'
Usage: approvals.sh [<subject>] [--status <s>] [--json] [--approvals-file <p>]

Reads the Approval Record (state/approvals.json) and prints approval status,
approver, time, and reason — the durable answer to "was approval obtained for
#N, by whom, why?".

Arguments:
  <subject>             Filter to one subject (#N, <owner>/<repo>#N, worker-abc).
                        A bare #N matches any subject key ending in #N.

Options:
  --status <s>          Filter to subjects with status s: awaiting | approved | rejected.
  --json                Machine output: the matching subset as a JSON object.
  --approvals-file <p>  Source file (default: $HYDRA_APPROVALS_FILE or
                        ./state/approvals.json).
  -h, --help            Show this help.

Exit codes:
  0  printed (including the empty/absent-file case)
  2  usage error / explicitly-named file unreadable
EOF
}

die_usage() { echo "approvals: $1" >&2; usage >&2; exit 2; }

subject_filter=""
status_filter=""
json_out=0
approvals_file="$APPROVALS_FILE_DEFAULT"
file_explicit=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --status)         [[ $# -ge 2 ]] || die_usage "--status needs a value"; status_filter="$2"; shift 2 ;;
    --json)           json_out=1; shift ;;
    --approvals-file) [[ $# -ge 2 ]] || die_usage "--approvals-file needs a value"; approvals_file="$2"; file_explicit=1; shift 2 ;;
    -h|--help)        usage; exit 0 ;;
    --) shift; break ;;
    -*)               die_usage "unknown argument: $1" ;;
    *)
      if [[ -z "$subject_filter" ]]; then subject_filter="$1"; shift
      else die_usage "unexpected positional argument: $1"; fi
      ;;
  esac
done

command -v jq >/dev/null 2>&1 || { echo "approvals: jq required but not found" >&2; exit 2; }

if [[ -n "$status_filter" ]]; then
  case "$status_filter" in
    awaiting|approved|rejected) : ;;
    *) die_usage "--status must be one of: awaiting approved rejected" ;;
  esac
fi

# --- load (absent file -> empty record, exit 0) ------------------------------
if [[ ! -f "$approvals_file" ]]; then
  if [[ "$file_explicit" -eq 1 ]]; then
    # An explicitly-named-but-absent file is the "nothing recorded yet" case —
    # not an error. Mirror the empty record.
    :
  fi
  if [[ "$json_out" -eq 1 ]]; then echo '{}'; else echo "_no approvals recorded_"; fi
  exit 0
fi

if ! jq -e 'type == "object"' "$approvals_file" >/dev/null 2>&1; then
  echo "approvals: $approvals_file is not a JSON object" >&2
  exit 2
fi

# --- build the matching subset ----------------------------------------------
# Meta keys (leading underscore, e.g. _comment) are skipped.
# subject_filter matching:
#   - exact key match, OR
#   - bare #N matches any key ending in #N
subset="$(jq -c \
  --arg subj "$subject_filter" \
  --arg status "$status_filter" '
  (.approvals // {})
  | with_entries(select(.key | startswith("_") | not))
  | with_entries(
      select(
        ($subj == "")
        or (.key == $subj)
        or (($subj | startswith("#")) and (.key | endswith($subj)))
      )
    )
  | with_entries(select(($status == "") or (.value.status == $status)))
' "$approvals_file")"

if [[ "$json_out" -eq 1 ]]; then
  printf '%s\n' "$subset" | jq '.'
  exit 0
fi

# --- human-readable rendering -----------------------------------------------
count="$(printf '%s' "$subset" | jq -r 'length')"
if [[ "$count" == "0" ]]; then
  echo "_none_"
  exit 0
fi

if [[ -n "$subject_filter" ]]; then
  # Detailed view: current line + full history for each matched subject.
  printf '%s' "$subset" | jq -r '
    to_entries
    | sort_by(.value.current.ts) | reverse
    | .[]
    | .value as $r
    | "\($r.status | ascii_upcase)  \($r.subject)"
      + "\n  by \($r.current.approver // "—") at \($r.current.ts): \($r.current.reason)"
      + (if ($r.current.decision_ref // null) != null then "\n  decision_ref: \($r.current.decision_ref)" else "" end)
      + "\n  history:"
      + ( [ $r.history[]
            | "\n    \(.ts)  \(.decision)  by \(.approver // "—"): \(.reason)" ] | add // "" )
      + "\n"
  '
else
  # Summary view: one line per subject, newest action first.
  printf '%s' "$subset" | jq -r '
    to_entries
    | sort_by(.value.current.ts) | reverse
    | .[]
    | .value as $r
    | "\($r.status | ascii_upcase)\t\($r.subject) — by \($r.current.approver // "—") at \($r.current.ts): \($r.current.reason)"
  ' | column -t -s $'\t' 2>/dev/null || printf '%s' "$subset" | jq -r '
    to_entries | sort_by(.value.current.ts) | reverse | .[] | .value as $r
    | "\($r.status | ascii_upcase)  \($r.subject) — by \($r.current.approver // "—") at \($r.current.ts): \($r.current.reason)"'
fi

exit 0

#!/usr/bin/env bash
#
# decisions.sh — read the Decision Record ("why did Commander do X?").
#
# Prints the decision(s) + rationale that Commander recorded via
# scripts/record-decision.sh into logs/decisions/<YYYY-MM-DD>.jsonl. This is the
# human read-path for the durable WHY: filter by subject (a ticket/PR/worker
# ref) to answer "why did Commander surface PR #501 for human merge?".
#
# Pure bash + jq. Reads across all daily files in the decisions dir, newest
# entry first.
#
# Spec: docs/specs/2026-06-08-decision-record.md (ticket #267)

set -euo pipefail

DECISIONS_DIR_DEFAULT="${HYDRA_DECISIONS_DIR:-./logs/decisions}"

usage() {
  cat <<'EOF'
Usage: decisions.sh [<subject>] [options]

Prints recorded decisions + rationale, newest first.

Arguments:
  <subject>             Filter to entries whose subject matches. A bare #N
                        (e.g. #501) matches any subject ending in #501 (so
                        '#501' matches 'tonychang04/hydra#501'); any other
                        string is a substring match (e.g. 'worker-abc').

Options:
  --since <YYYY-MM-DD>  Only entries on or after this date.
  --json                Emit a JSON array of entries (machine output).
  --decisions-dir <p>   Directory (default: $HYDRA_DECISIONS_DIR or
                        ./logs/decisions).
  -h, --help            Show this help.

Exit codes:
  0  ok (matches printed, or none found — an empty record is not an error)
  2  usage error (an explicit --decisions-dir that is not a directory)
EOF
}

die_usage() { echo "decisions: $1" >&2; usage >&2; exit 2; }

# --- argument parsing --------------------------------------------------------
subject=""
since=""
json_out=0
decisions_dir="$DECISIONS_DIR_DEFAULT"
dir_explicit=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --since)          [[ $# -ge 2 ]] || die_usage "--since needs a value"; since="$2"; shift 2 ;;
    --json)           json_out=1; shift ;;
    --decisions-dir)  [[ $# -ge 2 ]] || die_usage "--decisions-dir needs a value"; decisions_dir="$2"; dir_explicit=1; shift 2 ;;
    -h|--help)        usage; exit 0 ;;
    --*)              die_usage "unknown option: $1" ;;
    *)
      [[ -z "$subject" ]] || die_usage "only one <subject> may be given (got extra '$1')"
      subject="$1"; shift
      ;;
  esac
done

command -v jq >/dev/null 2>&1 || { echo "decisions: jq required but not found" >&2; exit 2; }
exec </dev/null

# An explicit dir that doesn't exist is a usage error; the default dir absent is
# fail-soft (an empty record is normal before any decision is logged).
if [[ ! -d "$decisions_dir" ]]; then
  if [[ "$dir_explicit" -eq 1 ]]; then
    # Tolerate an absent explicit dir as "empty record" (fail-soft) — surfaces
    # call this opportunistically before anything is recorded. A path that
    # exists but is a FILE is the genuine usage error.
    if [[ -e "$decisions_dir" ]]; then
      die_usage "--decisions-dir '$decisions_dir' is not a directory"
    fi
  fi
  # No dir → empty record.
  if [[ "$json_out" -eq 1 ]]; then printf '[]\n'; fi
  exit 0
fi

# --- gather entries ----------------------------------------------------------
# Collect daily files in date order. Filenames are YYYY-MM-DD.jsonl so a plain
# sort is chronological. Apply --since by filename (cheap, file-granular) and
# again per-entry by ts (precise).
files=()
while IFS= read -r f; do
  [[ -n "$f" ]] || continue
  base="$(basename -- "$f")"
  day="${base%.jsonl}"
  if [[ -n "$since" ]]; then
    # String compare works for YYYY-MM-DD.
    [[ "$day" < "$since" ]] && continue
  fi
  files+=("$f")
done < <(ls -1 "$decisions_dir"/*.jsonl 2>/dev/null | sort || true)

# Build a single JSON array of all entries, then filter + sort with jq.
# Guard the empty-array case (bash 3.2 / set -u).
if [[ "${#files[@]}" -eq 0 ]]; then
  if [[ "$json_out" -eq 1 ]]; then printf '[]\n'; fi
  exit 0
fi

# Slurp every line of every file into one array. jq -s over `inputs` keeps
# malformed lines from aborting the whole read (fromjson? drops bad lines).
all="$(cat "${files[@]}" | jq -R -s '
  split("\n") | map(select(length > 0)) | map(. as $l | try ($l | fromjson) catch empty)
' 2>/dev/null || echo '[]')"
[[ -n "$all" ]] || all='[]'

# Apply --since at entry granularity (ts >= since when since given), the subject
# filter, and sort newest-first by ts.
filtered="$(printf '%s' "$all" | jq \
  --arg subject "$subject" \
  --arg since "$since" \
  '
  def matches_subject($s; $needle):
    if ($needle | length) == 0 then true
    elif ($needle | startswith("#")) then ($s | endswith($needle))
    else ($s | contains($needle)) end;

  map(select(
        ($since | length) == 0
        or ((.ts // "")[0:10] >= $since)
      ))
  | map(select(matches_subject(.subject // ""; $subject)))
  | sort_by(.ts) | reverse
  ')"
[[ -n "$filtered" ]] || filtered='[]'

# --- output ------------------------------------------------------------------
if [[ "$json_out" -eq 1 ]]; then
  printf '%s\n' "$filtered" | jq -c '.'
  exit 0
fi

count="$(printf '%s' "$filtered" | jq 'length')"
if [[ "$count" -eq 0 ]]; then
  if [[ -n "$subject" ]]; then
    echo "No recorded decisions for subject '$subject'."
  else
    echo "No recorded decisions."
  fi
  exit 0
fi

# Human-readable block per entry.
printf '%s' "$filtered" | jq -r '
  .[]
  | "\(.ts)  [\(.decision_type)]  \(.subject) → \(.decided)",
    "    why: \(.why)",
    (if (.confidence // "") != "" then "    confidence: \(.confidence)" else empty end),
    (if (.what_would_reverse // "") != "" then "    what would reverse: \(.what_would_reverse)" else empty end),
    (if ((.alternatives // []) | length) > 0
       then "    alternatives: " + ((.alternatives | map(.option + (if (.why_rejected // "") != "" then " (" + .why_rejected + ")" else "" end))) | join("; "))
       else empty end),
    (if (.approval_ref // null) != null then "    approval: \(.approval_ref)" else empty end),
    ""
'

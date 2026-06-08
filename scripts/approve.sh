#!/usr/bin/env bash
#
# approve.sh — record ONE validated human-gated approval action durably.
#
# Human approval in Hydra used to be EPHEMERAL: the operator merged via GitHub
# or said "yes" in chat and Hydra recorded nothing about WHO approved, WHEN, or
# WHY. This helper makes approval a durable, auditable artifact: it records one
# action (approve / reject / await) for a subject (ticket/PR/worker ref) into
# state/approvals.json — a map of subject-key -> {current status + append-only
# history}. The reader is scripts/approvals.sh ("was approval obtained for #N,
# by whom, why?").
#
# Pure bash + jq — no daemon, no backend. Mirrors scripts/record-decision.sh
# (the sibling Decision Record writer, #267). The action is VALIDATED before it
# is written: an invalid action exits 1 (or 2 for usage errors) and writes
# NOTHING — the completion-gate philosophy of #255 (never persist an unproven
# artifact). Writes are atomic (temp file + mv), single writer per file.
#
# The two records form one audit trail (#267 + #268): an approval action's
# `decision_ref` links to a Decision Record entry, and approve.sh prints the
# minted `approval:<subject-key>` on stdout so the caller can store it as that
# entry's `approval_ref`.
#
# Output (stdout): the minted approval key `approval:<subject-key>`.
#
# Spec: docs/specs/2026-06-08-approval-record.md (ticket #268)

set -euo pipefail

APPROVALS_FILE_DEFAULT="${HYDRA_APPROVALS_FILE:-./state/approvals.json}"

VALID_DECISIONS=(approved rejected awaiting)

usage() {
  cat <<'EOF'
Usage:
  approve.sh <subject> --approve --by <who> --reason "..." [options]
  approve.sh <subject> --reject  --by <who> --reason "..." [options]
  approve.sh <subject> --await             --reason "..." [options]

Records ONE approval action for <subject> into state/approvals.json and prints
the minted `approval:<subject-key>` on stdout. An invalid action writes nothing.

Subject:
  <subject>             A ticket/PR/worker ref: #501, <owner>/<repo>#501, or
                        worker-abc. A bare #N is normalized to <repo>#N when
                        --repo (or $HYDRA_DEFAULT_REPO) is set, else stays #N.

Decision (exactly one required):
  --approve             Record a human approval (requires --by).
  --reject              Record a human rejection (requires --by).
  --await               Mark the subject as surfaced, awaiting a human (no --by).

Required:
  --reason "..."        WHY — non-empty rationale for the action.

Conditional:
  --by <who>            WHO approved/rejected. Required for --approve/--reject;
                        rejected for --await (await has no human yet).

Optional:
  --decision-ref <r>    Link to the Decision Record entry (e.g.
                        merge-surface:<subject>). Default null.
  --repo <owner>/<name> Repo context used to normalize a bare #N subject.
                        Default $HYDRA_DEFAULT_REPO.
  --approvals-file <p>  Target file (default: $HYDRA_APPROVALS_FILE or
                        ./state/approvals.json). Parent dir auto-created.
  --now <iso8601>       Override the timestamp (test seam). Default: now (UTC).
  -h, --help            Show this help.

Exit codes:
  0  action recorded (key printed)
  1  invalid action (validation failed; nothing written)
  2  usage error
EOF
}

die_usage()   { echo "approve: $1" >&2; usage >&2; exit 2; }
die_invalid() { echo "approve: invalid action — $1" >&2; exit 1; }

in_list() {  # in_list <needle> <items...>
  local needle="$1"; shift
  local x
  for x in "$@"; do [[ "$x" == "$needle" ]] && return 0; done
  return 1
}

iso_now_utc() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# --- argument parsing --------------------------------------------------------
subject_arg=""
decision=""           # set by exactly one of --approve/--reject/--await
decision_count=0
by=""
by_set=0
reason=""
reason_set=0
decision_ref=""
decision_ref_set=0
repo="${HYDRA_DEFAULT_REPO:-}"
approvals_file="$APPROVALS_FILE_DEFAULT"
now_override=""

set_decision() {  # set_decision <value>
  decision="$1"
  decision_count=$((decision_count + 1))
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --approve)        set_decision "approved"; shift ;;
    --reject)         set_decision "rejected"; shift ;;
    --await)          set_decision "awaiting"; shift ;;
    --by)             [[ $# -ge 2 ]] || die_usage "--by needs a value"; by="$2"; by_set=1; shift 2 ;;
    --reason)         [[ $# -ge 2 ]] || die_usage "--reason needs a value"; reason="$2"; reason_set=1; shift 2 ;;
    --decision-ref)   [[ $# -ge 2 ]] || die_usage "--decision-ref needs a value"; decision_ref="$2"; decision_ref_set=1; shift 2 ;;
    --repo)           [[ $# -ge 2 ]] || die_usage "--repo needs a value"; repo="$2"; shift 2 ;;
    --approvals-file) [[ $# -ge 2 ]] || die_usage "--approvals-file needs a value"; approvals_file="$2"; shift 2 ;;
    --now)            [[ $# -ge 2 ]] || die_usage "--now needs a value"; now_override="$2"; shift 2 ;;
    -h|--help)        usage; exit 0 ;;
    --) shift; break ;;
    -*)               die_usage "unknown argument: $1" ;;
    *)
      if [[ -z "$subject_arg" ]]; then subject_arg="$1"; shift
      else die_usage "unexpected positional argument: $1"; fi
      ;;
  esac
done

command -v jq >/dev/null 2>&1 || { echo "approve: jq required but not found" >&2; exit 2; }

# --- usage-level validation (exit 2) ----------------------------------------
[[ -n "$subject_arg" ]] || die_usage "a <subject> is required"
[[ "$decision_count" -ge 1 ]] || die_usage "one of --approve / --reject / --await is required"
[[ "$decision_count" -le 1 ]] || die_usage "give exactly one of --approve / --reject / --await"

case "$decision" in
  approved|rejected)
    [[ "$by_set" -eq 1 ]] || die_usage "--$( [[ $decision == approved ]] && echo approve || echo reject ) requires --by <who>"
    [[ -n "${by//[[:space:]]/}" ]] || die_usage "--by must be non-empty"
    ;;
  awaiting)
    [[ "$by_set" -eq 0 ]] || die_usage "--await takes no --by (no human has decided yet)"
    ;;
esac

# --reason is a required input for every mode (a non-empty rationale is the WHY).
[[ "$reason_set" -eq 1 ]] || die_usage "--reason is required"
[[ -n "${reason//[[:space:]]/}" ]] || die_usage "--reason must be non-empty"

# --- subject normalization ---------------------------------------------------
# #N            -> <repo>#N  (if repo known) else #N
# <repo>#N      -> as-is
# worker-abc    -> as-is
normalize_subject() {  # normalize_subject <raw>
  local raw="$1"
  case "$raw" in
    \#[0-9]*)
      if [[ -n "$repo" ]]; then printf '%s#%s' "$repo" "${raw#\#}"; else printf '%s' "$raw"; fi
      ;;
    *) printf '%s' "$raw" ;;
  esac
}
subject_key="$(normalize_subject "$subject_arg")"

# --- build + validate the action object (invalid -> exit 1, write nothing) ---
ts="${now_override:-$(iso_now_utc)}"

# ts shape gate.
[[ "$ts" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] \
  || die_invalid "ts '$ts' is not ISO-8601 UTC second precision (YYYY-MM-DDTHH:MM:SSZ)"

# decision enum (belt-and-suspenders; set internally).
in_list "$decision" "${VALID_DECISIONS[@]}" || die_invalid "decision '$decision' not in {${VALID_DECISIONS[*]}}"

# approver presence rule (required input already enforced as usage above):
# null for awaiting, the provided --by otherwise.
if [[ "$decision" == "awaiting" ]]; then
  approver_json='null'
else
  approver_json="$(jq -nc --arg b "$by" '$b')"
fi

# decision_ref: explicit string, else null.
if [[ "$decision_ref_set" -eq 1 ]]; then
  dref_json="$(jq -nc --arg r "$decision_ref" '$r')"
else
  dref_json='null'
fi

action="$(jq -nc \
  --arg decision "$decision" \
  --argjson approver "$approver_json" \
  --arg ts "$ts" \
  --arg reason "$reason" \
  --argjson dref "$dref_json" \
  '{decision:$decision, approver:$approver, ts:$ts, reason:$reason, decision_ref:$dref}')"

# --- read-modify-write the approvals file (atomic) ---------------------------
mkdir -p "$(dirname "$approvals_file")"

# Load existing state, or start fresh. A malformed existing file is a setup
# error, not a silently-clobbered file.
if [[ -f "$approvals_file" ]]; then
  if ! jq -e 'type == "object"' "$approvals_file" >/dev/null 2>&1; then
    echo "approve: existing $approvals_file is not a JSON object — refusing to overwrite" >&2
    exit 2
  fi
  current_state="$(cat "$approvals_file")"
else
  current_state='{"approvals":{}}'
fi

# Merge: ensure .approvals exists, then for the subject set/append.
new_state="$(printf '%s' "$current_state" | jq -c \
  --arg key "$subject_key" \
  --argjson action "$action" '
    (.approvals //= {})
    | .approvals[$key] = (
        (.approvals[$key] // {subject:$key, history:[]})
        | .subject  = $key
        | .history  = ((.history // []) + [$action])
        | .current  = $action
        | .status   = $action.decision
      )
  ')"

# Atomic write.
tmp="$(mktemp "${approvals_file}.XXXXXX")"
trap 'rm -f "$tmp"' EXIT
printf '%s\n' "$new_state" | jq '.' > "$tmp"
mv "$tmp" "$approvals_file"
trap - EXIT

# Print the minted approval key for the caller (Decision Record approval_ref).
printf 'approval:%s\n' "$subject_key"
exit 0

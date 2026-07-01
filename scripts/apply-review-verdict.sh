#!/usr/bin/env bash
#
# apply-review-verdict.sh — actuate review-gate labels on a PR from a verdict.
#
# Commander runs this AFTER a worker-review / worker-validator worker returns,
# on the worker's machine-readable `*_VERDICT:` marker. Workers themselves are
# blocked by the Claude Code auto-mode classifier from writing to the PR (it
# reads "post a verdict / apply a label" as an unauthorized external publish,
# and denies both the `gh pr review` comment and the label POST). So the
# actuation belongs to Commander's context, which CAN apply labels via REST.
#
# The pr-shepherd state machine keys on these labels (scripts/pr-shepherd.sh):
# no `commander-reviewed` label -> needs-review-gate -> re-spawn worker-review.
# If the label never lands, the shepherd re-spawns review endlessly (#320 drift:
# a merged PR stuck at `commander-review`). This script makes the label land
# idempotently and REMOVES the superseded interim label.
#
# Usage:
#   apply-review-verdict.sh <owner>/<repo> <pr> <verdict> [--dry-run]
#
# verdict is one of:
#   reviewed      -> add commander-reviewed;    remove commander-review, commander-needs-fix
#   review-clean  -> add commander-reviewed + commander-review-clean (superset of
#                    reviewed: satisfies the shepherd gate AND the
#                    auto_if_review_clean merge policy); remove commander-review,
#                    commander-needs-fix
#   validated     -> add commander-validated
#   needs-fix     -> add commander-needs-fix; remove commander-reviewed,
#                    commander-review-clean, commander-validated
#   stuck         -> add commander-stuck
#   rejected      -> add commander-rejected; remove commander-review,
#                    commander-reviewed, commander-review-clean
#
# Marker -> verdict translation (Commander applies this before calling):
#   REVIEW_VERDICT: clean     -> review-clean
#   REVIEW_VERDICT: needs-fix  -> needs-fix
#   REVIEW_VERDICT: blocked    -> stuck        (preserves security-blocker -> stuck)
#   VALIDATION_VERDICT: pass   -> validated
#   VALIDATION_VERDICT: fail   -> stuck
#
# Idempotent: adding an already-present label is a server-side no-op (POST
# returns 200); removing an absent label 404s harmlessly (guarded with `|| true`).
# Re-running the same verdict is safe.
#
# --dry-run prints the planned add/remove transitions and mutates NOTHING
# (never invokes `gh`).
#
# Label writes use the REST API (`gh api --method POST/DELETE .../issues/<n>/labels`)
# NOT `gh pr edit --add-label` — the latter hits GraphQL and fails with a
# Projects-classic deprecation. PRs are issues in GitHub's data model, so the
# issues/<n>/labels endpoint accepts a PR number. See the `apply-label-via-rest`
# skill. Labels are lazily created (create-then-add) so a brand-new label
# (commander-needs-fix) doesn't 422 the POST.
#
# Exit codes:
#   0  verdict actuated (or planned, under --dry-run)
#   1  a required label ADD failed at the REST layer
#   2  usage error (bad args / unknown verdict)
#
# Spec: docs/specs/2026-07-01-commander-owns-review-verdict-actuation.md

set -euo pipefail

usage() {
  cat <<'EOF'
Usage: apply-review-verdict.sh <owner>/<repo> <pr> <verdict> [--dry-run]

Arguments:
  <owner>/<repo>   Repo slug (e.g. tonychang04/hydra).
  <pr>             PR number (digits).
  <verdict>        One of: reviewed, review-clean, validated, needs-fix,
                   stuck, rejected.

Options:
  --dry-run        Print the planned add/remove transitions; mutate nothing.
  -h, --help       Show this help.

Exit codes:
  0 = actuated (or planned under --dry-run) · 1 = REST failure · 2 = usage error
EOF
}

slug=""
pr=""
verdict=""
dry_run=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) dry_run=1; shift ;;
    -h|--help) usage; exit 0 ;;
    --) shift; break ;;
    -*)
      echo "apply-review-verdict: unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
    *)
      if [[ -z "$slug" ]]; then slug="$1"
      elif [[ -z "$pr" ]]; then pr="$1"
      elif [[ -z "$verdict" ]]; then verdict="$1"
      else
        echo "apply-review-verdict: too many positional args" >&2
        exit 2
      fi
      shift
      ;;
  esac
done

if [[ -z "$slug" || -z "$pr" || -z "$verdict" ]]; then
  echo "apply-review-verdict: <owner>/<repo>, <pr>, and <verdict> are all required" >&2
  usage >&2
  exit 2
fi

# Validate slug is <owner>/<name>.
owner="${slug%%/*}"
name="${slug#*/}"
if [[ -z "$owner" || -z "$name" || "$owner" == "$slug" || "$name" == *"/"* ]]; then
  echo "apply-review-verdict: slug must be <owner>/<name> (got '$slug')" >&2
  exit 2
fi

# Validate pr is a bare number (no path smuggling into the REST URL).
if [[ ! "$pr" =~ ^[0-9]+$ ]]; then
  echo "apply-review-verdict: <pr> must be a number (got '$pr')" >&2
  exit 2
fi

# Resolve the verdict -> (ADD list, REMOVE list). Space-separated label lists.
adds=""
removes=""
case "$verdict" in
  reviewed)
    adds="commander-reviewed"
    removes="commander-review commander-needs-fix"
    ;;
  review-clean)
    adds="commander-reviewed commander-review-clean"
    removes="commander-review commander-needs-fix"
    ;;
  validated)
    adds="commander-validated"
    removes=""
    ;;
  needs-fix)
    adds="commander-needs-fix"
    removes="commander-reviewed commander-review-clean commander-validated"
    ;;
  stuck)
    adds="commander-stuck"
    removes=""
    ;;
  rejected)
    adds="commander-rejected"
    removes="commander-review commander-reviewed commander-review-clean"
    ;;
  *)
    echo "apply-review-verdict: unknown verdict '$verdict'" >&2
    echo "  expected one of: reviewed, review-clean, validated, needs-fix, stuck, rejected" >&2
    exit 2
    ;;
esac

# label_meta <name> -> "<6-hex-color>|<description>" for lazy creation.
label_meta() {
  case "$1" in
    commander-review)       echo "FBCA04|Review gate: in review (interim)" ;;
    commander-reviewed)     echo "0E8A16|Review gate: reviewed" ;;
    commander-review-clean) echo "0E8A16|Review gate: clean review (auto_if_review_clean)" ;;
    commander-validated)    echo "1D76DB|Review gate: runtime-validated" ;;
    commander-needs-fix)    echo "D93F0B|Review gate: changes requested" ;;
    commander-stuck)        echo "B60205|Blocked — needs operator" ;;
    commander-rejected)     echo "000000|PR rejected / closed" ;;
    *)                      echo "EDEDED|Hydra review-gate label" ;;
  esac
}

# --- dry-run: print the plan, mutate nothing -------------------------------
if [[ "$dry_run" == "1" ]]; then
  printf 'apply-review-verdict: %s#%s verdict=%s (dry-run — no changes)\n' "$slug" "$pr" "$verdict"
  for lbl in $adds; do
    printf '  + add    %s\n' "$lbl"
  done
  for lbl in $removes; do
    printf '  - remove %s\n' "$lbl"
  done
  exit 0
fi

# --- apply -----------------------------------------------------------------
# ADD (lazy create, then POST). A failed POST of a required label is fatal (1).
for lbl in $adds; do
  meta="$(label_meta "$lbl")"
  color="${meta%%|*}"
  desc="${meta#*|}"
  gh label create "$lbl" --repo "$slug" --color "$color" --description "$desc" \
    >/dev/null 2>&1 || true
  if ! gh api --method POST "/repos/$owner/$name/issues/$pr/labels" \
        -f "labels[]=$lbl" >/dev/null 2>&1; then
    echo "apply-review-verdict: failed to add label '$lbl' to $slug#$pr" >&2
    exit 1
  fi
  printf 'apply-review-verdict: added %s to %s#%s\n' "$lbl" "$slug" "$pr"
done

# REMOVE superseded (DELETE; 404 for an absent label is a harmless no-op).
for lbl in $removes; do
  gh api --method DELETE "/repos/$owner/$name/issues/$pr/labels/$lbl" \
    >/dev/null 2>&1 || true
  printf 'apply-review-verdict: removed %s from %s#%s (if present)\n' "$lbl" "$slug" "$pr"
done

exit 0

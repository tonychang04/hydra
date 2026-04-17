#!/usr/bin/env bash
#
# retro-file-proposed-edits.sh — turn the weekly retro's `## Proposed edits`
# bullets into GitHub issues.
#
# Commander's weekly retro writes memory/retros/YYYY-WW.md. The final
# `## Proposed edits` section lists concrete changes Commander noticed
# should happen (policy tweaks, worker-prompt fixes, memory entries).
# Without this script those bullets rot on disk. With it, each bullet
# becomes a labeled `commander-ready` issue that autopickup picks up
# next tick.
#
# Usage:
#   retro-file-proposed-edits.sh <week>
#
# <week>  ISO-8601 week tag matching the retro filename (e.g. 2026-16).
#         Read from memory/retros/<week>.md.
#
# Options:
#   --retros-dir <path>   Override memory/retros (default: memory/retros).
#   --default-repo <slug> Override the default target repo (default:
#                         tonychang04/hydra — Commander-internal fixes).
#   --dry-run             Print what WOULD be filed; do not call `gh issue
#                         create`. Idempotency lookups still happen.
#   -h, --help            Show this help.
#
# Env:
#   HYDRA_GH              Override the `gh` binary path (used by the test
#                         harness to stub GitHub calls). Default: gh.
#
# Output (stdout):
#   FILED: <issue-url>              — bullet filed as a new issue.
#   SKIPPED: <title> (duplicate)    — matching title already exists.
#   SURFACE: T3 <title>             — T3-tripwire match; not auto-filed.
#   WARN: <message>                 — non-fatal warning.
#
# Exit codes:
#   0  success (possibly zero filings — empty section, all duplicates,
#      all surface-only).
#   1  unrecoverable (retro file missing / malformed / gh auth broken).
#   2  usage error.
#
# Integration:
#   Called by Commander's retro procedure after it writes the retro file.
#   Safe to call standalone. Safe to re-run (idempotent).
#
# Spec: docs/specs/2026-04-17-retro-auto-file.md (ticket #142).

set -euo pipefail

# --- resolve paths ----------------------------------------------------------

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"

RETROS_DIR_DEFAULT="$ROOT_DIR/memory/retros"
DEFAULT_REPO_DEFAULT="tonychang04/hydra"
GH_BIN="${HYDRA_GH:-gh}"

# --- arg parse --------------------------------------------------------------

usage() {
  sed -n '3,35p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

retros_dir="$RETROS_DIR_DEFAULT"
default_repo="$DEFAULT_REPO_DEFAULT"
dry_run=0
week=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --retros-dir)
      [[ $# -ge 2 ]] || { echo "retro-file-proposed-edits: --retros-dir needs a value" >&2; exit 2; }
      retros_dir="$2"; shift 2
      ;;
    --default-repo)
      [[ $# -ge 2 ]] || { echo "retro-file-proposed-edits: --default-repo needs a value" >&2; exit 2; }
      default_repo="$2"; shift 2
      ;;
    --dry-run)
      dry_run=1; shift
      ;;
    -h|--help)
      usage; exit 0
      ;;
    -*)
      echo "retro-file-proposed-edits: unknown flag: $1" >&2
      usage >&2
      exit 2
      ;;
    *)
      if [[ -z "$week" ]]; then
        week="$1"; shift
      else
        echo "retro-file-proposed-edits: unexpected extra arg: $1" >&2
        usage >&2
        exit 2
      fi
      ;;
  esac
done

if [[ -z "$week" ]]; then
  echo "retro-file-proposed-edits: <week> is required (e.g. 2026-16)" >&2
  usage >&2
  exit 2
fi

# Basic week format sanity: YYYY-WW
if [[ ! "$week" =~ ^[0-9]{4}-[0-9]{2}$ ]]; then
  echo "retro-file-proposed-edits: <week> must be YYYY-WW (got: $week)" >&2
  exit 2
fi

retro_file="$retros_dir/$week.md"

if [[ ! -r "$retro_file" ]]; then
  echo "retro-file-proposed-edits: retro file not found or unreadable: $retro_file" >&2
  exit 1
fi

# --- extract ## Proposed edits section --------------------------------------

# Case-insensitive match on the "## Proposed edits" heading. Range ends at
# the next `^## ` sibling heading or EOF. awk FSM avoids the inclusive-range
# gotcha noted in memory/learnings-hydra.md:54.
proposed_section="$(awk '
  BEGIN { in_section = 0 }
  /^## / {
    if (in_section) { exit }
    low = tolower($0)
    if (low ~ /^## proposed edits[[:space:]]*$/) {
      in_section = 1
      next
    }
  }
  in_section { print }
' "$retro_file")"

# Strip leading/trailing blank lines for the empty-check.
trimmed_section="$(printf '%s\n' "$proposed_section" | awk 'NF { body=1 } body { print }' | awk '{ lines[NR]=$0 } END { last=NR; while (last>0 && lines[last]=="") last--; for (i=1;i<=last;i++) print lines[i] }')"

if [[ -z "$trimmed_section" ]]; then
  # No ## Proposed edits section, or section with zero content lines.
  # Silent no-op per spec: the retro may simply have nothing worth filing.
  exit 0
fi

# Sentinel string check (case-insensitive substring).
if printf '%s' "$trimmed_section" | tr '[:upper:]' '[:lower:]' | grep -q 'no pattern above minimum sample size this week'; then
  # Sample-size gate tripped inside the retro — nothing to file.
  exit 0
fi

# --- parse citation evidence from ## Stuck / ## Escalations -----------------

# "K workers hit commander-stuck" → K
stuck_count="$(awk '
  BEGIN { in_stuck = 0 }
  /^## / {
    if (in_stuck) { exit }
    low = tolower($0)
    if (low ~ /^## stuck[[:space:]]*$/) { in_stuck = 1; next }
  }
  in_stuck {
    if (match($0, /[0-9]+[[:space:]]+workers?[[:space:]]+hit[[:space:]]+commander-stuck/)) {
      n = substr($0, RSTART, RLENGTH)
      sub(/[^0-9].*/, "", n)
      print n
      exit
    }
  }
' "$retro_file")"

# "Human answered N novel questions" → N
esc_count="$(awk '
  BEGIN { in_esc = 0 }
  /^## / {
    if (in_esc) { exit }
    low = tolower($0)
    if (low ~ /^## escalations[[:space:]]*$/) { in_esc = 1; next }
  }
  in_esc {
    if (match($0, /[Hh]uman[[:space:]]+answered[[:space:]]+[0-9]+[[:space:]]+novel[[:space:]]+questions?/)) {
      chunk = substr($0, RSTART, RLENGTH)
      if (match(chunk, /[0-9]+/)) {
        print substr(chunk, RSTART, RLENGTH)
        exit
      }
    }
  }
' "$retro_file")"

if [[ -z "$stuck_count" && -z "$esc_count" ]]; then
  sample_size="unknown"
else
  total=$(( ${stuck_count:-0} + ${esc_count:-0} ))
  sample_size="$total data points ($(printf 'stuck=%s, escalations=%s' "${stuck_count:-0}" "${esc_count:-0}"))"
fi

# --- split proposed section into bullets ------------------------------------

# Each top-level `- ` or `* ` line starts a bullet. Continuation lines
# (indented >=2 spaces) fold in. Blank line ends the current bullet.
#
# We emit one bullet per line, with newlines encoded as \n literal (two-
# char sequence) so bash `while read` can process them. Printing decodes.
bullets=()
current=""

_flush() {
  if [[ -n "$current" ]]; then
    bullets+=("$current")
    current=""
  fi
}

while IFS= read -r line; do
  if [[ "$line" =~ ^[[:space:]]*$ ]]; then
    _flush
    continue
  fi
  if [[ "$line" =~ ^[[:space:]]{0,1}[-*][[:space:]]+ ]]; then
    # Start of a new top-level bullet.
    _flush
    # Strip leading bullet marker for storage; keep full text.
    current="$(printf '%s' "$line" | sed -E 's/^[[:space:]]{0,1}[-*][[:space:]]+//')"
  else
    # Continuation line (indented) — fold into current.
    if [[ -n "$current" ]]; then
      current="$current"$'\n'"$(printf '%s' "$line" | sed -E 's/^[[:space:]]+//')"
    fi
    # Orphan continuation (no preceding bullet) is silently dropped —
    # the section's prose preamble, if any, is not a bullet.
  fi
done <<< "$trimmed_section"
_flush

if [[ ${#bullets[@]} -eq 0 ]]; then
  # Section had content but no parseable bullets. Nothing to file.
  exit 0
fi

# --- classifier helpers -----------------------------------------------------

# T3 tripwire keywords (case-insensitive substring match).
T3_KEYWORDS=(
  'auth' 'authentication' 'authorize' 'migration' 'secret' 'credential'
  'token' 'oauth' 'crypto' 'rls ' 'rls,' 'rls.' '.github/workflows'
  'sudo ' 'drop table'
)

# T1 prefix heuristics (matched case-insensitively against the bullet
# summary's leading text).
T1_PREFIXES=(
  'fix typo' 'update readme' 'bump ' 'doc:' 'docs:' 'typo'
)

_classify_tier() {
  local text_lc
  text_lc="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
  local kw
  for kw in "${T3_KEYWORDS[@]}"; do
    if [[ "$text_lc" == *"$kw"* ]]; then
      echo "T3"
      return
    fi
  done
  for kw in "${T1_PREFIXES[@]}"; do
    if [[ "$text_lc" == "$kw"* || "$text_lc" == *" $kw"* ]]; then
      echo "T1"
      return
    fi
  done
  echo "T2"
}

_pick_repo() {
  local text="$1"
  # First match of `owner/repo` — alphanumeric + dash + underscore segments.
  local m
  m="$(printf '%s' "$text" | grep -oE '[A-Za-z0-9_-]+/[A-Za-z0-9_.-]+' | head -n1 || true)"
  if [[ -n "$m" ]]; then
    echo "$m"
  else
    echo "$default_repo"
  fi
}

_compose_title() {
  local week="$1" summary="$2"
  # Collapse whitespace and truncate.
  local clean trimmed
  clean="$(printf '%s' "$summary" | tr '\n\t' '  ' | sed -E 's/[[:space:]]+/ /g; s/^[[:space:]]+//; s/[[:space:]]+$//')"
  # 60-char body (title prefix added after). Truncate via python3 to be
  # codepoint-safe; bash ${var:0:N} slices by bytes and can leave a stray
  # UTF-8 leading byte which makes downstream tooling (grep in UTF-8 locale,
  # jq) treat the output as binary.
  if [[ ${#clean} -gt 60 ]]; then
    trimmed="$(python3 -c 'import sys; s=sys.argv[1]; print(s[:59] + "..." if len(s) > 60 else s, end="")' "$clean")"
  else
    trimmed="$clean"
  fi
  printf '[retro %s] %s' "$week" "$trimmed"
}

# --- idempotency lookup -----------------------------------------------------

_title_exists() {
  local repo="$1" title="$2"
  # `gh issue list` + jq filter. Search narrows server-side; the jq filter
  # confirms byte-for-byte title match (search is fuzzy-ish).
  local out
  if ! out="$("$GH_BIN" issue list --repo "$repo" --state all --search "[retro" --json title --limit 100 2>/dev/null)"; then
    # Search failure is not fatal — best-effort idempotency. Warn and
    # proceed; a duplicate issue is recoverable, a silent abort is not.
    echo "WARN: gh issue list failed on $repo; idempotency check skipped" >&2
    return 1
  fi
  printf '%s' "$out" | python3 -c '
import json, sys
needle = sys.argv[1]
try:
    rows = json.loads(sys.stdin.read() or "[]")
except Exception:
    sys.exit(1)
for r in rows:
    if r.get("title", "") == needle:
        sys.exit(0)
sys.exit(1)
' "$title"
}

# --- per-bullet processing --------------------------------------------------

for bullet in "${bullets[@]}"; do
  # first-line summary (for title + tier/repo classification)
  summary="$(printf '%s\n' "$bullet" | head -n1)"
  # Skip accidentally-empty bullets (shouldn't happen, belt-and-suspenders).
  if [[ -z "$summary" ]]; then
    continue
  fi

  tier="$(_classify_tier "$bullet")"
  repo="$(_pick_repo "$bullet")"
  title="$(_compose_title "$week" "$summary")"

  # T3 → surface, don't file.
  if [[ "$tier" == "T3" ]]; then
    printf 'SURFACE: T3 %s\n' "$title"
    continue
  fi

  # Idempotency check (best-effort; see _title_exists).
  if _title_exists "$repo" "$title"; then
    printf 'SKIPPED: %s (duplicate)\n' "$title"
    continue
  fi

  # Compose body.
  body="$(printf '## Proposed edit (from retro %s)\n\n%s\n\n## Source\n\n- Retro file: `memory/retros/%s.md`\n- Section: `## Proposed edits`\n- Sample size: %s\n- Classifier: tier %s (auto); repo %s (%s)\n' \
    "$week" "$bullet" "$week" "$sample_size" "$tier" "$repo" \
    "$( [[ "$repo" == "$default_repo" ]] && echo 'default hydra' || echo 'matched inline slug' )")"

  # Target labels: commander-ready, commander-auto-filed, commander-retro,
  # and the tier label (T1/T2). gh issue create --label is fine for plain
  # issues (memory/learnings-hydra.md:42) — the GraphQL-deprecation issue
  # only bites `gh pr edit`-family calls.
  labels=(
    "commander-ready"
    "commander-auto-filed"
    "commander-retro"
    "$tier"
  )

  if [[ "$dry_run" -eq 1 ]]; then
    printf 'DRY-RUN: would file on %s: %s (labels: %s)\n' "$repo" "$title" "${labels[*]}"
    continue
  fi

  # Build --label args.
  label_args=()
  for l in "${labels[@]}"; do
    label_args+=(--label "$l")
  done

  # Attempt create. Capture stdout (url) + stderr (for deprecation marker).
  tmp_stderr="$(mktemp)"
  # shellcheck disable=SC2064
  trap "rm -f '$tmp_stderr'" RETURN
  set +e
  url="$("$GH_BIN" issue create \
    --repo "$repo" \
    --assignee tonychang04 \
    --title "$title" \
    --body "$body" \
    "${label_args[@]}" \
    2> "$tmp_stderr")"
  rc=$?
  set -e

  if [[ $rc -eq 0 ]]; then
    printf 'FILED: %s\n' "$url"
    continue
  fi

  # Create failed. Look for known failure modes.
  err="$(cat "$tmp_stderr")"
  if printf '%s' "$err" | grep -qi 'not found\|could not find label\|label .* does not exist'; then
    # One or more labels missing. Fall back: create without labels, then
    # apply via REST POST (which works around the GraphQL-deprecation
    # issue on this repo per CLAUDE.md "Applying labels").
    set +e
    url="$("$GH_BIN" issue create \
      --repo "$repo" \
      --assignee tonychang04 \
      --title "$title" \
      --body "$body" \
      2> "$tmp_stderr")"
    rc=$?
    set -e
    if [[ $rc -ne 0 ]]; then
      echo "retro-file-proposed-edits: gh issue create failed on $repo: $(cat "$tmp_stderr")" >&2
      exit 1
    fi
    issue_num="$(printf '%s' "$url" | grep -oE '/issues/[0-9]+$' | grep -oE '[0-9]+$' || true)"
    if [[ -n "$issue_num" ]]; then
      for l in "${labels[@]}"; do
        set +e
        "$GH_BIN" api --method POST "/repos/$repo/issues/$issue_num/labels" -f "labels[]=$l" >/dev/null 2>&1
        label_rc=$?
        set -e
        if [[ $label_rc -ne 0 ]]; then
          # Label apply failed — try to create the label first, retry once.
          "$GH_BIN" label create "$l" --repo "$repo" --color "ededed" --description "auto-created by retro-file-proposed-edits" >/dev/null 2>&1 || true
          "$GH_BIN" api --method POST "/repos/$repo/issues/$issue_num/labels" -f "labels[]=$l" >/dev/null 2>&1 \
            || echo "WARN: could not apply label '$l' to $url" >&2
        fi
      done
    fi
    printf 'FILED: %s\n' "$url"
    continue
  fi

  # Unknown failure — bail loud rather than silently skip.
  echo "retro-file-proposed-edits: gh issue create failed on $repo: $err" >&2
  exit 1
done

exit 0

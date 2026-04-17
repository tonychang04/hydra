#!/usr/bin/env bash
#
# merge-policy-lookup.sh — resolve the effective merge policy for a repo/tier pair.
#
# Commander calls this before acting on `merge #N`. It's the single source of
# truth for per-repo overrides — so CLAUDE.md, self-tests, and the future MCP
# merge dispatcher all agree on what auto vs gate vs refuse means.
#
# Usage:
#   merge-policy-lookup.sh <owner>/<name> <tier> [--repos-file <path>]
#
# Tier must be one of: T1, T2, T3.
#
# Output (stdout): one of `auto`, `auto_if_review_clean`, `human`, `never`.
#
# Resolution order:
#   1. T3 → always `never` (safety rail, no override).
#   2. Look up <owner>/<name> in repos[]. Exit 1 if not found.
#   3. If `merge_policy` is an object and the tier key exists, use it.
#   4. If `merge_policy` is the legacy string:
#        auto-t1    → T1: auto, T2: human
#        human-all  → T1: human, T2: human
#        refuse-all → T1: never, T2: never (T3 already handled above)
#   5. Otherwise fall through to policy.md defaults: T1 auto, T2 human.
#
# Exit codes:
#   0  success; policy printed on stdout
#   1  repo not found / bad state file / invalid tier in object form
#   2  usage error
#
# Spec: docs/specs/2026-04-17-per-repo-merge-policy.md

set -euo pipefail

usage() {
  cat <<'EOF'
Usage: merge-policy-lookup.sh <owner>/<name> <tier> [--repos-file <path>]

Arguments:
  <owner>/<name>      Repo slug as it appears in state/repos.json.
  <tier>              One of T1, T2, T3.

Options:
  --repos-file <path> Path to repos.json (default: state/repos.json).
  -h, --help          Show this help.

Output:
  One of: auto, auto_if_review_clean, human, never.

Exit codes:
  0 = found · 1 = repo not found / bad input · 2 = usage error
EOF
}

repos_file="state/repos.json"
slug=""
tier=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repos-file)
      [[ $# -ge 2 ]] || { echo "merge-policy-lookup: --repos-file needs a value" >&2; usage >&2; exit 2; }
      repos_file="$2"; shift 2
      ;;
    --repos-file=*)
      repos_file="${1#--repos-file=}"; shift
      ;;
    -h|--help)
      usage; exit 0
      ;;
    --)
      shift; break
      ;;
    -*)
      echo "merge-policy-lookup: unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
    *)
      if [[ -z "$slug" ]]; then
        slug="$1"
      elif [[ -z "$tier" ]]; then
        tier="$1"
      else
        echo "merge-policy-lookup: too many positional args" >&2
        exit 2
      fi
      shift
      ;;
  esac
done

if [[ -z "$slug" || -z "$tier" ]]; then
  echo "merge-policy-lookup: <owner>/<name> and <tier> are both required" >&2
  usage >&2
  exit 2
fi

case "$tier" in
  T1|T2|T3) ;;
  *)
    echo "merge-policy-lookup: invalid tier '$tier' (expected T1, T2, or T3)" >&2
    exit 2
    ;;
esac

# Safety rail #1: T3 is hardcoded `never` regardless of override. Do NOT even
# read the repos file for this — we want a deterministic answer even if the
# file is malformed. See ticket #20 out-of-scope note: T3 override is refused.
if [[ "$tier" == "T3" ]]; then
  echo "never"
  exit 0
fi

if [[ ! -f "$repos_file" ]]; then
  echo "merge-policy-lookup: repos file not found: $repos_file" >&2
  exit 1
fi

command -v jq >/dev/null 2>&1 || {
  echo "merge-policy-lookup: jq not found on PATH" >&2
  exit 1
}

if ! jq empty "$repos_file" >/dev/null 2>&1; then
  echo "merge-policy-lookup: $repos_file is not valid JSON" >&2
  exit 1
fi

# Split slug.
owner="${slug%%/*}"
name="${slug#*/}"
if [[ -z "$owner" || -z "$name" || "$owner" == "$slug" ]]; then
  echo "merge-policy-lookup: slug must be <owner>/<name> (got '$slug')" >&2
  exit 2
fi

# Find the matching repo entry. `first(.repos[] | select(...))` returns empty
# if not found; `-e` makes jq exit 1 on null/false so we can branch on it.
entry="$(jq -c --arg o "$owner" --arg n "$name" \
  '.repos // [] | map(select(.owner == $o and .name == $n)) | .[0] // empty' \
  "$repos_file")"

if [[ -z "$entry" ]]; then
  echo "merge-policy-lookup: repo not found in $repos_file: $slug" >&2
  exit 1
fi

# Resolve the override (if any).
mp_type="$(jq -r 'if has("merge_policy") then (.merge_policy | type) else "absent" end' <<<"$entry")"

case "$mp_type" in
  object)
    # Object form. Look up the tier key; fall through to default if absent.
    mp_val="$(jq -r --arg t "$tier" '.merge_policy[$t] // empty' <<<"$entry")"
    if [[ -n "$mp_val" ]]; then
      echo "$mp_val"
      exit 0
    fi
    ;;
  string)
    legacy="$(jq -r '.merge_policy' <<<"$entry")"
    case "$legacy" in
      auto-t1)
        # Pre-#20 "allow T1 auto-merge, everything else human". T3 is handled above.
        if [[ "$tier" == "T1" ]]; then
          echo "auto"
        else
          echo "human"
        fi
        exit 0
        ;;
      human-all)
        echo "human"; exit 0
        ;;
      refuse-all)
        echo "never"; exit 0
        ;;
      *)
        echo "merge-policy-lookup: unknown legacy merge_policy '$legacy' for $slug" >&2
        exit 1
        ;;
    esac
    ;;
  absent)
    : # Fall through to defaults.
    ;;
  *)
    echo "merge-policy-lookup: merge_policy on $slug has unexpected type '$mp_type'" >&2
    exit 1
    ;;
esac

# Fallthrough: global policy.md defaults.
#   T1 → auto  (policy.md "Tier 1 — auto-merge eligible")
#   T2 → human (operator's summary: pre-ticket default; policy.md's review-clean
#               auto-merge behavior only activates when override explicitly says so)
case "$tier" in
  T1) echo "auto" ;;
  T2) echo "human" ;;
esac

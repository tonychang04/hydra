#!/usr/bin/env bash
#
# merge-policy-lookup.sh — resolve the effective merge policy for a repo/tier pair.
#
# Commander calls this before acting on `merge #N`. It's the single source of
# truth for per-repo overrides — so CLAUDE.md, self-tests, and the future MCP
# merge dispatcher all agree on what auto vs gate vs refuse means.
#
# Usage:
#   merge-policy-lookup.sh <owner>/<name> <tier> [--repos-file <path>] [--queue]
#
# Tier must be one of: T1, T2, T3.
#
# Output (stdout): one of `auto`, `auto_if_review_clean`, `human`, `never`.
# With --queue: if the resolved policy is `auto` or `auto_if_review_clean`
# AND the repo entry has `merge_queue_enabled: true`, prefixes the output
# with `queue:` (e.g. `queue:auto`). Otherwise emits the unprefixed policy.
# Commander reads this to decide between `--merge-queue --squash` and the
# legacy `--squash --auto` flow.
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
# Specs:
#   docs/specs/2026-04-17-per-repo-merge-policy.md (ticket #20)
#   docs/specs/2026-04-17-merge-queue.md (ticket #154 — --queue mode)

set -euo pipefail

usage() {
  cat <<'EOF'
Usage: merge-policy-lookup.sh <owner>/<name> <tier> [--repos-file <path>] [--queue]

Arguments:
  <owner>/<name>      Repo slug as it appears in state/repos.json.
  <tier>              One of T1, T2, T3.

Options:
  --repos-file <path> Path to repos.json (default: state/repos.json).
  --queue             Queue-aware mode. If the resolved policy is auto or
                      auto_if_review_clean AND the repo entry has
                      merge_queue_enabled:true, prefixes output with
                      `queue:` (e.g. queue:auto). Otherwise output is
                      unchanged. Commander uses this to branch between
                      `gh pr merge --merge-queue --squash` and the
                      legacy `--squash --auto` flow.
  -h, --help          Show this help.

Output:
  One of: auto, auto_if_review_clean, human, never.
  With --queue also: queue:auto, queue:auto_if_review_clean.

Exit codes:
  0 = found · 1 = repo not found / bad input · 2 = usage error
EOF
}

repos_file="state/repos.json"
slug=""
tier=""
queue_mode=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repos-file)
      [[ $# -ge 2 ]] || { echo "merge-policy-lookup: --repos-file needs a value" >&2; usage >&2; exit 2; }
      repos_file="$2"; shift 2
      ;;
    --repos-file=*)
      repos_file="${1#--repos-file=}"; shift
      ;;
    --queue)
      queue_mode=1; shift
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

# emit <policy> [<merge_queue_enabled>] — prints the resolved policy, applying
# the `queue:` prefix when --queue mode is on AND the repo has merge_queue_enabled
# AND the policy is auto* (queue mode only makes sense for auto-merging tiers).
# `never` and `human` are NEVER queue-prefixed — they're terminal states that
# should not route into --merge-queue on the Commander side. Ticket #154.
emit() {
  local policy="$1"
  local mq_enabled="${2:-false}"
  if [[ "$queue_mode" == "1" && "$mq_enabled" == "true" ]]; then
    case "$policy" in
      auto|auto_if_review_clean)
        printf 'queue:%s\n' "$policy"
        return
        ;;
    esac
  fi
  printf '%s\n' "$policy"
}

# Safety rail #1: T3 is hardcoded `never` regardless of override. Do NOT even
# read the repos file for this — we want a deterministic answer even if the
# file is malformed. See ticket #20 out-of-scope note: T3 override is refused.
# `never` is never queue-prefixed (emit() enforces that), so --queue is inert.
if [[ "$tier" == "T3" ]]; then
  emit "never"
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

# Ticket #154: per-repo opt-in for GitHub merge queue. Read once; passed to every
# emit() call below. Absent / non-boolean / false → "false". Schema guarantees
# a boolean when present, but default to "false" for any edge case (legacy
# repos.json files from before #154 have no such key at all).
mq_enabled="$(jq -r 'if (.merge_queue_enabled // false) == true then "true" else "false" end' <<<"$entry")"

# Resolve the override (if any).
mp_type="$(jq -r 'if has("merge_policy") then (.merge_policy | type) else "absent" end' <<<"$entry")"

case "$mp_type" in
  object)
    # Object form. Look up the tier key; fall through to default if absent.
    mp_val="$(jq -r --arg t "$tier" '.merge_policy[$t] // empty' <<<"$entry")"
    if [[ -n "$mp_val" ]]; then
      emit "$mp_val" "$mq_enabled"
      exit 0
    fi
    ;;
  string)
    legacy="$(jq -r '.merge_policy' <<<"$entry")"
    case "$legacy" in
      auto-t1)
        # Pre-#20 "allow T1 auto-merge, everything else human". T3 is handled above.
        if [[ "$tier" == "T1" ]]; then
          emit "auto" "$mq_enabled"
        else
          emit "human" "$mq_enabled"
        fi
        exit 0
        ;;
      human-all)
        emit "human" "$mq_enabled"; exit 0
        ;;
      refuse-all)
        emit "never" "$mq_enabled"; exit 0
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
  T1) emit "auto" "$mq_enabled" ;;
  T2) emit "human" "$mq_enabled" ;;
esac

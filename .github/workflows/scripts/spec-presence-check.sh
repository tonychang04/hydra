#!/usr/bin/env bash
#
# spec-presence-check.sh — enforce the spec-driven rule from DEVELOPING.md.
#
# If the PR diff touches any framework file, the same PR MUST include
# a new or modified file at docs/specs/YYYY-MM-DD-*.md. Escape hatch:
# a PR with the `trivial` label bypasses the check.
#
# Framework files (any change to one of these requires a spec):
#   - CLAUDE.md
#   - policy.md
#   - budget.json
#   - .claude/agents/*.md
#   - .claude/settings.local.json.example
#
# Required env:
#   PR_NUMBER — the pull request number
#   BASE_REF  — the base branch (e.g. main) — used for the diff range
#   GH_TOKEN  — GitHub token with read access (default GITHUB_TOKEN works)
#
# Spec: docs/specs/2026-04-16-ci.md (ticket #16 / T2)

set -euo pipefail

: "${PR_NUMBER:?PR_NUMBER is required}"
: "${GH_TOKEN:?GH_TOKEN is required}"
BASE_REF="${BASE_REF:-main}"

# -----------------------------------------------------------------------------
# Determine the diff range. `actions/checkout@v4` with fetch-depth: 0 gives us
# full history; origin/<base-ref> should exist. Fall back to HEAD~ if not.
# -----------------------------------------------------------------------------
if git rev-parse --verify "origin/$BASE_REF" >/dev/null 2>&1; then
  merge_base="$(git merge-base "origin/$BASE_REF" HEAD)"
elif git rev-parse --verify "$BASE_REF" >/dev/null 2>&1; then
  merge_base="$(git merge-base "$BASE_REF" HEAD)"
else
  echo "spec-presence: can't find $BASE_REF; falling back to HEAD~" >&2
  merge_base="$(git rev-parse HEAD~ 2>/dev/null || git rev-parse HEAD)"
fi

changed=()
while IFS= read -r line; do
  changed+=("$line")
done < <(git diff --name-only "$merge_base"...HEAD)

if [[ ${#changed[@]} -eq 0 ]]; then
  echo "spec-presence: no changed files against $BASE_REF — nothing to enforce"
  exit 0
fi

echo "spec-presence: diff range ${merge_base}..HEAD (${#changed[@]} files)"

# -----------------------------------------------------------------------------
# Did this PR touch any framework file?
# -----------------------------------------------------------------------------
is_framework_file() {
  local f="$1"
  case "$f" in
    CLAUDE.md|policy.md|budget.json) return 0 ;;
    .claude/agents/*.md) return 0 ;;
    .claude/settings.local.json.example) return 0 ;;
  esac
  return 1
}

framework_touched=()
spec_touched=()
for f in "${changed[@]}"; do
  if is_framework_file "$f"; then
    framework_touched+=("$f")
  fi
  # Match docs/specs/YYYY-MM-DD-*.md but not README.md / TEMPLATE.md.
  if [[ "$f" =~ ^docs/specs/[0-9]{4}-[0-9]{2}-[0-9]{2}-.+\.md$ ]]; then
    spec_touched+=("$f")
  fi
done

if [[ ${#framework_touched[@]} -eq 0 ]]; then
  echo "spec-presence: no framework files touched — check not required"
  exit 0
fi

echo "spec-presence: framework files touched:"
printf '  - %s\n' "${framework_touched[@]}"

# -----------------------------------------------------------------------------
# Check for the `trivial` label on the PR (escape hatch).
# -----------------------------------------------------------------------------
labels_json="$(gh pr view "$PR_NUMBER" --json labels 2>/dev/null || echo '{"labels":[]}')"
has_trivial="$(jq -r '[.labels[].name] | any(. == "trivial")' <<<"$labels_json")"

if [[ "$has_trivial" == "true" ]]; then
  echo "spec-presence: PR #$PR_NUMBER has label 'trivial' — bypassing spec check"
  exit 0
fi

# -----------------------------------------------------------------------------
# Framework files touched without a label bypass → spec MUST be present.
# -----------------------------------------------------------------------------
if [[ ${#spec_touched[@]} -eq 0 ]]; then
  echo "::error::Framework-file change without a spec. Add docs/specs/<YYYY-MM-DD>-<slug>.md per DEVELOPING.md."
  echo
  echo "Files triggering this check:"
  printf '  - %s\n' "${framework_touched[@]}"
  echo
  echo "To bypass (for truly trivial changes — typos, whitespace, comments):"
  echo "  gh pr edit $PR_NUMBER --add-label trivial"
  exit 1
fi

echo "spec-presence: spec present — OK"
printf '  - %s\n' "${spec_touched[@]}"

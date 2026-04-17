#!/usr/bin/env bash
# gh-filings.sh — file the three hello-hydra-demo fixture issues against the
# operator's fork via the `gh` CLI.
#
# Usage:
#   ./gh-filings.sh <your-fork-owner>/<your-fork-name>
#
# Example:
#   ./gh-filings.sh alice/hello-hydra-demo
#
# This script is IDEMPOTENT: if an issue with the same title already exists on
# the target repo, it is skipped (nothing is re-filed, nothing is duplicated).
# It calls `gh issue create` with --assignee @me so Commander's default
# assignee-trigger picks them up immediately.
#
# Prereqs:
#   - `gh` installed and authenticated (`gh auth status` green).
#   - The target repo exists and you have issue-write access.
#
# This script does NOT run automatically — it only fires when the operator
# invokes it. The PR that introduces this script does not file any issues.

set -euo pipefail

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  cat <<EOF
Usage: $0 <your-fork-owner>/<your-fork-name>

Files the 3 fixture issues from ./fixture-issues/ against the given repo,
assigning each to the current gh-auth'd user. Idempotent — existing titles
are skipped.
EOF
  exit 0
fi

if [[ $# -lt 1 ]]; then
  echo "error: missing repo argument" >&2
  echo "usage: $0 <owner>/<repo>" >&2
  exit 2
fi

REPO="$1"

# Validate shape
if ! [[ "$REPO" =~ ^[^/]+/[^/]+$ ]]; then
  echo "error: '$REPO' is not in owner/repo shape" >&2
  exit 2
fi

# Preflight
if ! command -v gh >/dev/null 2>&1; then
  echo "error: gh CLI not found. Install from https://cli.github.com/ first." >&2
  exit 127
fi

if ! gh auth status >/dev/null 2>&1; then
  echo "error: gh is not authenticated. Run 'gh auth login' first." >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FIXTURE_DIR="${SCRIPT_DIR}/fixture-issues"

if [[ ! -d "$FIXTURE_DIR" ]]; then
  echo "error: fixture-issues directory not found at $FIXTURE_DIR" >&2
  exit 1
fi

# Extract the title from a fixture markdown file's YAML-ish frontmatter.
# Strict: title MUST be declared as `title: "..."` inside a leading --- block.
extract_title() {
  local file="$1"
  awk '
    BEGIN { in_fm = 0; fm_seen = 0 }
    /^---[[:space:]]*$/ {
      if (in_fm == 0 && fm_seen == 0) { in_fm = 1; fm_seen = 1; next }
      if (in_fm == 1) { exit }
    }
    in_fm == 1 && /^title:/ {
      sub(/^title:[[:space:]]*/, "")
      gsub(/^"/, ""); gsub(/"$/, "")
      print
      exit
    }
  ' "$file"
}

# Return the body of a fixture file (everything after the closing --- of
# the frontmatter block). That's what we send to `gh issue create --body-file`.
extract_body_to() {
  local file="$1"
  local out="$2"
  awk '
    BEGIN { in_fm = 0; fm_seen = 0; past_fm = 0 }
    past_fm == 1 { print; next }
    /^---[[:space:]]*$/ {
      if (in_fm == 0 && fm_seen == 0) { in_fm = 1; fm_seen = 1; next }
      if (in_fm == 1) { in_fm = 0; past_fm = 1; next }
    }
  ' "$file" > "$out"
}

issue_exists() {
  local repo="$1"
  local title="$2"
  # gh issue list supports JSON output; exact-match on title.
  gh issue list --repo "$repo" --state all --search "in:title \"$title\"" --limit 10 --json title \
    | grep -Fq "\"title\":\"$title\""
}

declare -a CREATED_URLS=()
declare -a SKIPPED_TITLES=()

# Iterate sorted so 01, 02, 03 go in a predictable order.
for fixture in $(ls -1 "$FIXTURE_DIR"/*.md | sort); do
  title="$(extract_title "$fixture")"
  if [[ -z "$title" ]]; then
    echo "warn: could not parse title from $fixture — skipping" >&2
    continue
  fi

  if issue_exists "$REPO" "$title"; then
    echo "skip: issue with title '$title' already exists on $REPO"
    SKIPPED_TITLES+=("$title")
    continue
  fi

  body_tmp="$(mktemp)"
  extract_body_to "$fixture" "$body_tmp"

  url=$(gh issue create \
    --repo "$REPO" \
    --title "$title" \
    --body-file "$body_tmp" \
    --assignee "@me")

  rm -f "$body_tmp"

  CREATED_URLS+=("$url")
  echo "created: $url"
done

echo ""
echo "summary:"
echo "  repo:    $REPO"
echo "  created: ${#CREATED_URLS[@]}"
echo "  skipped: ${#SKIPPED_TITLES[@]}"

if [[ "${#CREATED_URLS[@]}" -gt 0 ]]; then
  echo ""
  echo "new issue URLs:"
  for url in "${CREATED_URLS[@]}"; do
    echo "  $url"
  done
fi

if [[ "${#SKIPPED_TITLES[@]}" -gt 0 ]]; then
  echo ""
  echo "already present (not re-filed):"
  for t in "${SKIPPED_TITLES[@]}"; do
    echo "  $t"
  done
fi

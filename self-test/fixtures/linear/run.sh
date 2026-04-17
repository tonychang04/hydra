#!/usr/bin/env bash
#
# run.sh — self-test for scripts/linear-poll.sh against the fixture mock.
# Invoked from `self-test/golden-cases.example.json` case id `linear-mcp-contract`,
# and runnable standalone: `bash self-test/fixtures/linear/run.sh`.
#
# Exercises the fixture-mode path (no Linear MCP required) and validates:
#   - Exit code 0
#   - Normalized output has 3 issues
#   - Identifiers match the mock
#   - States preserved verbatim (Todo / In Progress / Ready for Hydra)
#   - Assignee and labels flattened correctly
#   - "source" field equals "fixture"

set -euo pipefail

# Resolve repo root (two levels up from this file).
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/../../.." && pwd)"
script="$repo_root/scripts/linear-poll.sh"
fixture="$here/mock-list-issues-response.json"

fail() { echo "FAIL: $1" >&2; exit 1; }

[[ -x "$script" ]] || fail "scripts/linear-poll.sh not executable"
[[ -f "$fixture" ]] || fail "fixture missing: $fixture"
command -v jq >/dev/null || fail "jq required"

# Run it.
if ! out="$("$script" --fixture "$fixture" 2>/tmp/linear-poll-test.err)"; then
  cat /tmp/linear-poll-test.err >&2
  fail "linear-poll.sh exited non-zero on fixture"
fi

# Must be valid JSON.
if ! echo "$out" | jq -e . >/dev/null 2>&1; then
  echo "$out"
  fail "linear-poll.sh output is not valid JSON"
fi

# Count == 3.
count="$(echo "$out" | jq -r '.count')"
[[ "$count" == "3" ]] || fail "expected count=3, got $count"

# source == fixture.
source_val="$(echo "$out" | jq -r '.source')"
[[ "$source_val" == "fixture" ]] || fail "expected source=fixture, got $source_val"

# Identifiers in order.
ids="$(echo "$out" | jq -r '.issues | map(.identifier) | join(",")')"
[[ "$ids" == "ENG-101,ENG-102,ENG-103" ]] || fail "unexpected identifiers: $ids"

# States preserved.
states="$(echo "$out" | jq -r '.issues | map(.state) | join("|")')"
[[ "$states" == "Todo|In Progress|Ready for Hydra" ]] || fail "unexpected states: $states"

# Assignee flattened.
first_assignee="$(echo "$out" | jq -r '.issues[0].assignee')"
[[ "$first_assignee" == "operator@example.com" ]] || fail "unexpected assignee[0]: $first_assignee"

# Labels flattened into string arrays.
labels0="$(echo "$out" | jq -r '.issues[0].labels | join(",")')"
[[ "$labels0" == "backend,ready-for-hydra" ]] || fail "unexpected labels[0]: $labels0"

# URL preserved.
url0="$(echo "$out" | jq -r '.issues[0].url')"
[[ "$url0" == https://linear.app/* ]] || fail "expected issues[0].url to start with https://linear.app/, got $url0"

echo "OK: linear-poll.sh --fixture parses mock response correctly (3 issues, states preserved, labels + assignee flattened)"

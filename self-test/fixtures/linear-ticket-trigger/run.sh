#!/usr/bin/env bash
#
# run.sh — self-test for scripts/linear-pickup-dispatch.sh.
#
# Simulates the full pickup path for the Linear ticket trigger:
#   - Fixture config (state/linear.json equivalent) has enabled=true, one team.
#   - Fixture poll response has 3 issues: 2 ready + 1 in a commander-managed
#     state ('In Progress', matching state_transitions.on_pickup).
#   - After pickup-dispatch filters, exactly 2 tickets come back.
#
# Runs locally, no Linear MCP required. Invoked by:
#   - the linear-ticket-trigger golden case (when added)
#   - operators validating the #140 change:
#         bash self-test/fixtures/linear-ticket-trigger/run.sh
#
# Spec: docs/specs/2026-04-17-linear-ticket-trigger.md

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/../../.." && pwd)"
script="$repo_root/scripts/linear-pickup-dispatch.sh"
config="$here/linear-fixture-config.json"
poll="$here/poll-output-2-ready-1-working.json"

fail() { echo "FAIL: $1" >&2; exit 1; }

[[ -x "$script" ]] || fail "scripts/linear-pickup-dispatch.sh not executable"
[[ -f "$config" ]] || fail "fixture config missing: $config"
[[ -f "$poll"   ]] || fail "fixture poll missing: $poll"
command -v jq >/dev/null || fail "jq required"

# Invoke with fixture flags so no live MCP call is made.
if ! out="$("$script" --config "$config" --fixture-poll "$poll" 2>/tmp/linear-pickup-dispatch-test.err)"; then
  cat /tmp/linear-pickup-dispatch-test.err >&2
  fail "linear-pickup-dispatch.sh exited non-zero"
fi

# Output must be valid JSON.
if ! echo "$out" | jq -e . >/dev/null 2>&1; then
  echo "$out"
  fail "linear-pickup-dispatch.sh output is not valid JSON"
fi

# Must be an array.
kind="$(echo "$out" | jq -r 'type')"
[[ "$kind" == "array" ]] || fail "expected top-level array, got $kind"

# Must be length 2 (3 input issues minus 1 in 'In Progress').
len="$(echo "$out" | jq 'length')"
[[ "$len" == "2" ]] || fail "expected exactly 2 dispatched tickets, got $len"

# Dispatched identifiers must be ENG-200 and ENG-201 (ENG-202 filtered).
ids="$(echo "$out" | jq -r 'map(.issue.identifier) | sort | join(",")')"
[[ "$ids" == "ENG-200,ENG-201" ]] || fail "expected ENG-200,ENG-201 — got $ids"

# The filtered-out ticket must NOT appear.
if echo "$out" | jq -e 'any(.[]; .issue.identifier == "ENG-202")' >/dev/null; then
  fail "ENG-202 (In Progress) leaked through the commander-managed-state filter"
fi

# Envelope shape sanity: team_id, trigger.type, issue.url all populated.
team_ids="$(echo "$out" | jq -r 'map(.team_id) | unique | join(",")')"
[[ "$team_ids" == "team-uuid-eng" ]] || fail "unexpected team_id(s): $team_ids"

trigger_types="$(echo "$out" | jq -r 'map(.trigger.type) | unique | join(",")')"
[[ "$trigger_types" == "assignee" ]] || fail "unexpected trigger type(s): $trigger_types"

# Worker-prompt contract (AC #4 of ticket #140): the Linear URL and body
# must be present on each dispatched issue. Workers use these to populate
# the PR body's "Closes LIN-123 — <url>" line and to understand the ticket.
for i in 0 1; do
  url="$(echo "$out" | jq -r ".[$i].issue.url")"
  [[ "$url" == https://linear.app/* ]] || fail "dispatched[$i].issue.url malformed: $url"

  desc="$(echo "$out" | jq -r ".[$i].issue.description")"
  [[ -n "$desc" && "$desc" != "null" ]] || fail "dispatched[$i].issue.description missing — worker won't see ticket body"
done

# Master-switch behavior: enabled=false → empty array.
tmp_disabled="$(mktemp)"
jq '.enabled = false' "$config" > "$tmp_disabled"
disabled_out="$("$script" --config "$tmp_disabled" --fixture-poll "$poll")"
rm -f "$tmp_disabled"
disabled_kind="$(echo "$disabled_out" | jq -r 'type')"
disabled_len="$(echo "$disabled_out" | jq 'length')"
[[ "$disabled_kind" == "array" && "$disabled_len" == "0" ]] || \
    fail "enabled=false should yield empty array; got kind=$disabled_kind len=$disabled_len"

# Missing config: also empty array, not an error (operator hasn't configured
# Linear, pickup loop should keep running for GitHub-triggered repos).
missing_out="$("$script" --config /nonexistent/path/linear.json --fixture-poll "$poll")"
missing_kind="$(echo "$missing_out" | jq -r 'type')"
missing_len="$(echo "$missing_out" | jq 'length')"
[[ "$missing_kind" == "array" && "$missing_len" == "0" ]] || \
    fail "missing config should yield empty array; got kind=$missing_kind len=$missing_len"

echo "OK: linear-pickup-dispatch.sh correctly dispatches 2 of 3 fixture tickets (1 filtered as commander-managed)"

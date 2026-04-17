#!/usr/bin/env bash
#
# linear-pickup-dispatch.sh — Commander's pickup-dispatch pass for the Linear
# ticket trigger. Turns (state/linear.json config, per-team linear-poll.sh
# output) into a normalized list of "ready" tickets Commander can feed
# straight into the worker-implementation spawn loop.
#
# Responsibilities (see docs/specs/2026-04-17-linear-ticket-trigger.md):
#
#   1. Read state/linear.json (or --config <path> for tests).
#   2. Bail early if enabled=false.
#   3. For each team in teams[]:
#        - Invoke scripts/linear-poll.sh with the team's trigger, OR read
#          a --fixture-poll <path> file in test mode.
#        - Filter out tickets already in a commander-managed state
#          (state_transitions values plus per-team state_name_mapping
#          overrides). Same idempotency semantics as GitHub's skip-if-labeled.
#   4. Emit a JSON array on stdout:
#        [
#          {
#            "team_id":   "...",
#            "team_name": "...",
#            "trigger":   {"type":"assignee","value":"..."},
#            "issue":     { id, identifier, title, description, state, url, ... }
#          },
#          ...
#        ]
#
# The "one entry per ready ticket per team" shape is what Commander's pickup
# loop consumes — iteration can happen at the Commander level without caring
# about which team produced which issue.
#
# Exit codes:
#   0  success (zero or more tickets, always valid JSON on stdout)
#   1  linear-poll.sh failed for at least one team
#   2  usage / config malformed / jq missing
#   3  Linear MCP server not installed (propagated from linear-poll.sh)
#
# Fixture / live mode selection:
#   - Default: live mode. Calls linear-poll.sh per team without --fixture.
#   - --fixture-poll <path>: reads the poll response from disk for every
#     team (same file reused). Used by self-test/fixtures/linear-ticket-trigger/
#     and by operators who want a dry run without hitting Linear.
#
# Spec: docs/specs/2026-04-17-linear-ticket-trigger.md
# Contract for linear-poll.sh: docs/linear-tool-contract.md

set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  linear-pickup-dispatch.sh [options]

Options:
  --config <path>          Path to state/linear.json (default: state/linear.json)
  --fixture-poll <path>    Use a fixture instead of calling linear-poll.sh live.
                           The same fixture is used for every team in the config
                           — sufficient for the single-team common case and for
                           multi-team tests that seed a shared issue set.
  --first <n>              Cap per-team response size (passed to linear-poll.sh
                           in live mode; ignored in fixture mode). Default: 50.
  -h, --help               Show this help.

Exit codes:
  0 = success · 1 = poll failure · 2 = usage / malformed · 3 = MCP missing
EOF
}

# Resolve repo root so defaults work from anywhere.
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"

config_path=""
fixture_poll=""
first="50"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --config)       [[ $# -ge 2 ]] || { usage >&2; exit 2; }; config_path="$2"; shift 2;;
    --fixture-poll) [[ $# -ge 2 ]] || { usage >&2; exit 2; }; fixture_poll="$2"; shift 2;;
    --first)        [[ $# -ge 2 ]] || { usage >&2; exit 2; }; first="$2"; shift 2;;
    -h|--help)      usage; exit 0;;
    *) echo "linear-pickup-dispatch: unknown arg: $1" >&2; usage >&2; exit 2;;
  esac
done

if [[ -z "$config_path" ]]; then
  config_path="$ROOT_DIR/state/linear.json"
fi

# jq is a hard requirement everywhere Hydra touches JSON.
if ! command -v jq >/dev/null 2>&1; then
  echo "linear-pickup-dispatch: jq is required (brew install jq / apt-get install jq)" >&2
  exit 2
fi

# Missing config = operator hasn't set up Linear. Emit empty array, exit 0.
# This keeps the pickup loop quiet — no noise on GitHub-only installs.
if [[ ! -f "$config_path" ]]; then
  echo '[]'
  exit 0
fi

# Malformed config = preflight failure; bail loudly so Commander sees it.
if ! jq empty "$config_path" 2>/dev/null; then
  echo "linear-pickup-dispatch: $config_path is not valid JSON" >&2
  exit 2
fi

enabled="$(jq -r '.enabled // false' "$config_path")"
if [[ "$enabled" != "true" ]]; then
  # Operator disabled Linear via the master switch. Skip politely.
  echo '[]'
  exit 0
fi

# Poll script sits next to us.
poll_script="$SCRIPT_DIR/linear-poll.sh"
if [[ ! -f "$poll_script" ]]; then
  echo "linear-pickup-dispatch: linear-poll.sh not found at $poll_script" >&2
  exit 2
fi

# Fixture file (if any) must exist before we iterate teams.
if [[ -n "$fixture_poll" ]] && [[ ! -f "$fixture_poll" ]]; then
  echo "linear-pickup-dispatch: --fixture-poll file not found: $fixture_poll" >&2
  exit 2
fi

# Build the set of "commander-managed states" — Linear equivalent of
# GitHub's commander-working / commander-pause / commander-stuck labels.
# Global state_transitions values go into the set; per-team state_name_mapping
# overrides extend it per-team (computed inside the loop below).
#
# Any null/empty entries are ignored. A team that hasn't populated
# state_name_mapping just uses the global set.
global_managed_states="$(jq -r '
  [.state_transitions // {} | to_entries[] | select(.value != null and .value != "") | .value]
' "$config_path")"

# Emit the final array. We collect per-team filtered issues then merge at the
# end, so the stdout is always exactly ONE well-formed JSON array even if no
# team yields any issues.
collected="[]"

team_count="$(jq '(.teams // []) | length' "$config_path")"
for (( t=0; t<team_count; t++ )); do
  team_id="$(jq -r ".teams[$t].team_id // \"\"" "$config_path")"
  team_name="$(jq -r ".teams[$t].team_name // \"\"" "$config_path")"
  trigger_type="$(jq -r ".teams[$t].trigger.type // \"assignee\"" "$config_path")"
  trigger_value="$(jq -r ".teams[$t].trigger.value // \"me\"" "$config_path")"

  if [[ -z "$team_id" ]]; then
    echo "linear-pickup-dispatch: teams[$t].team_id missing; skipping" >&2
    continue
  fi

  # Per-team managed states = global state_transitions ∪ this team's
  # state_name_mapping values (non-null).
  per_team_managed="$(jq -r \
      --argjson gms "$global_managed_states" \
      "
      [\$gms[]] +
      [
        (.teams[$t].state_name_mapping // {}) | to_entries[]
        | select(.value != null and .value != \"\")
        | .value
      ]
      | unique
      " \
      "$config_path")"

  # Invoke poll (fixture or live).
  if [[ -n "$fixture_poll" ]]; then
    if ! poll_out="$(bash "$poll_script" --fixture "$fixture_poll" 2>/tmp/linear-pickup-dispatch.err)"; then
      echo "linear-pickup-dispatch: linear-poll.sh (fixture) failed for team $team_id:" >&2
      cat /tmp/linear-pickup-dispatch.err >&2 || true
      exit 1
    fi
  else
    # Live mode — propagate the 3 exit (MCP missing) specifically.
    set +e
    poll_out="$(bash "$poll_script" \
        --team "$team_id" \
        --trigger-type "$trigger_type" \
        --trigger-value "$trigger_value" \
        --first "$first" \
        2>/tmp/linear-pickup-dispatch.err)"
    poll_ec=$?
    set -e
    if [[ $poll_ec -ne 0 ]]; then
      cat /tmp/linear-pickup-dispatch.err >&2 || true
      if [[ $poll_ec -eq 3 ]]; then exit 3; fi
      exit 1
    fi
  fi

  # Filter tickets whose state is in the per-team managed set. Wrap each
  # remaining issue in the dispatch envelope shape.
  team_entries="$(printf '%s' "$poll_out" | jq -c \
      --arg tid "$team_id" \
      --arg tname "$team_name" \
      --arg tt "$trigger_type" \
      --arg tv "$trigger_value" \
      --argjson managed "$per_team_managed" \
      '
      (.issues // [])
      | map(select(.state as $s | ($managed | index($s)) | not))
      | map({
          team_id:   $tid,
          team_name: $tname,
          trigger:   {type: $tt, value: $tv},
          issue:     .
        })
      ')"

  # Merge into collected.
  collected="$(jq -c -n --argjson a "$collected" --argjson b "$team_entries" '$a + $b')"
done

# Pretty-printed output is easier to eyeball in interactive use; jq . without
# -c gives us that. Commander downstream always pipes through jq anyway.
printf '%s\n' "$collected" | jq .

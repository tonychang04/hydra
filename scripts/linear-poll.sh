#!/usr/bin/env bash
#
# linear-poll.sh — wrap the Linear MCP "list issues" call for Commander's
# poll step. Returns a normalized JSON list of ready tickets that Commander
# can merge into its queue.
#
# Two modes:
#
#   1. Live mode (default): invokes the Linear MCP via
#      `claude mcp call linear <tool> <args-json>`. Requires the Linear
#      MCP server to be installed (see INSTALL.md "Linear" section).
#
#   2. Fixture mode: `--fixture <path>` reads a canned JSON response from
#      disk and parses it with the same normalization logic. Used by
#      self-test (self-test/fixtures/linear/) and by operators who want
#      to validate their state/linear.json shape without hitting Linear.
#
# The EXACT Linear MCP tool names / arg shapes are documented in
# docs/linear-tool-contract.md. If your Linear MCP install uses different
# names, override via env vars HYDRA_LINEAR_TOOL_LIST etc. (see below).
#
# Output: JSON on stdout of the form
#   {
#     "source":    "live" | "fixture",
#     "team_id":   "<team-id-or-unknown>",
#     "trigger":   {"type": "assignee|state|label", "value": "..."},
#     "issues":    [
#       {
#         "id":         "...",
#         "identifier": "ENG-123",
#         "title":      "...",
#         "state":      "Todo",
#         "assignee":   "operator@example.com",
#         "labels":     ["ready-for-hydra"],
#         "url":        "https://linear.app/..."
#       },
#       ...
#     ],
#     "count":     <int>
#   }
#
# Exit codes:
#   0  success (issues list may be empty if no matches)
#   1  Linear MCP call failed (network, auth, rate-limit) — stderr has details
#   2  usage / fixture file not found / malformed input
#   3  Linear MCP server not installed (live mode) — stderr has install hint

set -euo pipefail

# Tool name overrides — see docs/linear-tool-contract.md. If your Linear
# MCP install exposes different names, set these before invoking the script.
: "${HYDRA_LINEAR_TOOL_LIST:=linear_list_issues}"
: "${HYDRA_LINEAR_MCP_SERVER:=linear}"

usage() {
  cat <<'EOF'
Usage:
  linear-poll.sh --team <team-id> [--trigger-type assignee|state|label] [--trigger-value <val>]
  linear-poll.sh --fixture <path-to-fixture-json>
  linear-poll.sh --config <path-to-state/linear.json>   # (not yet implemented; placeholder)
  linear-poll.sh -h | --help

Options:
  --team <team-id>         Linear team ID to filter on (required in live mode)
  --trigger-type <t>       One of: assignee, state, label (default: assignee)
  --trigger-value <v>      Value for the trigger (default: "me" for assignee)
  --fixture <path>         Read response from a fixture JSON file instead of the MCP server
  --first <n>              Cap response size (default: 50)
  -h, --help               Show this message

Environment overrides (see docs/linear-tool-contract.md):
  HYDRA_LINEAR_TOOL_LIST   Name of the "list issues" tool (default: linear_list_issues)
  HYDRA_LINEAR_MCP_SERVER  MCP server name (default: linear)

Examples:
  # Fixture / self-test:
  linear-poll.sh --fixture self-test/fixtures/linear/mock-list-issues-response.json

  # Live:
  linear-poll.sh --team ABC123 --trigger-type assignee --trigger-value me
EOF
}

# --- parse args -------------------------------------------------------------

team_id=""
trigger_type="assignee"
trigger_value="me"
fixture_path=""
first="50"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --team)           [[ $# -ge 2 ]] || { usage >&2; exit 2; }; team_id="$2"; shift 2;;
    --trigger-type)   [[ $# -ge 2 ]] || { usage >&2; exit 2; }; trigger_type="$2"; shift 2;;
    --trigger-value)  [[ $# -ge 2 ]] || { usage >&2; exit 2; }; trigger_value="$2"; shift 2;;
    --fixture)        [[ $# -ge 2 ]] || { usage >&2; exit 2; }; fixture_path="$2"; shift 2;;
    --first)          [[ $# -ge 2 ]] || { usage >&2; exit 2; }; first="$2"; shift 2;;
    -h|--help)        usage; exit 0;;
    *) echo "linear-poll: unknown arg: $1" >&2; usage >&2; exit 2;;
  esac
done

case "$trigger_type" in
  assignee|state|label) ;;
  *) echo "linear-poll: --trigger-type must be one of: assignee, state, label" >&2; exit 2;;
esac

# jq is a hard requirement.
if ! command -v jq >/dev/null 2>&1; then
  echo "linear-poll: jq is required (brew install jq or apt-get install jq)" >&2
  exit 2
fi

# --- obtain the raw response -----------------------------------------------

raw_response=""
source_label=""

if [[ -n "$fixture_path" ]]; then
  if [[ ! -f "$fixture_path" ]]; then
    echo "linear-poll: fixture not found: $fixture_path" >&2
    exit 2
  fi
  if ! raw_response="$(jq -c . "$fixture_path" 2>/dev/null)"; then
    echo "linear-poll: fixture is not valid JSON: $fixture_path" >&2
    exit 2
  fi
  source_label="fixture"
else
  if [[ -z "$team_id" ]]; then
    echo "linear-poll: --team is required in live mode" >&2
    usage >&2
    exit 2
  fi

  if ! command -v claude >/dev/null 2>&1; then
    echo "linear-poll: 'claude' CLI not on PATH — install Claude Code first" >&2
    exit 3
  fi

  # Check the Linear MCP server is registered. We do NOT make the `claude mcp`
  # output format load-bearing — just grep for the server name.
  if ! claude mcp list 2>/dev/null | grep -qi "^${HYDRA_LINEAR_MCP_SERVER}\b"; then
    cat >&2 <<EOF
linear-poll: Linear MCP server ('${HYDRA_LINEAR_MCP_SERVER}') not installed.
Install with:
    claude mcp add linear
Then re-run this command. See INSTALL.md for the full flow.
EOF
    exit 3
  fi

  # Build the filter JSON per docs/linear-tool-contract.md.
  # Exactly ONE of assignee / state / labels is populated at a time.
  args_json="$(jq -n \
      --arg tid "$team_id" \
      --arg tt  "$trigger_type" \
      --arg tv  "$trigger_value" \
      --argjson first "$first" \
      '
      {
        filter: (
          {team: {id: $tid}}
          + (
              if   $tt == "assignee" then {assignee: {email: $tv}}
              elif $tt == "state"    then {state:    {name:  $tv}}
              elif $tt == "label"    then {labels:   {name:  {in: [$tv]}}}
              else {} end
            )
        ),
        first: $first
      }
      ')"

  # Invoke the MCP tool. If the `claude mcp call` subcommand isn't supported
  # on this version of Claude Code, fail loudly — operator needs to upgrade.
  if ! raw_response="$(claude mcp call "$HYDRA_LINEAR_MCP_SERVER" "$HYDRA_LINEAR_TOOL_LIST" "$args_json" 2>/tmp/linear-poll.err)"; then
    err="$(cat /tmp/linear-poll.err 2>/dev/null || true)"
    if echo "$err" | grep -qiE 'auth|unauthorized|401|403'; then
      echo "linear-poll: Linear MCP auth failed. Re-run: claude mcp add linear" >&2
    elif echo "$err" | grep -qiE 'rate|429|too many'; then
      echo "linear-poll: Linear MCP rate-limited. Back off and retry later." >&2
    else
      echo "linear-poll: Linear MCP call failed: $err" >&2
    fi
    exit 1
  fi
  source_label="live"
fi

# --- normalize --------------------------------------------------------------
#
# The Linear MCP response (assumed shape per docs/linear-tool-contract.md) has
# an "issues" array with rich per-issue objects. Flatten to Hydra's normalized
# shape so consumers (Commander itself, tests) don't care about Linear schema
# quirks.

normalized="$(printf '%s' "$raw_response" | jq \
    --arg src "$source_label" \
    --arg tid "${team_id:-unknown}" \
    --arg tt  "$trigger_type" \
    --arg tv  "$trigger_value" \
    '
    # Accept both {"issues": [...]} and bare [...] for maximum fixture flexibility.
    (if type == "object" then (.issues // []) else . end) as $raw
    | {
        source:  $src,
        team_id: $tid,
        trigger: {type: $tt, value: $tv},
        issues:  ($raw | map({
          id:         (.id // ""),
          identifier: (.identifier // ""),
          title:      (.title // ""),
          state:      ((.state // {}).name // ""),
          assignee:   ((.assignee // {}).email // ""),
          labels:     ((.labels // []) | map(.name)),
          url:        (.url // "")
        })),
        count:   ($raw | length)
      }
    ' 2>/tmp/linear-poll.jqerr)" || {
  echo "linear-poll: failed to parse MCP response: $(cat /tmp/linear-poll.jqerr 2>/dev/null)" >&2
  exit 1
}

printf '%s\n' "$normalized"

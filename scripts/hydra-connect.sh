#!/usr/bin/env bash
#
# hydra-connect.sh — one-command wizard for wiring external connectors.
#
# Usage: ./hydra connect <linear|slack|supervisor|digest> [options]
#        ./hydra connect --list
#        ./hydra connect --status [--quiet]
#        ./hydra connect --dry-run <connector>
#
# Spec: docs/specs/2026-04-17-connector-wizard.md (ticket #139)
# Spec: docs/specs/2026-04-17-daily-digest.md (ticket #144, digest subcommand)
#
# Mirrors the style of:
#   scripts/hydra-add-repo.sh         (interactive wizard pattern)
#   scripts/hydra-mcp-register-agent.sh (token / sha256 / atomic-write pattern)
#   scripts/hydra-doctor.sh           (--status health-check pattern)
#
# Hard rules:
#   - set -euo pipefail
#   - Bash + jq only (no Python / Node)
#   - Atomic writes (tmp in same dir + mv)
#   - Every write schema-validates BEFORE the mv via scripts/validate-state.sh
#   - Never edits CLAUDE.md, policy.md, budget.json, .claude/settings.local.json,
#     or any worker subagent
#   - --dry-run NEVER writes anywhere, never calls `claude mcp add`

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"

# shellcheck disable=SC1091
[[ -f "$ROOT_DIR/.hydra.env" ]] && source "$ROOT_DIR/.hydra.env"

usage() {
  cat <<'EOF'
Usage: ./hydra connect <linear|slack|supervisor|digest> [options]
       ./hydra connect --list
       ./hydra connect --status [--quiet]
       ./hydra connect --dry-run <connector>

One-command wizard for wiring external connectors to Commander. Interactive
by default; re-runs show current config and let you update individual fields.

Subcommands:
  linear          Wire Linear MCP integration (state/linear.json)
  slack           Wire Hydra's Slack bot (state/connectors/slack.json)
  supervisor      Wire the outbound MCP upstream supervisor
                  (state/connectors/mcp.json:upstream_supervisor)
  digest          Subscribe a channel to the daily status digest
                  (state/digests.json). See docs/specs/2026-04-17-daily-digest.md.

Flags:
  --list          List all supported connectors + install state. Exit 0.
  --status        Live health check. Parses `claude mcp list` + config state.
                  Exit 0 if all OK or disabled; exit 1 if any connector is
                  broken. --quiet prints a single summary line (used by
                  Commander's session greeting).
  --quiet         Modifier for --status. Single-line summary only.
  --dry-run       Preview the JSON that would be written; do not write.
                  Skips any `claude mcp add` step.
  --non-interactive
                  Never prompt. Use defaults or existing values for every
                  field. Fails with exit 2 if a required field has no
                  default and no existing value.
  -h, --help      Show this help

Environment overrides (for self-test fixtures):
  HYDRA_CONNECT_LINEAR_FILE        Override state/linear.json path
  HYDRA_CONNECT_SLACK_FILE         Override state/connectors/slack.json path
  HYDRA_CONNECT_MCP_FILE           Override state/connectors/mcp.json path
  HYDRA_CONNECT_DIGEST_FILE        Override state/digests.json path
  HYDRA_CONNECT_FAKE_MCP_LIST      Path to a file whose contents replace
                                   `claude mcp list` stdout. Used by --status
                                   tests so they don't need a real MCP client.
  NO_COLOR=1                       Disable ANSI color even on a TTY.

Exit codes:
  0   success (wizard completed, --list / --status OK, --dry-run valid)
  1   I/O / validation error, or --status found broken connectors
  2   usage error (unknown subcommand, missing required field in
      --non-interactive mode)

Examples:
  ./hydra connect linear                      # interactive wizard
  ./hydra connect digest                      # subscribe daily digest
  ./hydra connect digest stdout               # short-form: channel as arg
  ./hydra connect --dry-run supervisor        # preview; no write
  ./hydra connect --list                      # what connectors exist?
  ./hydra connect --status                    # are they healthy?
  ./hydra connect --status --quiet            # one-line summary
EOF
}

# -----------------------------------------------------------------------------
# color (same pattern as hydra-add-repo / hydra-doctor)
# -----------------------------------------------------------------------------
if [[ -t 1 ]] && [[ "${NO_COLOR:-}" != "1" ]]; then
  C_GREEN=$'\033[32m'
  C_RED=$'\033[31m'
  C_YELLOW=$'\033[33m'
  C_DIM=$'\033[2m'
  C_BOLD=$'\033[1m'
  C_RESET=$'\033[0m'
else
  C_GREEN=""; C_RED=""; C_YELLOW=""; C_DIM=""; C_BOLD=""; C_RESET=""
fi

err()  { printf "%s✗%s %s\n" "$C_RED"    "$C_RESET" "$*" >&2; }
ok()   { printf "%s✓%s %s\n" "$C_GREEN"  "$C_RESET" "$*" >&2; }
warn() { printf "%s⚠%s %s\n" "$C_YELLOW" "$C_RESET" "$*" >&2; }
info() { printf "%s▸%s %s\n" "$C_BOLD"   "$C_RESET" "$*" >&2; }

# -----------------------------------------------------------------------------
# arg parse
# -----------------------------------------------------------------------------
subcommand=""
mode=""              # "wizard" | "list" | "status" | "dry-run"
non_interactive=0
quiet=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --list)
      if [[ -n "$mode" ]]; then err "only one mode flag allowed"; exit 2; fi
      mode="list"; shift ;;
    --status)
      if [[ -n "$mode" ]]; then err "only one mode flag allowed"; exit 2; fi
      mode="status"; shift ;;
    --quiet) quiet=1; shift ;;
    --dry-run)
      if [[ -n "$mode" ]]; then err "only one mode flag allowed"; exit 2; fi
      mode="dry-run"; shift ;;
    --non-interactive) non_interactive=1; shift ;;
    --) shift; break ;;
    -*)
      err "unknown flag: $1"; usage >&2; exit 2 ;;
    *)
      if [[ -z "$subcommand" ]]; then
        subcommand="$1"
      else
        err "unexpected positional argument: $1"; usage >&2; exit 2
      fi
      shift ;;
  esac
done

# If neither --list nor --status nor --dry-run, and a subcommand was given,
# we're in wizard mode.
if [[ -z "$mode" ]] && [[ -n "$subcommand" ]]; then
  mode="wizard"
fi

# No mode + no subcommand = print help.
if [[ -z "$mode" ]] && [[ -z "$subcommand" ]]; then
  usage; exit 2
fi

# -----------------------------------------------------------------------------
# prerequisites
# -----------------------------------------------------------------------------
if ! command -v jq >/dev/null 2>&1; then
  err "jq is required — brew install jq (macOS) or apt install jq (Debian)"
  exit 1
fi

# -----------------------------------------------------------------------------
# file paths (overridable for self-test fixtures)
# -----------------------------------------------------------------------------
LINEAR_FILE="${HYDRA_CONNECT_LINEAR_FILE:-$ROOT_DIR/state/linear.json}"
LINEAR_EXAMPLE="$ROOT_DIR/state/linear.example.json"
LINEAR_SCHEMA="$ROOT_DIR/state/schemas/linear.schema.json"

SLACK_FILE="${HYDRA_CONNECT_SLACK_FILE:-$ROOT_DIR/state/connectors/slack.json}"
SLACK_EXAMPLE="$ROOT_DIR/state/connectors/slack.json.example"
SLACK_SCHEMA="$ROOT_DIR/state/schemas/slack.schema.json"

MCP_FILE="${HYDRA_CONNECT_MCP_FILE:-$ROOT_DIR/state/connectors/mcp.json}"
MCP_EXAMPLE="$ROOT_DIR/state/connectors/mcp.json.example"
MCP_SCHEMA="$ROOT_DIR/state/schemas/mcp.schema.json"

DIGEST_FILE="${HYDRA_CONNECT_DIGEST_FILE:-$ROOT_DIR/state/digests.json}"
DIGEST_EXAMPLE="$ROOT_DIR/state/digests.example.json"
DIGEST_SCHEMA="$ROOT_DIR/state/schemas/digests.schema.json"

VALIDATE_STATE="$ROOT_DIR/scripts/validate-state.sh"

# -----------------------------------------------------------------------------
# helpers
# -----------------------------------------------------------------------------

# prompt_default LABEL DEFAULT [VALIDATE_REGEX]
# - In interactive mode: prompt, default on bare enter.
# - In non-interactive mode: echo DEFAULT with no prompt.
# - If VALIDATE_REGEX is provided, the resulting value must match or we err.
# - Reads from stdin ONLY in interactive mode.
# - Prints the chosen value to stdout (for `x=$(prompt_default ...)`).
# - Everything informational goes to stderr so command substitution works.
prompt_default() {
  local label="$1"
  local default="${2:-}"
  local regex="${3:-}"
  local line value

  if [[ "$non_interactive" -eq 1 ]]; then
    value="$default"
  else
    if [[ -n "$default" ]]; then
      printf "%s%s%s [%s]: " "$C_BOLD" "$label" "$C_RESET" "$default" >&2
    else
      printf "%s%s%s (required): " "$C_BOLD" "$label" "$C_RESET" >&2
    fi
    IFS= read -r line || line=""
    value="${line:-$default}"
  fi

  if [[ -n "$regex" ]] && [[ -n "$value" ]]; then
    if ! [[ "$value" =~ $regex ]]; then
      err "invalid $label '$value' (expected to match $regex)"
      exit 1
    fi
  fi

  printf '%s\n' "$value"
}

# Strip _description / _comment / _note / _* doc fields from a JSON blob
# so the wizard writes clean config rather than copying the .example.json's
# inline docs verbatim. Operates on objects at any depth — walks recursively.
strip_doc_fields() {
  jq 'walk(if type == "object" then with_entries(select(.key | startswith("_") | not)) else . end)'
}

# parse_mcp_list_line CONNECTOR_NAME
# Echo one of: "installed-ok" | "needs-auth" | "missing" based on a line in
# `claude mcp list`. Honors HYDRA_CONNECT_FAKE_MCP_LIST for tests.
# Returns the status via stdout — caller inspects.
probe_mcp_server() {
  local name="$1"
  local output

  if [[ -n "${HYDRA_CONNECT_FAKE_MCP_LIST:-}" ]] && [[ -f "$HYDRA_CONNECT_FAKE_MCP_LIST" ]]; then
    output="$(cat "$HYDRA_CONNECT_FAKE_MCP_LIST")"
  elif command -v claude >/dev/null 2>&1; then
    # `claude mcp list` may write status to stderr on some versions; merge.
    output="$(claude mcp list 2>&1 || true)"
  else
    echo "mcp-unavailable"
    return
  fi

  # Case-insensitive match on "<name> ..." somewhere in the output. If the
  # line also says "Needs authentication", treat as needs-auth.
  local line
  line="$(printf '%s\n' "$output" | grep -iE "(^|[[:space:]])${name}([[:space:]]|:)" | head -1 || true)"

  if [[ -z "$line" ]]; then
    echo "missing"
  elif [[ "$line" =~ [Nn]eeds[[:space:]]+[Aa]uthentication ]] \
    || [[ "$line" =~ [Nn]ot[[:space:]]+[Aa]uthenticated ]] \
    || [[ "$line" =~ [Ff]ailed ]]; then
    echo "needs-auth"
  else
    echo "installed-ok"
  fi
}

# Read a path from a JSON file if it exists; otherwise echo empty string.
json_get_or_empty() {
  local file="$1" path="$2"
  if [[ -f "$file" ]]; then
    jq -r --arg dflt "" "$path // \$dflt" "$file" 2>/dev/null || echo ""
  else
    echo ""
  fi
}

# Validate a JSON file against a schema. Wraps scripts/validate-state.sh.
# Returns 0 on success; prints validator output on failure.
validate_against_schema() {
  local file="$1" schema="$2"
  if [[ ! -x "$VALIDATE_STATE" ]]; then
    warn "$VALIDATE_STATE not executable; skipping schema validation"
    return 0
  fi
  "$VALIDATE_STATE" --schema "$schema" "$file" >&2
}

# Atomic write. Takes the JSON blob on stdin + the target path. Validates
# against the schema (schema arg) before the mv. If schema validation
# fails, the tmpfile is deleted and we exit 1.
atomic_write() {
  local target="$1" schema="$2"
  local dir tmp
  dir="$(dirname "$target")"
  mkdir -p "$dir"
  tmp="$(mktemp "$dir/.$(basename "$target").XXXXXX")"
  # shellcheck disable=SC2064
  trap "rm -f '$tmp'" RETURN
  cat >"$tmp"
  if ! jq empty "$tmp" 2>/dev/null; then
    err "atomic_write: tmpfile is not valid JSON"
    return 1
  fi
  if ! validate_against_schema "$tmp" "$schema"; then
    err "atomic_write: schema validation failed — refusing to write"
    return 1
  fi
  mv "$tmp" "$target"
  trap - RETURN
}

# -----------------------------------------------------------------------------
# dispatch: --list
# -----------------------------------------------------------------------------
#
# Discover supported connectors by scanning state/*.example.json +
# state/connectors/*.example.json for the canonical names the wizard knows
# about. For each, report installed / missing state.
cmd_list() {
  # The canonical set. If a new connector is added, extend here.
  declare -a connectors=("linear" "slack" "supervisor")

  printf "%-12s %-12s %s\n" "CONNECTOR" "STATE" "DETAIL"
  printf "%-12s %-12s %s\n" "---------" "-----" "------"

  for c in "${connectors[@]}"; do
    local state="missing" detail=""
    case "$c" in
      linear)
        if [[ -f "$LINEAR_FILE" ]]; then
          local enabled
          enabled="$(jq -r '.enabled // false' "$LINEAR_FILE" 2>/dev/null || echo false)"
          if [[ "$enabled" == "true" ]]; then
            state="installed"
            detail="$LINEAR_FILE (enabled)"
          else
            state="disabled"
            detail="$LINEAR_FILE (enabled=false)"
          fi
        else
          detail="no $LINEAR_FILE"
        fi
        ;;
      slack)
        if [[ -f "$SLACK_FILE" ]]; then
          local enabled
          enabled="$(jq -r '.enabled // false' "$SLACK_FILE" 2>/dev/null || echo false)"
          if [[ "$enabled" == "true" ]]; then
            state="installed"
            detail="$SLACK_FILE (enabled)"
          else
            state="disabled"
            detail="$SLACK_FILE (enabled=false)"
          fi
        else
          detail="no $SLACK_FILE"
        fi
        ;;
      supervisor)
        if [[ -f "$MCP_FILE" ]]; then
          local enabled
          enabled="$(jq -r '.upstream_supervisor.enabled // false' "$MCP_FILE" 2>/dev/null || echo false)"
          if [[ "$enabled" == "true" ]]; then
            state="installed"
            detail="$MCP_FILE:upstream_supervisor (enabled)"
          else
            state="disabled"
            detail="$MCP_FILE:upstream_supervisor (enabled=false)"
          fi
        else
          detail="no $MCP_FILE"
        fi
        ;;
    esac
    printf "%-12s %-12s %s\n" "$c" "$state" "$detail"
  done
  exit 0
}

# -----------------------------------------------------------------------------
# dispatch: --status
# -----------------------------------------------------------------------------
#
# Live health check. For MCP-backed connectors (linear, supervisor in http/
# stdio modes), probe `claude mcp list`. For slack, check config presence +
# enabled flag. --quiet prints a single summary line for Commander's session
# greeting.
cmd_status() {
  local any_broken=0
  local broken_names=()
  local ok_names=()
  local disabled_names=()

  # ---- linear ----
  # "not configured" = file missing, treated as silently disabled. Only
  # "enabled but MCP broken / auth expired" counts as BROKEN.
  {
    if [[ ! -f "$LINEAR_FILE" ]]; then
      disabled_names+=("linear")
      [[ "$quiet" -eq 1 ]] || printf "%-12s %-12s %s\n" "linear" "NOT-CONFIG" "run: ./hydra connect linear"
    else
      local enabled
      enabled="$(jq -r '.enabled // false' "$LINEAR_FILE")"
      if [[ "$enabled" != "true" ]]; then
        disabled_names+=("linear")
        [[ "$quiet" -eq 1 ]] || printf "%-12s %-12s %s\n" "linear" "DISABLED" "$LINEAR_FILE:enabled=false"
      else
        local mcp_state
        mcp_state="$(probe_mcp_server linear)"
        case "$mcp_state" in
          installed-ok)
            ok_names+=("linear")
            [[ "$quiet" -eq 1 ]] || printf "%-12s %-12s %s\n" "linear" "OK" "mcp-installed, config valid"
            ;;
          needs-auth)
            broken_names+=("linear auth expired")
            any_broken=1
            [[ "$quiet" -eq 1 ]] || printf "%-12s %-12s %s\n" "linear" "BROKEN" "claude mcp list says 'Needs authentication' — run: claude mcp add linear"
            ;;
          missing)
            broken_names+=("linear mcp missing")
            any_broken=1
            [[ "$quiet" -eq 1 ]] || printf "%-12s %-12s %s\n" "linear" "BROKEN" "linear MCP server not installed — run: claude mcp add linear"
            ;;
          mcp-unavailable)
            broken_names+=("linear (claude CLI unavailable)")
            any_broken=1
            [[ "$quiet" -eq 1 ]] || printf "%-12s %-12s %s\n" "linear" "BROKEN" "'claude' CLI not on PATH; can't probe MCP"
            ;;
        esac
      fi
    fi
  }

  # ---- slack ----
  {
    if [[ ! -f "$SLACK_FILE" ]]; then
      disabled_names+=("slack")
      [[ "$quiet" -eq 1 ]] || printf "%-12s %-12s %s\n" "slack" "NOT-CONFIG" "run: ./hydra connect slack"
    else
      local enabled
      enabled="$(jq -r '.enabled // false' "$SLACK_FILE")"
      if [[ "$enabled" != "true" ]]; then
        disabled_names+=("slack")
        [[ "$quiet" -eq 1 ]] || printf "%-12s %-12s %s\n" "slack" "DISABLED" "$SLACK_FILE:enabled=false"
      else
        ok_names+=("slack")
        [[ "$quiet" -eq 1 ]] || printf "%-12s %-12s %s\n" "slack" "OK" "config valid; bot starts on Commander launch"
      fi
    fi
  }

  # ---- supervisor (upstream_supervisor section of mcp.json) ----
  {
    if [[ ! -f "$MCP_FILE" ]]; then
      disabled_names+=("supervisor")
      [[ "$quiet" -eq 1 ]] || printf "%-12s %-12s %s\n" "supervisor" "NOT-CONFIG" "run: ./hydra connect supervisor"
    else
      local enabled connect_url
      enabled="$(jq -r '.upstream_supervisor.enabled // false' "$MCP_FILE")"
      connect_url="$(jq -r '.upstream_supervisor.connect_url // ""' "$MCP_FILE")"
      if [[ "$enabled" != "true" ]]; then
        disabled_names+=("supervisor")
        [[ "$quiet" -eq 1 ]] || printf "%-12s %-12s %s\n" "supervisor" "DISABLED" "upstream_supervisor.enabled=false"
      elif [[ -z "$connect_url" ]] || [[ "$connect_url" == "REPLACE_WITH_STDIO_COMMAND_OR_HTTP_URL" ]]; then
        broken_names+=("supervisor connect_url missing")
        any_broken=1
        [[ "$quiet" -eq 1 ]] || printf "%-12s %-12s %s\n" "supervisor" "BROKEN" "upstream_supervisor.connect_url is empty or placeholder"
      else
        ok_names+=("supervisor")
        [[ "$quiet" -eq 1 ]] || printf "%-12s %-12s %s\n" "supervisor" "OK" "upstream_supervisor enabled + connect_url set"
      fi
    fi
  }

  # --quiet summary: only print if there's something interesting.
  if [[ "$quiet" -eq 1 ]]; then
    # Commander's session greeting uses this shape. Only produce output if
    # there's a BROKEN connector — otherwise silent (green path).
    if [[ "$any_broken" -eq 1 ]]; then
      local joined
      joined="$(IFS=,; echo "${broken_names[*]}")"
      printf "Connectors: %s\n" "$joined"
    fi
  fi

  if [[ "$any_broken" -eq 1 ]]; then
    exit 1
  fi
  exit 0
}

# -----------------------------------------------------------------------------
# wizard: connect_linear
# -----------------------------------------------------------------------------
connect_linear() {
  local dry_run="$1"

  info "Connecting Linear"

  # Preflight: is the linear MCP server installed?
  if [[ "$dry_run" -eq 0 ]]; then
    local mcp_state
    mcp_state="$(probe_mcp_server linear)"
    case "$mcp_state" in
      installed-ok) ok "linear MCP server installed + authenticated" ;;
      needs-auth)
        warn "linear MCP server installed but needs authentication"
        warn "run: claude mcp add linear  (re-auths the existing entry)"
        ;;
      missing)
        warn "linear MCP server not installed"
        if [[ "$non_interactive" -eq 0 ]] && [[ -t 0 ]]; then
          printf "%srun 'claude mcp add linear' now?%s [y/N]: " "$C_BOLD" "$C_RESET" >&2
          local ans ans_lc
          IFS= read -r ans || ans=""
          # Bash 3.2 (macOS default) doesn't support ${ans,,} — use tr.
          ans_lc="$(printf '%s' "$ans" | tr '[:upper:]' '[:lower:]')"
          if [[ "$ans_lc" == "y" ]] || [[ "$ans_lc" == "yes" ]]; then
            if command -v claude >/dev/null 2>&1; then
              claude mcp add linear || {
                err "claude mcp add linear failed — fix the MCP env and re-run"
                exit 1
              }
            else
              err "'claude' CLI not on PATH; install it first"
              exit 1
            fi
          else
            warn "skipping MCP install — config will be written but Commander's linear path will not work until MCP is installed"
          fi
        else
          warn "non-interactive or non-TTY: skipping MCP install prompt"
        fi
        ;;
      mcp-unavailable)
        warn "'claude' CLI not on PATH — can't probe MCP state"
        ;;
    esac
  fi

  # Bootstrap: if state/linear.json doesn't exist, seed from example +
  # strip _description fields.
  local existing_json
  if [[ -f "$LINEAR_FILE" ]]; then
    existing_json="$(cat "$LINEAR_FILE")"
  elif [[ -f "$LINEAR_EXAMPLE" ]]; then
    existing_json="$(strip_doc_fields <"$LINEAR_EXAMPLE")"
  else
    err "neither $LINEAR_FILE nor $LINEAR_EXAMPLE exists"
    exit 1
  fi

  # Current values — used as prompt defaults for idempotent re-runs.
  local cur_enabled cur_team_id cur_team_name cur_trigger_type cur_trigger_value
  cur_enabled="$(echo "$existing_json" | jq -r '.enabled // false')"
  cur_team_id="$(echo "$existing_json" | jq -r '.teams[0].team_id // ""')"
  cur_team_name="$(echo "$existing_json" | jq -r '.teams[0].team_name // "Engineering"')"
  cur_trigger_type="$(echo "$existing_json" | jq -r '.teams[0].trigger.type // "assignee"')"
  cur_trigger_value="$(echo "$existing_json" | jq -r '.teams[0].trigger.value // "me"')"

  # Treat placeholder values from the example as "no existing default" so the
  # prompt doesn't helpfully suggest "TEAM-ID-FROM-LINEAR".
  if [[ "$cur_team_id" == "TEAM-ID-FROM-LINEAR" ]]; then
    cur_team_id=""
  fi

  local team_id team_name trigger_type trigger_value enabled
  team_id="$(prompt_default "team_id" "$cur_team_id")"
  if [[ -z "$team_id" ]]; then
    err "team_id is required"
    exit 1
  fi
  team_name="$(prompt_default "team_name" "$cur_team_name")"
  trigger_type="$(prompt_default "trigger_type (assignee|state|label)" "$cur_trigger_type" '^(assignee|state|label)$')"
  trigger_value="$(prompt_default "trigger_value" "$cur_trigger_value")"
  enabled="$(prompt_default "enabled (true|false)" "$cur_enabled" '^(true|false)$')"

  # Build the merged JSON. We start from existing_json so we don't lose
  # unrelated keys (comment_on, rate_limit_per_hour, state_name_mapping, etc.).
  # We overwrite just the first team in teams[] — multi-team setups require
  # a manual edit for now.
  local merged
  merged="$(
    echo "$existing_json" | jq \
      --arg team_id    "$team_id" \
      --arg team_name  "$team_name" \
      --arg trig_type  "$trigger_type" \
      --arg trig_value "$trigger_value" \
      --argjson enabled "$enabled" \
      '
      .enabled = $enabled
      | if (.teams // []) | length == 0
        then .teams = [{
          team_id: $team_id,
          team_name: $team_name,
          trigger: { type: $trig_type, value: $trig_value }
        }]
        else .teams[0].team_id = $team_id
             | .teams[0].team_name = $team_name
             | .teams[0].trigger.type = $trig_type
             | .teams[0].trigger.value = $trig_value
        end
      '
  )"

  # state_transitions + comment_on: preserve whatever is already there;
  # bootstrap sensible defaults if missing.
  merged="$(
    echo "$merged" | jq '
      .state_transitions = (.state_transitions // {
        on_pickup: "In Progress",
        on_pr_opened: "In Review",
        on_pr_merged: "Done",
        on_stuck: "Blocked"
      })
      | .comment_on = (.comment_on // {
        worker_started: true,
        question_asked: true,
        pr_opened: true,
        pr_merged: true,
        worker_stuck: true
      })
    '
  )"

  if [[ "$dry_run" -eq 1 ]]; then
    printf "%s-- dry-run: would write to %s --%s\n" "$C_DIM" "$LINEAR_FILE" "$C_RESET" >&2
    echo "$merged" | jq .
    # Validate the dry-run blob too — catches schema problems before a real run.
    local tmp
    tmp="$(mktemp)"
    echo "$merged" >"$tmp"
    if ! validate_against_schema "$tmp" "$LINEAR_SCHEMA"; then
      rm -f "$tmp"
      err "dry-run output failed schema validation"
      exit 1
    fi
    rm -f "$tmp"
    ok "dry-run JSON valid against $LINEAR_SCHEMA"
    exit 0
  fi

  echo "$merged" | atomic_write "$LINEAR_FILE" "$LINEAR_SCHEMA"
  ok "wrote $LINEAR_FILE"
}

# -----------------------------------------------------------------------------
# wizard: connect_slack
# -----------------------------------------------------------------------------
connect_slack() {
  local dry_run="$1"

  info "Connecting Slack"
  info "Slack bot tokens live in env vars (xoxb- / xapp-), not this file."
  info "Set them via 'fly secrets set' or your shell before launching the bot."

  local existing_json
  if [[ -f "$SLACK_FILE" ]]; then
    existing_json="$(cat "$SLACK_FILE")"
  elif [[ -f "$SLACK_EXAMPLE" ]]; then
    existing_json="$(strip_doc_fields <"$SLACK_EXAMPLE")"
  else
    err "neither $SLACK_FILE nor $SLACK_EXAMPLE exists"
    exit 1
  fi

  local cur_enabled cur_bot_env cur_app_env cur_user cur_channel cur_interval
  cur_enabled="$(echo "$existing_json" | jq -r '.enabled // false')"
  cur_bot_env="$(echo "$existing_json" | jq -r '.bot_token_env // "HYDRA_SLACK_BOT_TOKEN"')"
  cur_app_env="$(echo "$existing_json" | jq -r '.app_token_env // "HYDRA_SLACK_APP_TOKEN"')"
  cur_user="$(echo "$existing_json" | jq -r '.allowed_user_id // ""')"
  cur_channel="$(echo "$existing_json" | jq -r '.default_channel // ""')"
  cur_interval="$(echo "$existing_json" | jq -r '.notification_poll_interval_sec // 60')"

  # Scrub the example placeholders so prompts don't suggest U0000000000.
  if [[ "$cur_user" == "U0000000000" ]]; then cur_user=""; fi
  if [[ "$cur_channel" == "D0000000000" ]]; then cur_channel=""; fi

  local bot_env app_env user channel interval enabled
  enabled="$(prompt_default "enabled (true|false)" "$cur_enabled" '^(true|false)$')"
  bot_env="$(prompt_default "bot_token_env" "$cur_bot_env")"
  app_env="$(prompt_default "app_token_env" "$cur_app_env")"
  user="$(prompt_default "allowed_user_id (U...)" "$cur_user" '^U[A-Z0-9]+$')"
  if [[ -z "$user" ]]; then
    err "allowed_user_id is required"
    exit 1
  fi
  channel="$(prompt_default "default_channel (C.../D.../G...)" "$cur_channel" '^[CDG][A-Z0-9]+$')"
  if [[ -z "$channel" ]]; then
    err "default_channel is required"
    exit 1
  fi
  interval="$(prompt_default "notification_poll_interval_sec (>=30)" "$cur_interval" '^[0-9]+$')"
  if (( interval < 30 )); then
    err "notification_poll_interval_sec must be >= 30"
    exit 1
  fi

  local merged
  merged="$(
    echo "$existing_json" | jq \
      --argjson enabled  "$enabled" \
      --arg bot_env      "$bot_env" \
      --arg app_env      "$app_env" \
      --arg user         "$user" \
      --arg channel      "$channel" \
      --argjson interval "$interval" \
      '
      .enabled = $enabled
      | .bot_token_env = $bot_env
      | .app_token_env = $app_env
      | .allowed_user_id = $user
      | .default_channel = $channel
      | .notification_poll_interval_sec = $interval
      | .repos = (.repos // [])
      | .seen_prs_state_path = (.seen_prs_state_path // "state/slack-notified-prs.json")
      '
  )"

  if [[ "$dry_run" -eq 1 ]]; then
    printf "%s-- dry-run: would write to %s --%s\n" "$C_DIM" "$SLACK_FILE" "$C_RESET" >&2
    echo "$merged" | jq .
    local tmp
    tmp="$(mktemp)"
    echo "$merged" >"$tmp"
    if ! validate_against_schema "$tmp" "$SLACK_SCHEMA"; then
      rm -f "$tmp"
      err "dry-run output failed schema validation"
      exit 1
    fi
    rm -f "$tmp"
    ok "dry-run JSON valid against $SLACK_SCHEMA"
    exit 0
  fi

  echo "$merged" | atomic_write "$SLACK_FILE" "$SLACK_SCHEMA"
  ok "wrote $SLACK_FILE"
}

# -----------------------------------------------------------------------------
# wizard: connect_supervisor
# -----------------------------------------------------------------------------
#
# Writes ONLY the upstream_supervisor subtree of state/connectors/mcp.json.
# Preserves server / authorized_agents / audit.
connect_supervisor() {
  local dry_run="$1"

  info "Connecting upstream supervisor (outbound MCP)"
  info "This wires Commander's QUESTION-escalation path. See docs/specs/2026-04-17-supervisor-escalate-client.md."

  local existing_json
  if [[ -f "$MCP_FILE" ]]; then
    existing_json="$(cat "$MCP_FILE")"
  elif [[ -f "$MCP_EXAMPLE" ]]; then
    # Bootstrap: clear authorized_agents (we don't want example hashes on disk)
    # and strip _description fields.
    existing_json="$(strip_doc_fields <"$MCP_EXAMPLE" | jq '.authorized_agents = []')"
  else
    err "neither $MCP_FILE nor $MCP_EXAMPLE exists"
    exit 1
  fi

  local cur_enabled cur_name cur_transport cur_url cur_env cur_timeout
  cur_enabled="$(echo "$existing_json" | jq -r '.upstream_supervisor.enabled // false')"
  cur_name="$(echo "$existing_json" | jq -r '.upstream_supervisor.name // "your-supervisor"')"
  cur_transport="$(echo "$existing_json" | jq -r '.upstream_supervisor.transport // "stdio"')"
  cur_url="$(echo "$existing_json" | jq -r '.upstream_supervisor.connect_url // ""')"
  cur_env="$(echo "$existing_json" | jq -r '.upstream_supervisor.auth_token_env // "HYDRA_SUPERVISOR_TOKEN"')"
  cur_timeout="$(echo "$existing_json" | jq -r '.upstream_supervisor.timeout_sec // 300')"

  # Scrub placeholder.
  if [[ "$cur_url" == "REPLACE_WITH_STDIO_COMMAND_OR_HTTP_URL" ]]; then cur_url=""; fi

  local enabled name transport url env timeout
  enabled="$(prompt_default "upstream_supervisor.enabled (true|false)" "$cur_enabled" '^(true|false)$')"
  name="$(prompt_default "name" "$cur_name")"
  transport="$(prompt_default "transport (stdio|http)" "$cur_transport" '^(stdio|http)$')"
  url="$(prompt_default "connect_url (stdio command OR https URL)" "$cur_url")"
  if [[ "$enabled" == "true" ]] && [[ -z "$url" ]]; then
    err "connect_url is required when enabled=true"
    exit 1
  fi
  env="$(prompt_default "auth_token_env" "$cur_env")"
  timeout="$(prompt_default "timeout_sec" "$cur_timeout" '^[0-9]+$')"

  # Build merged JSON — only the upstream_supervisor subtree changes.
  local merged
  merged="$(
    echo "$existing_json" | jq \
      --argjson enabled "$enabled" \
      --arg name        "$name" \
      --arg transport   "$transport" \
      --arg url         "$url" \
      --arg env         "$env" \
      --argjson timeout "$timeout" \
      '
      .upstream_supervisor = (.upstream_supervisor // {}) + {
        enabled: $enabled,
        name: $name,
        transport: $transport,
        connect_url: $url,
        auth_token_env: $env,
        scope_granted: ["resolve_question"],
        timeout_sec: $timeout
      }
      '
  )"

  if [[ "$dry_run" -eq 1 ]]; then
    printf "%s-- dry-run: would write to %s (upstream_supervisor subtree) --%s\n" "$C_DIM" "$MCP_FILE" "$C_RESET" >&2
    echo "$merged" | jq '.upstream_supervisor'
    local tmp
    tmp="$(mktemp)"
    echo "$merged" >"$tmp"
    if ! validate_against_schema "$tmp" "$MCP_SCHEMA"; then
      rm -f "$tmp"
      err "dry-run output failed schema validation"
      exit 1
    fi
    rm -f "$tmp"
    ok "dry-run JSON valid against $MCP_SCHEMA"
    exit 0
  fi

  echo "$merged" | atomic_write "$MCP_FILE" "$MCP_SCHEMA"
  ok "wrote upstream_supervisor subtree in $MCP_FILE"
}

# -----------------------------------------------------------------------------
# dispatch
# -----------------------------------------------------------------------------
case "$mode" in
  list)   cmd_list ;;
  status) cmd_status ;;
  dry-run)
    if [[ -z "$subcommand" ]]; then
      err "--dry-run requires a connector (linear|slack|supervisor)"
      exit 2
    fi
    case "$subcommand" in
      linear)     connect_linear     1 ;;
      slack)      connect_slack      1 ;;
      supervisor) connect_supervisor 1 ;;
      *) err "unknown connector: $subcommand"; exit 2 ;;
    esac
    ;;
  wizard)
    case "$subcommand" in
      linear)     connect_linear     0 ;;
      slack)      connect_slack      0 ;;
      supervisor) connect_supervisor 0 ;;
      *) err "unknown connector: $subcommand"; exit 2 ;;
    esac
    ;;
  *)
    err "internal: unknown mode '$mode'"; exit 2 ;;
esac

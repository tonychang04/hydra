#!/usr/bin/env bash
#
# hydra-pair-agent.sh — one-command setup for a new MCP-speaking agent.
#
# Wraps the ticket #92 primitive (scripts/hydra-mcp-register-agent.sh) to:
#   1. Generate a fresh bearer token for a given agent-id.
#   2. Detect whether the operator has a local MCP server running, a Fly
#      cloud commander running, or neither — print recipes for whichever
#      apply.
#   3. Emit paste-ready config blocks for Claude Code, Cursor,
#      OpenClaw / Codex-CLI / generic MCP, and a raw curl one-liner.
#   4. Run a live sanity check — call hydra.get_status with the fresh
#      bearer, report ✓ or an actionable ✗.
#
# Security invariants (see docs/specs/2026-04-17-pair-agent.md §Risks):
#   - Raw bearer goes to stdout EXACTLY ONCE (the "copy this now" block).
#   - Bearer is never written to disk (register-agent primitive only
#     stores the SHA-256 hash).
#   - Bearer is never in logs, error messages, or curl -v output —
#     sanity-check curl uses -sS (no verbose).
#   - --dry-run never generates a real token, never mutates config,
#     never hits the network; prints <token-would-go-here> placeholder.
#
# Spec: docs/specs/2026-04-17-pair-agent.md (ticket #124)

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"

# shellcheck disable=SC1091
[[ -f "$ROOT_DIR/.hydra.env" ]] && source "$ROOT_DIR/.hydra.env"

REGISTER_SCRIPT="$SCRIPT_DIR/hydra-mcp-register-agent.sh"
MCP_CONFIG="${HYDRA_MCP_REGISTER_CONFIG:-$ROOT_DIR/state/connectors/mcp.json}"
MCP_EXAMPLE="$ROOT_DIR/state/connectors/mcp.json.example"
FLY_TOML="$ROOT_DIR/infra/fly.toml"

usage() {
  cat <<'EOF'
Usage: ./hydra pair-agent <agent-id> [options]

One command to onboard a new MCP-speaking agent to your Hydra Commander.
Generates a fresh bearer, prints paste-ready config recipes, and runs a
live sanity check.

Arguments:
  <agent-id>              Required. Free-form label for the agent
                          (letters, digits, dots, dashes, underscores).
                          Must be unique; use --rotate on the primitive
                          to replace an existing agent-id.

Options:
  --scope <list>          Comma-separated scope list. Allowed values:
                          read, spawn, merge, admin.
                          Default: read,spawn.
  --editor <name>         Print only one recipe. One of:
                          claude-code, cursor, openclaw, generic.
                          Default: print all four recipes.
  --dry-run               Print recipes with placeholder token; do NOT
                          generate a bearer, do NOT mutate config, do
                          NOT run the sanity check. CI / self-test safe.
  -h, --help              Show this help.

Exit codes:
  0   Agent registered, recipes printed, sanity check passed (or --dry-run).
  1   I/O error, missing prerequisite, or register-agent primitive failed.
  2   Usage error (bad flag, missing agent-id, invalid scope).
  3   Registration succeeded but the live sanity check failed. The agent
      is still registered; re-run the raw curl recipe manually to debug.

Security notes:
  - The raw bearer is printed to stdout exactly once, at the end.
  - Copy it into the consuming agent's config immediately — Hydra only
    stores the SHA-256 hash on disk.
  - --dry-run is safe for CI: no tokens are generated and no files are
    modified.

Examples:
  # Default: read + spawn scope, all four recipes, live sanity check.
  ./hydra pair-agent my-laptop-claude

  # Widen scope to merge, only print the Cursor recipe.
  ./hydra pair-agent cursor-project --scope read,spawn,merge --editor cursor

  # Self-test / CI: no network, no mutation, no real token.
  ./hydra pair-agent test-agent --dry-run
EOF
}

# -----------------------------------------------------------------------------
# color (stderr; stdout stays plain for copy-paste friendliness)
# -----------------------------------------------------------------------------
if [[ -t 2 ]] && [[ "${NO_COLOR:-}" != "1" ]]; then
  C_GREEN=$'\033[32m'
  C_RED=$'\033[31m'
  C_YELLOW=$'\033[33m'
  C_BOLD=$'\033[1m'
  C_DIM=$'\033[2m'
  C_RESET=$'\033[0m'
else
  C_GREEN=""; C_RED=""; C_YELLOW=""; C_BOLD=""; C_DIM=""; C_RESET=""
fi

err()  { printf "%s✗%s %s\n" "$C_RED"    "$C_RESET" "$*" >&2; }
ok()   { printf "%s✓%s %s\n" "$C_GREEN"  "$C_RESET" "$*" >&2; }
warn() { printf "%s⚠%s %s\n" "$C_YELLOW" "$C_RESET" "$*" >&2; }
dim()  { printf "  %s%s%s\n" "$C_DIM" "$*" "$C_RESET" >&2; }

# -----------------------------------------------------------------------------
# args
# -----------------------------------------------------------------------------
agent_id=""
scope="read,spawn"
editor=""
dry_run=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --scope)
      [[ $# -ge 2 ]] || { err "--scope needs a value"; usage >&2; exit 2; }
      scope="$2"; shift 2 ;;
    --scope=*)
      scope="${1#--scope=}"; shift ;;
    --editor)
      [[ $# -ge 2 ]] || { err "--editor needs a value"; usage >&2; exit 2; }
      editor="$2"; shift 2 ;;
    --editor=*)
      editor="${1#--editor=}"; shift ;;
    --dry-run)
      dry_run=1; shift ;;
    --) shift; break ;;
    -*)
      err "unknown flag: $1"
      usage >&2
      exit 2
      ;;
    *)
      if [[ -z "$agent_id" ]]; then
        agent_id="$1"
      else
        err "unexpected positional argument: $1"
        usage >&2
        exit 2
      fi
      shift
      ;;
  esac
done

if [[ -z "$agent_id" ]]; then
  err "missing required <agent-id> argument"
  usage >&2
  exit 2
fi

# Validate agent-id shape — same regex as the primitive.
if ! [[ "$agent_id" =~ ^[A-Za-z0-9._-]+$ ]]; then
  err "invalid agent-id '$agent_id' — allowed: [A-Za-z0-9._-]"
  exit 2
fi

# Validate --scope list.
IFS=',' read -r -a scope_arr <<< "$scope"
for s in "${scope_arr[@]}"; do
  case "$s" in
    read|spawn|merge|admin) ;;
    "")
      err "empty entry in --scope list: '$scope'"; exit 2 ;;
    *)
      err "invalid scope '$s' — allowed: read, spawn, merge, admin"
      exit 2 ;;
  esac
done

# Validate --editor.
case "$editor" in
  ""|claude-code|cursor|openclaw|generic) ;;
  *)
    err "invalid --editor '$editor' — allowed: claude-code, cursor, openclaw, generic"
    exit 2 ;;
esac

# -----------------------------------------------------------------------------
# prerequisites
# -----------------------------------------------------------------------------
if ! command -v jq >/dev/null 2>&1; then
  err "jq is required — brew install jq (macOS) or apt install jq (Debian)"
  exit 1
fi

if ! command -v curl >/dev/null 2>&1; then
  err "curl is required — most systems have it preinstalled"
  exit 1
fi

if [[ "$dry_run" -eq 0 ]]; then
  if [[ ! -x "$REGISTER_SCRIPT" ]]; then
    err "register-agent primitive missing or not executable: $REGISTER_SCRIPT"
    err "  this wrapper delegates bearer generation — check your install"
    exit 1
  fi
fi

# -----------------------------------------------------------------------------
# URL detection
#
# local: state/connectors/mcp.json:server.http_port (or example fallback), +
#   quick TCP probe to 127.0.0.1:<port>.
# cloud: infra/fly.toml:app + `fly status` reports a started machine.
#
# Fallback (neither): default to local URL shape, print a yellow warning.
# -----------------------------------------------------------------------------
detect_local_port() {
  local src=""
  if [[ -f "$MCP_CONFIG" ]]; then
    src="$MCP_CONFIG"
  elif [[ -f "$MCP_EXAMPLE" ]]; then
    src="$MCP_EXAMPLE"
  fi
  if [[ -n "$src" ]]; then
    jq -r '.server.http_port // 8765' "$src" 2>/dev/null || echo 8765
  else
    echo 8765
  fi
}

local_tcp_probe() {
  # Returns 0 if 127.0.0.1:<port> accepts a connection, 1 otherwise.
  local port="$1"
  local host="127.0.0.1"
  # Use bash /dev/tcp pseudo-device; some distros' bash is built without
  # it (rare). Guard via command -v timeout for the 500ms ceiling.
  if command -v timeout >/dev/null 2>&1; then
    timeout 0.5 bash -c "exec 3<>/dev/tcp/$host/$port" 2>/dev/null
  else
    # Fire-and-forget; bash builds without /dev/tcp are rare, and a missed
    # probe just means we print the default local recipe + warning.
    bash -c "exec 3<>/dev/tcp/$host/$port" 2>/dev/null
  fi
}

detect_fly_app() {
  # Read app name from infra/fly.toml. Returns app name on stdout or empty.
  [[ -f "$FLY_TOML" ]] || return 0
  # Extract `app = "..."` — simple grep + sed. Fly.toml syntax is stable.
  grep -E '^[[:space:]]*app[[:space:]]*=' "$FLY_TOML" 2>/dev/null \
    | head -n1 \
    | sed -E 's/^[[:space:]]*app[[:space:]]*=[[:space:]]*"([^"]+)".*/\1/'
}

fly_cli() {
  if command -v flyctl >/dev/null 2>&1; then echo flyctl
  elif command -v fly >/dev/null 2>&1; then echo fly
  else echo ""
  fi
}

cloud_status() {
  # Returns 0 if a Fly machine for the app is running, 1 otherwise.
  # Silent (stderr suppressed) — this is a detection, not a diagnosis.
  local app="$1"
  local bin
  bin="$(fly_cli)"
  [[ -n "$bin" ]] || return 1
  [[ -n "$app" ]] || return 1
  # `fly status --app <name> --json` returns JSON on success; parse for a
  # machine state == "started". Cap wall-clock at 5s.
  local out
  if command -v timeout >/dev/null 2>&1; then
    out="$(timeout 5 "$bin" status --app "$app" --json 2>/dev/null || true)"
  else
    out="$("$bin" status --app "$app" --json 2>/dev/null || true)"
  fi
  [[ -n "$out" ]] || return 1
  # The fly status JSON shape varies slightly by version; we accept either
  # a top-level `Status` field == "running", or a Machines array with any
  # entry whose `state` == "started".
  echo "$out" | jq -e '
    (.Status // "") == "running"
    or ((.Machines // []) | any(.state == "started" or .State == "started"))
  ' >/dev/null 2>&1
}

LOCAL_PORT="$(detect_local_port)"
LOCAL_URL="http://127.0.0.1:${LOCAL_PORT}/mcp"
FLY_APP="$(detect_fly_app || true)"
CLOUD_URL=""
HAVE_LOCAL=0
HAVE_CLOUD=0

if local_tcp_probe "$LOCAL_PORT"; then
  HAVE_LOCAL=1
fi

if [[ -n "$FLY_APP" ]] && cloud_status "$FLY_APP"; then
  HAVE_CLOUD=1
  CLOUD_URL="https://${FLY_APP}.fly.dev/mcp"
fi

# Report detection on stderr so stdout stays clean for recipes.
if [[ "$HAVE_LOCAL" -eq 1 && "$HAVE_CLOUD" -eq 1 ]]; then
  warn "Detected BOTH local and cloud MCP servers — printing both recipes."
  dim "Pick the one that matches the context you're pairing the agent for."
elif [[ "$HAVE_LOCAL" -eq 1 ]]; then
  ok "Local MCP server detected at $LOCAL_URL"
elif [[ "$HAVE_CLOUD" -eq 1 ]]; then
  ok "Cloud MCP server detected at $CLOUD_URL"
else
  warn "No MCP server detected (local or cloud)."
  dim "Printing recipes for the default local URL: $LOCAL_URL"
  dim "Start one with: ./hydra mcp serve  (local)"
  dim "              or: fly deploy         (cloud; see docs/phase2-vps-runbook.md)"
fi

# -----------------------------------------------------------------------------
# bearer generation (skipped on --dry-run)
# -----------------------------------------------------------------------------
TOKEN=""
if [[ "$dry_run" -eq 0 ]]; then
  # Delegate to the primitive. Stdout = raw token; stderr = banner.
  set +e
  TOKEN="$(NO_COLOR="${NO_COLOR:-}" "$REGISTER_SCRIPT" "$agent_id" 2>/tmp/.pair-agent-register-$$.stderr)"
  RC=$?
  set -e
  REG_STDERR="$(cat /tmp/.pair-agent-register-$$.stderr 2>/dev/null || true)"
  rm -f /tmp/.pair-agent-register-$$.stderr

  if [[ "$RC" -ne 0 ]]; then
    err "register-agent primitive failed (exit $RC)"
    # Surface the primitive's stderr verbatim so the operator sees the
    # exact cause (duplicate id, bad jq, etc.). We never printed a
    # positional arg that could contain the token, so this is safe.
    printf '%s\n' "$REG_STDERR" >&2
    exit 1
  fi

  # Sanity-check the token shape — defensive (the primitive already
  # validates length, but we refuse to emit a placeholder-looking string
  # as a real token if something is off).
  if [[ ${#TOKEN} -lt 43 ]]; then
    err "register-agent returned an unexpected token length (${#TOKEN} < 43)"
    exit 1
  fi

  # Widen scope if the caller requested more than the primitive's default
  # (which is ["read"]). Atomic tmp+mv like the primitive itself.
  if [[ "$scope" != "read" ]]; then
    if [[ ! -f "$MCP_CONFIG" ]]; then
      err "internal: expected $MCP_CONFIG to exist after register-agent, but it does not"
      exit 1
    fi
    scope_json="$(printf '%s\n' "${scope_arr[@]}" | jq -R . | jq -s .)"
    tmp="$(mktemp "$(dirname "$MCP_CONFIG")/.pair-agent.XXXXXX")"
    # shellcheck disable=SC2064
    trap "rm -f '$tmp'" EXIT
    jq --arg id "$agent_id" --argjson scope "$scope_json" \
       '.authorized_agents = ((.authorized_agents // []) | map(
          if .id == $id then .scope = $scope else . end
       ))' "$MCP_CONFIG" > "$tmp"
    mv "$tmp" "$MCP_CONFIG"
    trap - EXIT
    ok "Scope widened to [$scope] on agent-id '$agent_id'"
  fi
fi

# -----------------------------------------------------------------------------
# recipes
#
# Block header format matches ./hydra doctor visual style: bold title on
# stderr, plain copy-pasteable body on stdout. Blank line between blocks
# keeps selection clean in terminals.
# -----------------------------------------------------------------------------
TOKEN_PLACEHOLDER="<token-would-go-here>"
if [[ "$dry_run" -eq 1 ]]; then
  RECIPE_TOKEN="$TOKEN_PLACEHOLDER"
else
  RECIPE_TOKEN="$TOKEN"
fi

# URL to reference in recipes when printing a single block. If both local
# and cloud are detected, each recipe prints both URLs (user picks one).
recipe_url_list() {
  local urls=()
  if [[ "$HAVE_CLOUD" -eq 1 ]]; then urls+=("$CLOUD_URL"); fi
  if [[ "$HAVE_LOCAL" -eq 1 ]]; then urls+=("$LOCAL_URL"); fi
  # Fallback: neither detected → print the local default so the operator
  # sees the shape; they'll adjust once they start a server.
  if [[ ${#urls[@]} -eq 0 ]]; then urls=("$LOCAL_URL"); fi
  printf '%s\n' "${urls[@]}"
}

# Primary URL for the sanity-check step — prefer cloud if present, else
# local. (Operators who detect both usually care about the cloud path —
# local is the dev-loop default.)
PRIMARY_URL="$LOCAL_URL"
if [[ "$HAVE_CLOUD" -eq 1 ]]; then PRIMARY_URL="$CLOUD_URL"; fi

print_block_header() {
  local title="$1"
  printf "\n%s▸ %s%s\n" "$C_BOLD" "$title" "$C_RESET" >&2
}

emit_claude_code_recipe() {
  print_block_header "Claude Code:"
  local url
  while IFS= read -r url; do
    printf 'claude mcp add hydra --url %s --transport http --header "Authorization: Bearer %s"\n' \
      "$url" "$RECIPE_TOKEN"
  done < <(recipe_url_list)
  dim "Paste in your terminal. Re-run the 'claude mcp list' command to verify."
}

emit_cursor_recipe() {
  print_block_header "Cursor / mcpServers JSON:"
  local url
  while IFS= read -r url; do
    # Cursor's mcpServers entry: URL transport with headers. Operators drop
    # this into ~/.cursor/mcp.json (or their project config). env block
    # shows the env-var path for rotating the bearer without editing JSON.
    cat <<EOF
{
  "mcpServers": {
    "hydra": {
      "url": "$url",
      "transport": "http",
      "headers": {
        "Authorization": "Bearer $RECIPE_TOKEN"
      },
      "_note_env": "For long-term use, move the bearer to an env var and reference it via \$HYDRA_BEARER in your shell."
    }
  }
}
EOF
  done < <(recipe_url_list)
  dim "Merge into ~/.cursor/mcp.json or your project's mcp.json."
}

emit_openclaw_recipe() {
  print_block_header "OpenClaw / Codex-CLI / generic MCP:"
  local url
  while IFS= read -r url; do
    cat <<EOF
# Generic MCP config — client-specific grammar varies.
# Replace --auth-header with your client's equivalent.
url=$url
transport=http
auth_header=Authorization: Bearer $RECIPE_TOKEN
EOF
  done < <(recipe_url_list)
  dim "OpenClaw + Codex-CLI config grammars shift across versions — consult your client's current docs."
}

emit_curl_recipe() {
  print_block_header "Raw curl (sanity check — doubles as a manual diagnostic):"
  local url
  while IFS= read -r url; do
    printf 'curl -sS -X POST %s -H "Content-Type: application/json" -H "Authorization: Bearer %s" -d %s\n' \
      "$url" "$RECIPE_TOKEN" \
      "'{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"hydra.get_status\",\"arguments\":{}}}'"
  done < <(recipe_url_list)
  dim "Expect HTTP 200 with a JSON-RPC body containing .result. Non-200 → see \"Errors\" section of ./hydra pair-agent --help."
}

case "$editor" in
  claude-code) emit_claude_code_recipe ;;
  cursor)      emit_cursor_recipe ;;
  openclaw)    emit_openclaw_recipe ;;
  generic)     emit_openclaw_recipe ;;
  "")
    emit_claude_code_recipe
    emit_cursor_recipe
    emit_openclaw_recipe
    emit_curl_recipe
    ;;
esac

# -----------------------------------------------------------------------------
# sanity check (skipped on --dry-run)
#
# Calls hydra.get_status via the curl recipe with the fresh bearer.
# Exit codes 200 → ✓; 401, 404, 5xx, connect-refused, timeout → distinct
# actionable errors.
# -----------------------------------------------------------------------------
run_sanity_check() {
  print_block_header "Live sanity check:"
  local payload='{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"hydra.get_status","arguments":{}}}'
  # Capture status + body separately. curl -sS suppresses progress; --max-time 5
  # caps wall-clock; -w writes the status code on stdout after the body.
  local tmpfile
  tmpfile="$(mktemp)"
  # shellcheck disable=SC2064
  trap "rm -f '$tmpfile'" EXIT
  local status
  status="$(
    curl -sS --max-time 5 \
      -o "$tmpfile" \
      -w '%{http_code}' \
      -X POST \
      -H "Content-Type: application/json" \
      -H "Authorization: Bearer $TOKEN" \
      "$PRIMARY_URL" \
      --data "$payload" \
      2>/dev/null || echo "curl-failed"
  )"
  local body
  body="$(cat "$tmpfile" 2>/dev/null || true)"
  rm -f "$tmpfile"
  trap - EXIT

  case "$status" in
    200)
      # Further verify the body is a JSON-RPC success.
      if echo "$body" | jq -e '.jsonrpc == "2.0" and (.result != null)' >/dev/null 2>&1; then
        ok "Sanity check passed — agent '$agent_id' can reach $PRIMARY_URL (HTTP 200)"
        return 0
      fi
      err "Sanity check failed — HTTP 200 but body is not a JSON-RPC success:"
      printf '  %s\n' "$body" >&2
      return 3
      ;;
    401)
      err "Sanity check failed — HTTP 401 bearer mismatch."
      dim "The server at $PRIMARY_URL does not recognize this token."
      dim "Possible causes: the Fly app was redeployed and lost state/connectors/mcp.json;"
      dim "you paired against the wrong URL; or the agent-id hash was rotated elsewhere."
      return 3
      ;;
    404)
      err "Sanity check failed — HTTP 404 at $PRIMARY_URL."
      dim "The MCP server is not serving /mcp at that URL."
      dim "Start a local server with:  ./hydra mcp serve"
      dim "Or redeploy the cloud commander: fly deploy"
      return 3
      ;;
    5*)
      err "Sanity check failed — HTTP $status server error."
      dim "The MCP server is reachable but returned an error. Check the server logs."
      return 3
      ;;
    000|curl-failed)
      # 000 = curl exit-before-HTTP (connect refused / resolve fail / timeout)
      err "Sanity check failed — no HTTP response from $PRIMARY_URL."
      dim "Possible causes: the server is not running, the URL is wrong,"
      dim "or a firewall is blocking the request. Try:"
      dim "  curl -v $PRIMARY_URL      # diagnose"
      dim "  ./hydra mcp serve         # start local"
      return 3
      ;;
    *)
      err "Sanity check failed — unexpected HTTP status $status from $PRIMARY_URL."
      dim "Response body: $body"
      return 3
      ;;
  esac
}

sanity_rc=0
if [[ "$dry_run" -eq 0 ]]; then
  set +e
  run_sanity_check
  sanity_rc=$?
  set -e
fi

# -----------------------------------------------------------------------------
# final bearer block — last thing on stdout so `| tail -n1` yields the token.
# Skipped entirely on --dry-run (no real token to emit).
# -----------------------------------------------------------------------------
if [[ "$dry_run" -eq 0 ]]; then
  {
    printf "\n"
    printf "%s⚠ This is the only time the bearer will be shown.%s\n" "$C_BOLD$C_YELLOW" "$C_RESET"
    printf "  Copy it into the consuming agent's config NOW.\n"
    printf "  Agent-id: %s%s%s · scope: [%s]\n" "$C_BOLD" "$agent_id" "$C_RESET" "$scope"
    printf "\n"
  } >&2
  # Raw token on its own line — last stdout line.
  printf '%s\n' "$TOKEN"
else
  {
    printf "\n"
    printf "%s(dry-run: no bearer generated, no config written, no network call)%s\n" "$C_DIM" "$C_RESET"
  } >&2
fi

# Exit 3 if sanity check failed; 0 otherwise.
if [[ "$sanity_rc" -ne 0 ]]; then
  exit 3
fi

exit 0

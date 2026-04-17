#!/usr/bin/env bash
#
# hydra-mcp-register-agent.sh — generate a bearer token for a new MCP client
# agent, store its SHA-256 hash in state/connectors/mcp.json, and print the raw
# token ONCE so the operator can paste it into the consuming agent's config.
#
# Usage: ./hydra mcp register-agent <agent-id> [--rotate]
#
# Security invariants (see docs/specs/2026-04-17-mcp-register-agent.md §Risks):
#   - Raw token is written to stdout EXACTLY ONCE and never written to any file.
#   - Token is never passed as a positional argument to any subprocess — the
#     SHA-256 hash is computed by piping the token to shasum/sha256sum via
#     stdin, so the token doesn't land in /proc/*/cmdline or ps output.
#   - Atomic config update: tmpfile in the same dir + mv. No partial state.
#   - Refuses (exit 1) if an entry with <agent-id> already exists, unless
#     --rotate is passed — in which case only token_hash is replaced.
#
# Spec: docs/specs/2026-04-17-mcp-register-agent.md (ticket #84)

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"

# shellcheck disable=SC1091
[[ -f "$ROOT_DIR/.hydra.env" ]] && source "$ROOT_DIR/.hydra.env"

usage() {
  cat <<'EOF'
Usage: ./hydra mcp register-agent <agent-id> [options]

Generate a 32-byte bearer token for a new MCP client agent, hash it with
SHA-256, and append a new entry to state/connectors/mcp.json. Prints the
raw token to stdout EXACTLY ONCE — copy it immediately into the consuming
agent's config; the hash is the only thing Hydra keeps on disk.

Arguments:
  <agent-id>        Required. Free-form label for the agent (e.g. "openclaw",
                    "discord-bridge", "my-laptop-claude"). Must be unique in
                    state/connectors/mcp.json:authorized_agents[].id.

Options:
  --rotate          Replace the token_hash on an EXISTING entry with
                    <agent-id>. Preserves scope + id. Fails if no entry
                    exists (use register-agent without --rotate for new
                    agents).
  -h, --help        Show this help.

Environment:
  HYDRA_MCP_REGISTER_CONFIG
                    Override the path to the mcp.json file being edited.
                    Defaults to state/connectors/mcp.json under the repo
                    root. Used by self-test fixtures to target a tmpdir.

Exit codes:
  0   token registered (or rotated). Raw token printed to stdout.
  1   I/O error, missing jq, duplicate agent-id without --rotate, or
      --rotate against an unknown id.
  2   usage error (missing agent-id, unknown flag).

Security notes:
  - Raw token never touches disk. Only SHA-256 hash is persisted.
  - Run this on a trusted terminal; the token is printed to stdout.
  - Scope defaults to ["read"] for new entries. Widen by editing
    state/connectors/mcp.json directly AFTER the entry is created.

Example:
  # First-time registration.
  ./hydra mcp register-agent openclaw
  # → prints a 44-char base64 token; copy it to the consumer NOW.

  # Rotate the token for an existing agent.
  ./hydra mcp register-agent openclaw --rotate
  # → prints a new token; old token is immediately invalid.
EOF
}

# -----------------------------------------------------------------------------
# color
# -----------------------------------------------------------------------------
if [[ -t 2 ]] && [[ "${NO_COLOR:-}" != "1" ]]; then
  C_GREEN=$'\033[32m'
  C_RED=$'\033[31m'
  C_YELLOW=$'\033[33m'
  C_BOLD=$'\033[1m'
  C_RESET=$'\033[0m'
else
  C_GREEN=""; C_RED=""; C_YELLOW=""; C_BOLD=""; C_RESET=""
fi

err()  { printf "%s✗%s %s\n" "$C_RED"    "$C_RESET" "$*" >&2; }
ok()   { printf "%s✓%s %s\n" "$C_GREEN"  "$C_RESET" "$*" >&2; }
warn() { printf "%s⚠%s %s\n" "$C_YELLOW" "$C_RESET" "$*" >&2; }

# -----------------------------------------------------------------------------
# args
# -----------------------------------------------------------------------------
agent_id=""
rotate=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --rotate) rotate=1; shift ;;
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

# Validate agent-id shape — keep it simple to avoid JSON-injection / shell
# surprises later. Letters, digits, dashes, underscores, dots. No spaces.
if ! [[ "$agent_id" =~ ^[A-Za-z0-9._-]+$ ]]; then
  err "invalid agent-id '$agent_id' — allowed: [A-Za-z0-9._-]"
  exit 2
fi

# -----------------------------------------------------------------------------
# prerequisites
# -----------------------------------------------------------------------------
if ! command -v jq >/dev/null 2>&1; then
  err "jq is required — brew install jq (macOS) or apt install jq (Debian)"
  exit 1
fi

# Pick the platform's sha256 tool. macOS has shasum; most Linux has sha256sum.
# We deliberately do NOT fall back to openssl (its output format varies across
# versions — `(stdin)= <hex>` vs bare hex — and parsing it adds complexity).
if command -v sha256sum >/dev/null 2>&1; then
  sha256_cmd=(sha256sum)
elif command -v shasum >/dev/null 2>&1; then
  sha256_cmd=(shasum -a 256)
else
  err "neither sha256sum nor shasum found on PATH — install one"
  err "  macOS: shasum is in /usr/bin (should be preinstalled)"
  err "  Debian: apt install coreutils"
  exit 1
fi

# -----------------------------------------------------------------------------
# locate config file
# -----------------------------------------------------------------------------
mcp_file="${HYDRA_MCP_REGISTER_CONFIG:-$ROOT_DIR/state/connectors/mcp.json}"
mcp_example="$ROOT_DIR/state/connectors/mcp.json.example"

if [[ ! -f "$mcp_file" ]]; then
  if [[ ! -f "$mcp_example" ]]; then
    err "config missing: $mcp_file"
    err "  and no template at: $mcp_example"
    exit 1
  fi
  warn "config missing — bootstrapping from $(basename "$mcp_example")"
  # Bootstrap: copy the template, then clear the two placeholder
  # authorized_agents entries so we don't ship fake SHA256 hashes. Keep
  # every other field (server, upstream_supervisor, audit).
  bootstrap_tmp="$(mktemp "$(dirname "$mcp_file")/.mcp.bootstrap.XXXXXX")"
  # shellcheck disable=SC2064
  trap "rm -f '$bootstrap_tmp'" EXIT
  jq '.authorized_agents = []' "$mcp_example" > "$bootstrap_tmp"
  mv "$bootstrap_tmp" "$mcp_file"
  trap - EXIT
fi

if ! jq empty "$mcp_file" 2>/dev/null; then
  err "config is not valid JSON: $mcp_file"
  exit 1
fi

# -----------------------------------------------------------------------------
# duplicate detection
# -----------------------------------------------------------------------------
existing_count=$(
  jq --arg id "$agent_id" \
    '[.authorized_agents // [] | .[] | select(.id == $id)] | length' \
    "$mcp_file"
)

if [[ "$rotate" -eq 1 ]]; then
  if [[ "$existing_count" == "0" ]]; then
    err "--rotate requires an existing entry for agent-id '$agent_id', but none was found"
    err "  (if this is a new agent, run without --rotate)"
    exit 1
  fi
  if [[ "$existing_count" != "1" ]]; then
    # Defensive: the config has been hand-edited to contain duplicates. Refuse
    # rather than guess which one to rotate.
    err "expected exactly 1 existing entry for '$agent_id', found $existing_count"
    err "  fix state/connectors/mcp.json by hand before retrying --rotate"
    exit 1
  fi
else
  if [[ "$existing_count" != "0" ]]; then
    err "agent-id '$agent_id' is already registered"
    err "  use --rotate to replace the token_hash (preserves scope),"
    err "  or pick a different agent-id"
    exit 1
  fi
fi

# -----------------------------------------------------------------------------
# generate token — /dev/urandom + base64
# -----------------------------------------------------------------------------
#
# 32 random bytes → base64 → strip newlines. On some base64 implementations
# line-wrap at 76 columns kicks in; we want a single-line token. We also
# consider padding: 32 bytes of base64 with padding is 44 chars; without
# padding it's 43. We keep whatever the local base64 produces.
#
# We do NOT use `mktemp` or any intermediate file for the token — it lives
# only in this shell variable and is emitted once to stdout at the end.

if [[ ! -r /dev/urandom ]]; then
  err "cannot read /dev/urandom — can't generate secure random bytes"
  exit 1
fi

token="$(head -c 32 /dev/urandom | base64 | tr -d '\n')"

# Sanity-check length. 32 random bytes in base64 is 43 (no padding) or 44
# (with padding) — if we got something wildly different, bail rather than
# ship a weak token.
token_len=${#token}
if [[ "$token_len" -lt 43 ]]; then
  err "generated token has unexpected length $token_len (expected 43+)"
  err "  base64 output may be truncated — check head / base64 / tr installation"
  exit 1
fi

# -----------------------------------------------------------------------------
# hash via stdin pipe — token never touches disk
# -----------------------------------------------------------------------------
#
# printf '%s' avoids the trailing newline that `echo` would add (which would
# make the hash mismatch when the server later hashes the token it received
# over the wire). We capture stdout, extract just the hex digest (both
# shasum and sha256sum print `<hex>  <filename-or-dash>`).

hash=$(printf '%s' "$token" | "${sha256_cmd[@]}" 2>/dev/null | awk '{print $1}')

# Validate hash shape — exactly 64 lowercase hex chars.
if ! [[ "$hash" =~ ^[0-9a-f]{64}$ ]]; then
  err "SHA-256 hashing failed — got unexpected output shape"
  exit 1
fi

# -----------------------------------------------------------------------------
# write config atomically (tmpfile in same dir + mv)
# -----------------------------------------------------------------------------
#
# Tempfile MUST be in the same directory as the target; mv is only atomic
# within a filesystem. /tmp may be on a tmpfs.

tmp="$(mktemp "$(dirname "$mcp_file")/.mcp.register.XXXXXX")"
# shellcheck disable=SC2064
trap "rm -f '$tmp'" EXIT

if [[ "$rotate" -eq 1 ]]; then
  # Replace only token_hash on the matching entry — scope, id, and any
  # other operator-added fields are preserved.
  jq --arg id "$agent_id" --arg hash "SHA256:$hash" \
    '.authorized_agents = ((.authorized_agents // []) | map(
       if .id == $id then .token_hash = $hash else . end
    ))' \
    "$mcp_file" > "$tmp"
else
  # Append a new entry with scope=["read"]. Deliberately narrow — operators
  # widen to spawn/merge/admin by editing the file after the CLI run.
  jq --arg id "$agent_id" --arg hash "SHA256:$hash" \
    '.authorized_agents = ((.authorized_agents // []) + [{
       id: $id,
       token_hash: $hash,
       scope: ["read"]
    }])' \
    "$mcp_file" > "$tmp"
fi

# Sanity: the entry should exist in the tmp file with the expected hash.
written_hash=$(
  jq -r --arg id "$agent_id" \
    '[.authorized_agents // [] | .[] | select(.id == $id) | .token_hash][0] // ""' \
    "$tmp"
)
if [[ "$written_hash" != "SHA256:$hash" ]]; then
  err "post-write consistency check failed — refusing to swap config"
  exit 1
fi

# Atomic swap.
mv "$tmp" "$mcp_file"
trap - EXIT

# -----------------------------------------------------------------------------
# emit token — EXACTLY ONCE to stdout, warning to stderr
# -----------------------------------------------------------------------------
#
# stdout = raw token only (so callers can pipe into `fly secrets set` etc.).
# stderr = everything else (warning, status, hash path). This lets the
# operator redirect stdout to a password manager or secret store without
# losing the banner.

printf '%s\n' "$token"

if [[ "$rotate" -eq 1 ]]; then
  action="rotated"
else
  action="registered"
fi

{
  printf "\n"
  printf "%s⚠ This is the only time this token will be shown.%s\n" "$C_BOLD$C_YELLOW" "$C_RESET"
  printf "  Copy it into the consuming agent's config NOW.\n"
  printf "\n"
  printf "  %s agent-id=%s%s%s\n" "$action" "$C_BOLD" "$agent_id" "$C_RESET"
  if [[ "$rotate" -ne 1 ]]; then
    printf "  scope=[read] — widen by editing the config if needed\n"
  fi
  printf "  Hash stored in %s\n" "$mcp_file"
} >&2

ok "done"
exit 0

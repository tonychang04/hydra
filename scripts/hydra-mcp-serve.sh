#!/usr/bin/env bash
#
# hydra-mcp-serve.sh — launch Hydra's MCP server (agent-only interface).
#
# Usage: ./hydra mcp serve [--transport http|stdio] [--port N] [--bind ADDR] [--check]
#
# This is the thin shell wrapper; the real logic lives in
# scripts/hydra-mcp-server.py. Keeping it separate means operators can run
# the Python server directly in environments that don't have our bash shim
# (e.g. under a different process supervisor), and it matches the pattern
# used by the other ./hydra subcommands (scripts/hydra-status.sh,
# scripts/hydra-pause.sh, etc.).
#
# Spec: docs/specs/2026-04-17-mcp-server-binary.md (ticket #72)
# Tool contract: mcp/hydra-tools.json

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"

# shellcheck disable=SC1091
[[ -f "$ROOT_DIR/.hydra.env" ]] && source "$ROOT_DIR/.hydra.env"

usage() {
  cat <<'EOF'
Usage: ./hydra mcp serve [options]

Launch the Hydra MCP server. Serves the agent-only interface defined in
mcp/hydra-tools.json over HTTP (JSON-RPC 2.0) for authorized client agents.

Options:
  --transport {http,stdio}  Transport (default http; stdio is a follow-up).
  --port N                  HTTP port (default 8765; env HYDRA_MCP_PORT).
  --bind ADDR               Bind address (default 127.0.0.1; env HYDRA_MCP_BIND).
  --check                   Validate config + tools and exit 0 without binding.
  -h, --help                Show this help.

Prerequisites:
  - state/connectors/mcp.json exists with at least one authorized_agents[] entry
  - mcp/hydra-tools.json is present (always committed in the repo)
  - python3 is on PATH (Fly image has it)

Exit codes:
  0   Server started OK (or --check passed)
  1   Config missing / invalid / no authorized agents
  2   Usage error / unsupported transport
EOF
}

for arg in "$@"; do
  case "$arg" in
    -h|--help) usage; exit 0 ;;
  esac
done

# Phase 1 hard-requires python3. Fly image has it; local macOS dev has it.
if ! command -v python3 >/dev/null 2>&1; then
  echo "✗ python3 not found on PATH — the MCP server is a Python script." >&2
  echo "  Install python3 (brew install python on macOS; apt install python3 on Debian)." >&2
  exit 1
fi

# Respect the big red off-switch in entrypoint.sh. If HYDRA_MCP_ENABLED=0 is
# set explicitly, refuse to launch (operator rollback path per the spec's
# §Risks / rollback section).
if [[ "${HYDRA_MCP_ENABLED:-1}" == "0" ]]; then
  echo "⚠ HYDRA_MCP_ENABLED=0 — refusing to launch MCP server (operator opt-out)." >&2
  exit 0
fi

exec python3 "$SCRIPT_DIR/hydra-mcp-server.py" "$@"

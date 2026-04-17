#!/usr/bin/env bash
#
# Self-test fixture for scripts/hydra-pair-agent.sh (spec:
# docs/specs/2026-04-17-pair-agent.md, ticket #124).
#
# Exercises the --dry-run path end-to-end: generates no bearer, mutates
# no state, makes no network call. Verifies:
#
#   (a) exit 0 on --dry-run
#   (b) all four recipe block headers present in stdout:
#         Claude Code:
#         Cursor / mcpServers JSON:
#         OpenClaw / Codex-CLI / generic MCP:
#         Raw curl
#   (c) placeholder <token-would-go-here> present in stdout
#   (d) no 43+ char base64-shaped string (i.e. no real-token-looking
#       string) leaked to stdout
#   (e) --editor claude-code prints ONLY the Claude Code block
#   (f) invalid --scope exits 2
#   (g) no arg exits 2 with usage error
#   (h) state/connectors/mcp.json is NOT created by --dry-run (no side
#       effects on config)
#
# Prints "PASS" to stdout on success; non-zero exit on any mismatch.
# Safe to re-run (tmpdir-isolated; never touches the real state tree).

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd -- "$SCRIPT_DIR/../../.." && pwd)"
SCRIPT="$ROOT_DIR/scripts/hydra-pair-agent.sh"

[[ -x "$SCRIPT" ]] || { echo "FAIL: $SCRIPT not executable"; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Point the register-agent config at a tmpdir path; even though --dry-run
# never invokes the primitive, this belt-and-suspenders ensures a bug
# that regresses the dry-run guard still wouldn't touch the real config.
export HYDRA_MCP_REGISTER_CONFIG="$TMP/mcp.json"
export NO_COLOR=1

# ---------------------------------------------------------------------------
# (a) + (b) + (c) + (d) all four recipes, placeholder, no token leak
# ---------------------------------------------------------------------------
STDOUT="$("$SCRIPT" --dry-run pair-fixture 2>"$TMP/stderr-all")"
RC=$?
if [[ "$RC" -ne 0 ]]; then
  echo "FAIL (a): --dry-run exited $RC (expected 0)"
  cat "$TMP/stderr-all"
  exit 1
fi

# Block headers are printed to stderr (block titles are bold-on-stderr, body
# plain-on-stdout — by design so stdout is copy-pasteable). For assertion
# purposes we concatenate the two streams.
ALL="$STDOUT"$'\n'"$(cat "$TMP/stderr-all")"

for marker in \
  "Claude Code:" \
  "Cursor / mcpServers JSON:" \
  "OpenClaw / Codex-CLI / generic MCP:" \
  "Raw curl"
do
  if ! printf '%s' "$ALL" | grep -qF "$marker"; then
    echo "FAIL (b): recipe block header '$marker' not found in combined output"
    echo "=== combined output ==="
    printf '%s\n' "$ALL"
    exit 1
  fi
done

if ! printf '%s' "$STDOUT" | grep -qF "<token-would-go-here>"; then
  echo "FAIL (c): placeholder '<token-would-go-here>' not found in stdout"
  echo "=== stdout ==="
  printf '%s\n' "$STDOUT"
  exit 1
fi

# (d) No real-token-shaped string. The register-agent primitive emits
# 43-44 char base64 tokens (letters, digits, +, /, =, no spaces, no dashes).
# A placeholder contains angle brackets and dashes so it naturally won't
# match. Scan stdout for any standalone 43+ char base64 run — if found,
# the dry-run guard has regressed.
if printf '%s' "$STDOUT" | grep -Eq '(^|[[:space:]"])[A-Za-z0-9+/]{43,}={0,2}([[:space:]"]|$)'; then
  echo "FAIL (d): stdout contains a base64-shaped string 43+ chars (real token leak suspected)"
  echo "=== stdout ==="
  printf '%s\n' "$STDOUT"
  exit 1
fi

# ---------------------------------------------------------------------------
# (e) --editor claude-code → only Claude Code block
# ---------------------------------------------------------------------------
STDOUT_CC="$("$SCRIPT" --dry-run --editor claude-code pair-fixture-cc 2>"$TMP/stderr-cc")"
ALL_CC="$STDOUT_CC"$'\n'"$(cat "$TMP/stderr-cc")"

if ! printf '%s' "$ALL_CC" | grep -qF "Claude Code:"; then
  echo "FAIL (e): --editor claude-code output missing Claude Code block"
  exit 1
fi
# Other blocks must be ABSENT.
for marker in \
  "Cursor / mcpServers JSON:" \
  "OpenClaw / Codex-CLI / generic MCP:" \
  "Raw curl"
do
  if printf '%s' "$ALL_CC" | grep -qF "$marker"; then
    echo "FAIL (e'): --editor claude-code leaked '$marker' (expected only Claude Code block)"
    exit 1
  fi
done

# ---------------------------------------------------------------------------
# (f) invalid --scope → exit 2
# ---------------------------------------------------------------------------
set +e
"$SCRIPT" --dry-run --scope bogus bad-scope-agent >"$TMP/scope-stdout" 2>"$TMP/scope-stderr"
RC=$?
set -e
if [[ "$RC" -ne 2 ]]; then
  echo "FAIL (f): invalid --scope exited $RC (expected 2)"
  cat "$TMP/scope-stderr"
  exit 1
fi

# ---------------------------------------------------------------------------
# (g) no arg → exit 2
# ---------------------------------------------------------------------------
set +e
"$SCRIPT" >"$TMP/noarg-stdout" 2>"$TMP/noarg-stderr"
RC=$?
set -e
if [[ "$RC" -ne 2 ]]; then
  echo "FAIL (g): no-arg exited $RC (expected 2)"
  cat "$TMP/noarg-stderr"
  exit 1
fi
if ! grep -qF "missing required <agent-id>" "$TMP/noarg-stderr"; then
  echo "FAIL (g'): no-arg stderr did not mention missing agent-id"
  cat "$TMP/noarg-stderr"
  exit 1
fi

# ---------------------------------------------------------------------------
# (h) --dry-run did NOT create the mcp.json file at HYDRA_MCP_REGISTER_CONFIG
# ---------------------------------------------------------------------------
if [[ -f "$HYDRA_MCP_REGISTER_CONFIG" ]]; then
  echo "FAIL (h): --dry-run created $HYDRA_MCP_REGISTER_CONFIG (expected untouched)"
  exit 1
fi

echo "PASS"

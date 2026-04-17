#!/usr/bin/env bash
#
# Self-test for scripts/hydra-mcp-register-agent.sh (spec:
# docs/specs/2026-04-17-mcp-register-agent.md, ticket #84).
#
# Exercises the full token-generation + config-update flow end-to-end
# against a tmpdir config — the real state/connectors/mcp.json is never
# touched. Verifies five assertions from the ticket acceptance:
#
#   (a) exit 0 on first-use
#   (b) stdout token is 43+ chars base64
#   (c) SHA-256 of the printed token matches the hash in the config
#   (d) --rotate succeeds on a second call for the same agent-id,
#       produces a different token, preserves scope, and doesn't create
#       a duplicate entry
#   (e) non-rotate second call with the same agent-id exits 1 and
#       leaves the config byte-for-byte unchanged
#
# Plus two extras:
#   (f) --rotate on an unknown agent-id exits 1 with no writes
#   (g) auto-bootstrap: running against a tmpdir with no mcp.json
#       copies from mcp.json.example, clears placeholder agents, and
#       writes the new entry
#
# Prints "PASS" to stdout on success; non-zero exit on any mismatch.
# Safe to re-run (every invocation uses a fresh tmpdir).

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd -- "$SCRIPT_DIR/../../.." && pwd)"
SCRIPT="$ROOT_DIR/scripts/hydra-mcp-register-agent.sh"
EXAMPLE="$ROOT_DIR/state/connectors/mcp.json.example"

have() { command -v "$1" >/dev/null 2>&1; }
have jq || { echo "FAIL: jq not on PATH"; exit 1; }
have python3 || { echo "FAIL: python3 not on PATH"; exit 1; }

# Pick a sha256 tool (same logic as the script).
if have sha256sum; then
  sha256_cmd=(sha256sum)
elif have shasum; then
  sha256_cmd=(shasum -a 256)
else
  echo "FAIL: neither sha256sum nor shasum on PATH"
  exit 1
fi

[[ -x "$SCRIPT" ]] || { echo "FAIL: $SCRIPT not executable"; exit 1; }
[[ -f "$EXAMPLE" ]] || { echo "FAIL: $EXAMPLE missing"; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

MCP_DIR="$TMP/state/connectors"
mkdir -p "$MCP_DIR"
MCP="$MCP_DIR/mcp.json"

# Seed config from example, with authorized_agents pruned to empty (so
# we don't ship fake SHA256 placeholders into the test config).
jq '.authorized_agents = []' "$EXAMPLE" > "$MCP"

AGENT_ID="selftest-$$"

# ---------------------------------------------------------------------------
# (a) + (b) + (c) first-use happy path
# ---------------------------------------------------------------------------
STDOUT="$(HYDRA_MCP_REGISTER_CONFIG="$MCP" NO_COLOR=1 "$SCRIPT" "$AGENT_ID" 2>"$TMP/stderr-1")"
RC=$?
if [[ "$RC" -ne 0 ]]; then
  echo "FAIL (a): first-use exited with $RC (expected 0)"
  cat "$TMP/stderr-1"
  exit 1
fi

# stdout should be exactly one line — the token.
LINECOUNT=$(printf '%s\n' "$STDOUT" | wc -l | tr -d ' ')
if [[ "$LINECOUNT" != "1" ]]; then
  echo "FAIL (a'): stdout had $LINECOUNT lines (expected 1 — the token)"
  echo "stdout: $STDOUT"
  exit 1
fi

TOKEN="$STDOUT"
TOKEN_LEN=${#TOKEN}
if [[ "$TOKEN_LEN" -lt 43 ]]; then
  echo "FAIL (b): token length $TOKEN_LEN (expected >= 43)"
  exit 1
fi

# Token must be base64-shaped (letters, digits, +, /, =).
if ! printf '%s' "$TOKEN" | grep -Eq '^[A-Za-z0-9+/=]+$'; then
  echo "FAIL (b'): token is not base64-shaped: $TOKEN"
  exit 1
fi

WANT_HASH=$(printf '%s' "$TOKEN" | "${sha256_cmd[@]}" | awk '{print $1}')
GOT_HASH=$(jq -r --arg id "$AGENT_ID" \
  '[.authorized_agents[] | select(.id == $id) | .token_hash][0]' "$MCP" \
  | sed 's/^SHA256://')
if [[ "$WANT_HASH" != "$GOT_HASH" ]]; then
  echo "FAIL (c): SHA-256 mismatch"
  echo "  want (hash of stdout token): $WANT_HASH"
  echo "  got  (in config):            $GOT_HASH"
  exit 1
fi

# Scope should be ["read"] by default.
SCOPE=$(jq -c --arg id "$AGENT_ID" \
  '[.authorized_agents[] | select(.id == $id) | .scope][0]' "$MCP")
if [[ "$SCOPE" != '["read"]' ]]; then
  echo "FAIL (c'): new entry scope is $SCOPE (expected [\"read\"])"
  exit 1
fi

# ---------------------------------------------------------------------------
# (e) duplicate without --rotate → exit 1, config unchanged
# ---------------------------------------------------------------------------
BEFORE_HASH=$(shasum "$MCP" 2>/dev/null | awk '{print $1}' || sha256sum "$MCP" | awk '{print $1}')
set +e
HYDRA_MCP_REGISTER_CONFIG="$MCP" NO_COLOR=1 "$SCRIPT" "$AGENT_ID" >"$TMP/dup-stdout" 2>"$TMP/dup-stderr"
RC=$?
set -e
if [[ "$RC" -ne 1 ]]; then
  echo "FAIL (e): duplicate call exited $RC (expected 1)"
  cat "$TMP/dup-stderr"
  exit 1
fi
if [[ -s "$TMP/dup-stdout" ]]; then
  echo "FAIL (e'): duplicate call wrote to stdout (token leaked?)"
  cat "$TMP/dup-stdout"
  exit 1
fi
AFTER_HASH=$(shasum "$MCP" 2>/dev/null | awk '{print $1}' || sha256sum "$MCP" | awk '{print $1}')
if [[ "$BEFORE_HASH" != "$AFTER_HASH" ]]; then
  echo "FAIL (e''): duplicate call modified the config (atomicity broken)"
  exit 1
fi

# ---------------------------------------------------------------------------
# (d) --rotate → new token, scope preserved, still exactly 1 entry
# ---------------------------------------------------------------------------
STDOUT2="$(HYDRA_MCP_REGISTER_CONFIG="$MCP" NO_COLOR=1 "$SCRIPT" "$AGENT_ID" --rotate 2>"$TMP/rotate-stderr")"
RC=$?
if [[ "$RC" -ne 0 ]]; then
  echo "FAIL (d): --rotate exited $RC (expected 0)"
  cat "$TMP/rotate-stderr"
  exit 1
fi
TOKEN2="$STDOUT2"
if [[ "$TOKEN" == "$TOKEN2" ]]; then
  echo "FAIL (d'): --rotate produced the SAME token (entropy collapsed?)"
  exit 1
fi

COUNT=$(jq -r --arg id "$AGENT_ID" \
  '[.authorized_agents[] | select(.id == $id)] | length' "$MCP")
if [[ "$COUNT" != "1" ]]; then
  echo "FAIL (d''): after --rotate there are $COUNT entries (expected 1)"
  exit 1
fi

# Scope must still be ["read"] — --rotate must not touch it.
SCOPE2=$(jq -c --arg id "$AGENT_ID" \
  '[.authorized_agents[] | select(.id == $id) | .scope][0]' "$MCP")
if [[ "$SCOPE2" != '["read"]' ]]; then
  echo "FAIL (d'''): --rotate changed scope to $SCOPE2 (expected [\"read\"])"
  exit 1
fi

# The new hash should match the new token.
WANT_HASH2=$(printf '%s' "$TOKEN2" | "${sha256_cmd[@]}" | awk '{print $1}')
GOT_HASH2=$(jq -r --arg id "$AGENT_ID" \
  '[.authorized_agents[] | select(.id == $id) | .token_hash][0]' "$MCP" \
  | sed 's/^SHA256://')
if [[ "$WANT_HASH2" != "$GOT_HASH2" ]]; then
  echo "FAIL (d''''): post-rotate hash mismatch"
  exit 1
fi

# ---------------------------------------------------------------------------
# (f) --rotate on unknown id → exit 1, no writes
# ---------------------------------------------------------------------------
BEFORE_HASH=$(shasum "$MCP" 2>/dev/null | awk '{print $1}' || sha256sum "$MCP" | awk '{print $1}')
set +e
HYDRA_MCP_REGISTER_CONFIG="$MCP" NO_COLOR=1 "$SCRIPT" "no-such-agent-id" --rotate \
  >"$TMP/rot-unk-stdout" 2>"$TMP/rot-unk-stderr"
RC=$?
set -e
if [[ "$RC" -ne 1 ]]; then
  echo "FAIL (f): --rotate on unknown id exited $RC (expected 1)"
  cat "$TMP/rot-unk-stderr"
  exit 1
fi
if [[ -s "$TMP/rot-unk-stdout" ]]; then
  echo "FAIL (f'): --rotate on unknown id leaked stdout"
  exit 1
fi
AFTER_HASH=$(shasum "$MCP" 2>/dev/null | awk '{print $1}' || sha256sum "$MCP" | awk '{print $1}')
if [[ "$BEFORE_HASH" != "$AFTER_HASH" ]]; then
  echo "FAIL (f''): --rotate on unknown id modified the config"
  exit 1
fi

# ---------------------------------------------------------------------------
# (g) auto-bootstrap: no existing mcp.json → copy from example, strip
#     placeholder authorized_agents, append new entry
# ---------------------------------------------------------------------------
BOOT_DIR="$TMP/boot/state/connectors"
mkdir -p "$BOOT_DIR"
BOOT_MCP="$BOOT_DIR/mcp.json"
# NOTE: intentionally do NOT seed — the script should auto-copy from example.

BOOT_STDOUT="$(HYDRA_MCP_REGISTER_CONFIG="$BOOT_MCP" NO_COLOR=1 "$SCRIPT" "boot-agent" 2>"$TMP/boot-stderr")"
RC=$?
if [[ "$RC" -ne 0 ]]; then
  echo "FAIL (g): auto-bootstrap exited $RC (expected 0)"
  cat "$TMP/boot-stderr"
  exit 1
fi

if [[ ! -f "$BOOT_MCP" ]]; then
  echo "FAIL (g'): auto-bootstrap did not create $BOOT_MCP"
  exit 1
fi

if ! jq empty "$BOOT_MCP" 2>/dev/null; then
  echo "FAIL (g''): bootstrapped config is not valid JSON"
  exit 1
fi

BOOT_COUNT=$(jq -r '[.authorized_agents[]] | length' "$BOOT_MCP")
if [[ "$BOOT_COUNT" != "1" ]]; then
  echo "FAIL (g'''): bootstrapped config has $BOOT_COUNT entries (expected 1)"
  exit 1
fi

# No fake SHA256:REPLACE_... hashes should be in the bootstrapped file.
if grep -q 'SHA256:REPLACE' "$BOOT_MCP"; then
  echo "FAIL (g''''): bootstrap did not strip placeholder authorized_agents"
  grep 'SHA256:REPLACE' "$BOOT_MCP"
  exit 1
fi

# Confirm the 'server' section was preserved from the example.
if ! jq -e '.server.transport' "$BOOT_MCP" >/dev/null 2>&1; then
  echo "FAIL (g'''''): bootstrap lost the 'server' section from the template"
  exit 1
fi

echo "PASS"

#!/usr/bin/env bash
#
# Integration smoke test for scripts/hydra-mcp-server.py (spec:
# docs/specs/2026-04-17-mcp-server-binary.md, ticket #72).
#
# Exercises the full auth + scope + dispatch + audit flow end-to-end against
# a real running server on a random free port:
#
#   1. Starts the server in the background with a fixture mcp.json.
#   2. Sends tools/list with a valid bearer → expects 13 tools.
#   3. Sends tools/call hydra.get_status → expects the documented shape.
#   4. Sends with a bad bearer → expects HTTP 401.
#   5. Sends tools/call hydra.pause with a read-only bearer → expects HTTP 403.
#   6. Sends tools/call hydra.merge_pr (bogus PR) → expects t3-refused.
#   7. Sends tools/call hydra.resume (scaffolded) → expects JSON-RPC -32001.
#   8. Asserts logs/mcp-audit.jsonl contains one line per call.
#
# Prints "PASS" to stdout on success; non-zero exit on any mismatch. Safe to
# re-run (every invocation uses a fresh tmpdir + fresh port).

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd -- "$SCRIPT_DIR/../../.." && pwd)"

have() { command -v "$1" >/dev/null 2>&1; }

have python3 || { echo "FAIL: python3 not on PATH"; exit 1; }
have curl    || { echo "FAIL: curl not on PATH"; exit 1; }

TMP="$(mktemp -d)"
trap 'kill $SERVER_PID 2>/dev/null || true; wait $SERVER_PID 2>/dev/null || true; rm -rf "$TMP"' EXIT

# --- stage fixture config ---------------------------------------------------
ADMIN_TOKEN="mcp-smoke-admin-$$"
READONLY_TOKEN="mcp-smoke-readonly-$$"
ADMIN_HASH=$(python3 -c "import hashlib; print(hashlib.sha256('$ADMIN_TOKEN'.encode()).hexdigest())")
READONLY_HASH=$(python3 -c "import hashlib; print(hashlib.sha256('$READONLY_TOKEN'.encode()).hexdigest())")

cat > "$TMP/mcp.json" <<EOF
{
  "authorized_agents": [
    {"id": "smoke-admin", "token_hash": "$ADMIN_HASH", "scope": ["read", "spawn", "merge", "admin"]},
    {"id": "smoke-readonly", "token_hash": "$READONLY_HASH", "scope": ["read"]}
  ]
}
EOF

PORT=$(python3 -c "import socket; s=socket.socket(); s.bind(('127.0.0.1',0)); print(s.getsockname()[1]); s.close()")

# --- start the server -------------------------------------------------------
HYDRA_MCP_CONFIG="$TMP/mcp.json" \
HYDRA_MCP_AUDIT_LOG="$TMP/audit.jsonl" \
HYDRA_MCP_PAUSE_FILE="$TMP/PAUSE" \
  python3 "$ROOT_DIR/scripts/hydra-mcp-server.py" --port "$PORT" --bind 127.0.0.1 \
  >"$TMP/server.log" 2>&1 &
SERVER_PID=$!

# Wait for bind (up to ~3s).
for _ in 1 2 3 4 5 6 7 8 9 10; do
  if curl -sf -o /dev/null "http://127.0.0.1:$PORT/" 2>/dev/null; then
    break
  fi
  sleep 0.3
done

if ! curl -sf -o /dev/null "http://127.0.0.1:$PORT/" 2>/dev/null; then
  echo "FAIL: server did not bind on port $PORT"
  cat "$TMP/server.log"
  exit 1
fi

# Small helper — POST JSON-RPC with a given bearer, return the body.
post() {
  local bearer="$1"; shift
  local body="$1"; shift
  curl -s -X POST "http://127.0.0.1:$PORT/mcp" \
    -H "Authorization: Bearer $bearer" \
    -H "Content-Type: application/json" \
    -d "$body"
}

status_code() {
  local bearer="$1"; shift
  local body="$1"; shift
  curl -s -o /dev/null -w "%{http_code}" -X POST "http://127.0.0.1:$PORT/mcp" \
    -H "Authorization: Bearer $bearer" \
    -H "Content-Type: application/json" \
    -d "$body"
}

# --- 1) tools/list ----------------------------------------------------------
RESP=$(post "$ADMIN_TOKEN" '{"jsonrpc":"2.0","id":1,"method":"tools/list"}')
COUNT=$(printf '%s' "$RESP" > "$TMP/tools-list.json" && python3 -c "import json; print(len(json.load(open('$TMP/tools-list.json'))['result']['tools']))")
if [[ "$COUNT" != "13" ]]; then
  echo "FAIL: tools/list returned $COUNT tools (expected 13)"
  echo "body: $RESP"
  exit 1
fi

# Verify every advertised tool has name/description/inputSchema.
python3 -c "
import json, sys
d = json.load(open('$TMP/tools-list.json'))
for t in d['result']['tools']:
    assert t.get('name', '').startswith('hydra.'), f'bad name: {t}'
    assert t.get('description'), f'missing description: {t}'
    assert isinstance(t.get('inputSchema'), dict), f'missing inputSchema: {t}'
print('tools/list shape OK')
"

# --- 2) hydra.get_status ----------------------------------------------------
RESP=$(post "$ADMIN_TOKEN" '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"hydra.get_status","arguments":{}}}')
printf '%s' "$RESP" > "$TMP/get-status.json"
python3 -c "
import json
d = json.load(open('$TMP/get-status.json'))
sc = d['result']['structuredContent']
for key in ('active_workers', 'today', 'paused', 'autopickup', 'quota_health'):
    assert key in sc, f'get_status missing {key}: {list(sc.keys())}'
assert isinstance(sc['paused'], bool)
assert isinstance(sc['active_workers'], list)
print('hydra.get_status shape OK')
"

# --- 3) bad bearer → 401 ----------------------------------------------------
CODE=$(status_code "wrong-token-xxx" '{"jsonrpc":"2.0","id":3,"method":"tools/list"}')
if [[ "$CODE" != "401" ]]; then
  echo "FAIL: bad bearer returned $CODE (expected 401)"
  exit 1
fi

# --- 4) readonly → hydra.pause → 403 ---------------------------------------
CODE=$(status_code "$READONLY_TOKEN" '{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"hydra.pause","arguments":{"reason":"smoke test"}}}')
if [[ "$CODE" != "403" ]]; then
  echo "FAIL: readonly token calling admin tool returned $CODE (expected 403)"
  exit 1
fi

# --- 5) hydra.merge_pr with bogus pr_num → t3-refused ----------------------
RESP=$(post "$ADMIN_TOKEN" '{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"hydra.merge_pr","arguments":{"pr_num":-1,"caller_agent_id":"smoke-admin"}}}')
printf '%s' "$RESP" > "$TMP/merge-pr.json"
python3 -c "
import json
d = json.load(open('$TMP/merge-pr.json'))
sc = d['result']['structuredContent']
assert sc.get('error') == 't3-refused', f'merge_pr did not refuse: {sc}'
print('hydra.merge_pr t3-refused OK')
"

# --- 6) hydra.resume (scaffolded) → JSON-RPC -32001 ------------------------
RESP=$(post "$ADMIN_TOKEN" '{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"hydra.resume","arguments":{}}}')
printf '%s' "$RESP" > "$TMP/resume.json"
python3 -c "
import json
d = json.load(open('$TMP/resume.json'))
err = d.get('error', {})
assert err.get('code') == -32001, f'resume code was {err.get(\"code\")} (expected -32001)'
assert 'Phase 1' in err.get('message', '') or 'not implemented' in err.get('message', '').lower()
print('hydra.resume NotImplemented OK')
"

# --- 7) hydra.pause (admin token) --- verifies pause path + audit -----------
RESP=$(post "$ADMIN_TOKEN" '{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"hydra.pause","arguments":{"reason":"smoke"}}}')
printf '%s' "$RESP" > "$TMP/pause.json"
python3 -c "
import json, os
d = json.load(open('$TMP/pause.json'))
sc = d['result']['structuredContent']
assert 'paused_at' in sc, f'no paused_at: {sc}'
assert os.path.exists('$TMP/PAUSE'), 'PAUSE sentinel not written'
print('hydra.pause OK')
"

# --- 8) audit log sanity ----------------------------------------------------
if [[ ! -s "$TMP/audit.jsonl" ]]; then
  echo "FAIL: audit log is empty"
  exit 1
fi
python3 -c "
import json
lines = open('$TMP/audit.jsonl').read().strip().split('\n')
assert len(lines) >= 7, f'only {len(lines)} audit lines (expected >= 7)'
for i, line in enumerate(lines):
    r = json.loads(line)
    for key in ('ts', 'caller_agent_id', 'tool', 'scope_check', 'refused_reason'):
        assert key in r, f'line {i}: missing {key}'
# At least one 'denied' (scope 403), one 'unauthenticated' (bad bearer), one
# 'ok' (successful call).
checks = {r['scope_check'] for r in (json.loads(l) for l in lines)}
for expected in ('ok', 'denied', 'unauthenticated'):
    assert expected in checks, f'missing audit scope_check={expected}: {checks}'
print(f'audit log sanity OK ({len(lines)} lines)')
"

echo "PASS"

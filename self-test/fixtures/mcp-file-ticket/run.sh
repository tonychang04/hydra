#!/usr/bin/env bash
#
# Integration smoke test for hydra.file_ticket (ticket #143, spec:
# docs/specs/2026-04-17-main-agent-filing.md).
#
# Exercises the full auth + scope + validation + rate-limit flow end-to-end
# against a real running server on a random free port:
#
#   1. Starts the server with a fixture mcp.json (spawn-scoped + read-only agents).
#   2. Stages a fake `gh` binary in PATH that logs args + prints a canned URL.
#   3. hydra.file_ticket happy path → asserts issue_number 42, right labels.
#   4. hydra.file_ticket with read-only token → HTTP 403.
#   5. hydra.file_ticket to a repo NOT in state/repos.json → repo-not-enabled.
#   6. hydra.file_ticket with title+body < 20 chars → validation error.
#   7. hydra.file_ticket with proposed_tier=T3 → will_autopickup=false + commander-stuck.
#   8. 10 successful calls, then the 11th → rate-limit error with retry_after_sec.
#
# Prints "PASS" on success; non-zero exit on any mismatch. Safe to re-run.
#
# Design note: the fake `gh` shim just captures argv and prints a canned URL.
# We are NOT testing that GitHub actually got the issue — we're testing that
# the MCP handler dispatched to `gh` with the right arguments.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd -- "$SCRIPT_DIR/../../.." && pwd)"

have() { command -v "$1" >/dev/null 2>&1; }

have python3 || { echo "FAIL: python3 not on PATH"; exit 1; }
have curl    || { echo "FAIL: curl not on PATH"; exit 1; }

TMP="$(mktemp -d)"
trap 'kill $SERVER_PID 2>/dev/null || true; wait $SERVER_PID 2>/dev/null || true; rm -rf "$TMP"' EXIT

# --- stage fixture mcp.json -------------------------------------------------
SPAWN_TOKEN="file-ticket-spawn-$$"
READONLY_TOKEN="file-ticket-readonly-$$"
SPAWN_HASH=$(python3 -c "import hashlib; print(hashlib.sha256('$SPAWN_TOKEN'.encode()).hexdigest())")
READONLY_HASH=$(python3 -c "import hashlib; print(hashlib.sha256('$READONLY_TOKEN'.encode()).hexdigest())")

cat > "$TMP/mcp.json" <<EOF
{
  "authorized_agents": [
    {"id": "spawn-agent", "token_hash": "$SPAWN_HASH", "scope": ["read", "spawn"]},
    {"id": "readonly-agent", "token_hash": "$READONLY_HASH", "scope": ["read"]}
  ]
}
EOF

# --- stage fixture repos.json (one enabled repo) ---------------------------
mkdir -p "$TMP/state"
cat > "$TMP/state/repos.json" <<'EOF'
{
  "default_ticket_trigger": "assignee",
  "repos": [
    {
      "owner": "test-owner",
      "name": "test-repo",
      "local_path": "/tmp/whatever",
      "enabled": true,
      "ticket_trigger": "assignee"
    },
    {
      "owner": "test-owner",
      "name": "disabled-repo",
      "local_path": "/tmp/whatever",
      "enabled": false,
      "ticket_trigger": "assignee"
    }
  ]
}
EOF

# --- stage fake gh shim -----------------------------------------------------
mkdir -p "$TMP/fakebin"
GH_LOG="$TMP/gh-calls.log"
cat > "$TMP/fakebin/gh" <<'GHEOF'
#!/usr/bin/env bash
# Fake gh — log args, print canned GitHub issue URL on `gh issue create`.
echo "$*" >> "$GH_LOG_PATH"
if [[ "$1" == "issue" && "$2" == "create" ]]; then
  echo "https://github.com/test-owner/test-repo/issues/42"
  exit 0
fi
exit 0
GHEOF
chmod +x "$TMP/fakebin/gh"

PORT=$(python3 -c "import socket; s=socket.socket(); s.bind(('127.0.0.1',0)); print(s.getsockname()[1]); s.close()")

# Stage the tool manifest at $TMP/mcp/ so the server picks it up via HYDRA_MCP_TOOLS.
mkdir -p "$TMP/mcp"
cp "$ROOT_DIR/mcp/hydra-tools.json" "$TMP/mcp/hydra-tools.json"

# --- start the server -------------------------------------------------------
export GH_LOG_PATH="$GH_LOG"
PATH="$TMP/fakebin:$PATH" \
HYDRA_ROOT="$TMP" \
HYDRA_MCP_CONFIG="$TMP/mcp.json" \
HYDRA_MCP_TOOLS="$TMP/mcp/hydra-tools.json" \
HYDRA_MCP_AUDIT_LOG="$TMP/audit.jsonl" \
HYDRA_MCP_PAUSE_FILE="$TMP/PAUSE" \
HYDRA_MCP_RATE_LIMIT="$TMP/mcp-rate-limit.json" \
  python3 "$ROOT_DIR/scripts/hydra-mcp-server.py" --port "$PORT" --bind 127.0.0.1 \
  >"$TMP/server.log" 2>&1 &
SERVER_PID=$!

# Wait for bind.
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

# Helpers.
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

# --- 1) happy path ----------------------------------------------------------
REQ=$(cat <<'EOF'
{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"hydra.file_ticket","arguments":{"repo":"test-owner/test-repo","title":"Add settings icon","body":"The settings page should have an icon next to each section header for visual scannability."}}}
EOF
)
RESP=$(post "$SPAWN_TOKEN" "$REQ")
printf '%s' "$RESP" > "$TMP/happy.json"
python3 -c "
import json
d = json.load(open('$TMP/happy.json'))
assert 'result' in d, f'no result: {d}'
sc = d['result']['structuredContent']
assert sc['issue_number'] == 42, f'wrong issue_number: {sc}'
assert sc['issue_url'].endswith('/issues/42'), f'wrong URL: {sc}'
assert sc['will_autopickup'] is True, f'expected will_autopickup True: {sc}'
print('1) happy path OK')
"

# Verify gh was called with the right labels.
if ! grep -q "commander-auto-filed" "$GH_LOG"; then
  echo "FAIL: gh shim log missing commander-auto-filed label"
  cat "$GH_LOG"
  exit 1
fi
if ! grep -q "commander-ready" "$GH_LOG"; then
  echo "FAIL: gh shim log missing commander-ready label"
  cat "$GH_LOG"
  exit 1
fi

# --- 2) read-only → 403 -----------------------------------------------------
CODE=$(status_code "$READONLY_TOKEN" "$REQ")
if [[ "$CODE" != "403" ]]; then
  echo "FAIL: read-only token got $CODE (expected 403)"
  exit 1
fi
echo "2) readonly→403 OK"

# --- 3) unknown repo → repo-not-enabled ------------------------------------
REQ_UNKNOWN=$(cat <<'EOF'
{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"hydra.file_ticket","arguments":{"repo":"bogus-owner/bogus-repo","title":"This repo is not enabled","body":"This body is long enough for the anti-spam check."}}}
EOF
)
RESP=$(post "$SPAWN_TOKEN" "$REQ_UNKNOWN")
printf '%s' "$RESP" > "$TMP/unknown.json"
python3 -c "
import json
d = json.load(open('$TMP/unknown.json'))
sc = d['result']['structuredContent']
assert sc.get('error') == 'repo-not-enabled', f'unexpected: {sc}'
print('3) repo-not-enabled OK')
"

# --- 3b) disabled repo → repo-not-enabled ----------------------------------
REQ_DISABLED=$(cat <<'EOF'
{"jsonrpc":"2.0","id":31,"method":"tools/call","params":{"name":"hydra.file_ticket","arguments":{"repo":"test-owner/disabled-repo","title":"This repo is flagged disabled","body":"This body is long enough for the anti-spam check."}}}
EOF
)
RESP=$(post "$SPAWN_TOKEN" "$REQ_DISABLED")
printf '%s' "$RESP" > "$TMP/disabled.json"
python3 -c "
import json
d = json.load(open('$TMP/disabled.json'))
sc = d['result']['structuredContent']
assert sc.get('error') == 'repo-not-enabled', f'unexpected: {sc}'
print('3b) disabled repo→repo-not-enabled OK')
"

# --- 4) short title+body → validation-error --------------------------------
REQ_SHORT=$(cat <<'EOF'
{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"hydra.file_ticket","arguments":{"repo":"test-owner/test-repo","title":"x","body":"y"}}}
EOF
)
RESP=$(post "$SPAWN_TOKEN" "$REQ_SHORT")
printf '%s' "$RESP" > "$TMP/short.json"
python3 -c "
import json
d = json.load(open('$TMP/short.json'))
sc = d['result']['structuredContent']
assert sc.get('error') == 'validation-error', f'unexpected: {sc}'
assert '20' in sc.get('reason', ''), f'reason should mention 20: {sc}'
print('4) validation error (too-short) OK')
"

# --- 4b) title > 120 chars → validation-error ------------------------------
# build a 121-char title.
LONG_TITLE=$(python3 -c "print('A' * 121)")
REQ_LONG=$(python3 -c "
import json
print(json.dumps({
    'jsonrpc':'2.0','id':41,'method':'tools/call',
    'params':{'name':'hydra.file_ticket','arguments':{
        'repo':'test-owner/test-repo',
        'title':'$LONG_TITLE',
        'body':'body is long enough but title is not'
    }}
}))
")
RESP=$(post "$SPAWN_TOKEN" "$REQ_LONG")
printf '%s' "$RESP" > "$TMP/long.json"
python3 -c "
import json
d = json.load(open('$TMP/long.json'))
sc = d['result']['structuredContent']
assert sc.get('error') == 'validation-error', f'unexpected: {sc}'
assert '120' in sc.get('reason', ''), f'reason should mention 120: {sc}'
print('4b) validation error (too-long title) OK')
"

# --- 5) proposed_tier=T3 → will_autopickup=false ---------------------------
REQ_T3=$(cat <<'EOF'
{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"hydra.file_ticket","arguments":{"repo":"test-owner/test-repo","title":"Change auth config","body":"This ticket is explicitly flagged T3 to test the refusal path.","proposed_tier":"T3"}}}
EOF
)
# Wipe the gh log before this call so we can check the label arg in isolation.
: > "$GH_LOG"
RESP=$(post "$SPAWN_TOKEN" "$REQ_T3")
printf '%s' "$RESP" > "$TMP/t3.json"
python3 -c "
import json
d = json.load(open('$TMP/t3.json'))
sc = d['result']['structuredContent']
assert sc['will_autopickup'] is False, f'T3 should not autopickup: {sc}'
assert 'T3' in (sc.get('reason') or ''), f'reason should mention T3: {sc}'
print('5) T3 refusal OK')
"
# gh should have been called WITHOUT commander-ready and WITH commander-stuck.
if grep -q "commander-ready" "$GH_LOG"; then
  echo "FAIL: T3 path applied commander-ready label"
  cat "$GH_LOG"
  exit 1
fi
if ! grep -q "commander-stuck" "$GH_LOG"; then
  echo "FAIL: T3 path missing commander-stuck label"
  cat "$GH_LOG"
  exit 1
fi

# --- 6) rate limit: 10 valid calls, 11th refused ---------------------------
# The T3 call in step 5 counts toward the rate limit (we count all calls, not
# just successes), and we already used 1 call in step 1. That's 2 so far for
# spawn-agent — we need 8 more before the 11th triggers refusal.
# Fire 8 more successful calls (9th through 10th overall).
for i in $(seq 3 10); do
  REQ_I=$(cat <<EOF
{"jsonrpc":"2.0","id":$((100+i)),"method":"tools/call","params":{"name":"hydra.file_ticket","arguments":{"repo":"test-owner/test-repo","title":"Auto-filed ticket $i","body":"Long enough body for the anti-spam check $i."}}}
EOF
)
  RESP=$(post "$SPAWN_TOKEN" "$REQ_I")
  printf '%s' "$RESP" > "$TMP/rate-$i.json"
  python3 -c "
import json
d = json.load(open('$TMP/rate-$i.json'))
sc = d['result']['structuredContent']
assert sc.get('issue_number') == 42, f'call $i should have succeeded: {sc}'
" || { echo "FAIL: expected call $i to succeed"; cat "$TMP/rate-$i.json"; exit 1; }
done

# 11th call should be rate-limited.
REQ_11=$(cat <<'EOF'
{"jsonrpc":"2.0","id":999,"method":"tools/call","params":{"name":"hydra.file_ticket","arguments":{"repo":"test-owner/test-repo","title":"Eleventh call should rate-limit","body":"This body is long enough for the anti-spam check."}}}
EOF
)
RESP=$(post "$SPAWN_TOKEN" "$REQ_11")
printf '%s' "$RESP" > "$TMP/rate-11.json"
python3 -c "
import json
d = json.load(open('$TMP/rate-11.json'))
sc = d['result']['structuredContent']
assert sc.get('error') == 'rate-limited', f'11th call should be rate-limited: {sc}'
assert 'retry_after_sec' in sc, f'missing retry_after_sec: {sc}'
assert sc['retry_after_sec'] > 0, f'retry_after_sec should be positive: {sc}'
print('6) rate-limit (11th call refused) OK')
"

# --- 7) rate-limit state file exists with expected shape -------------------
if [[ ! -s "$TMP/mcp-rate-limit.json" ]]; then
  echo "FAIL: state/mcp-rate-limit.json was never written"
  exit 1
fi
python3 -c "
import json
d = json.load(open('$TMP/mcp-rate-limit.json'))
assert 'limits' in d
assert 'file_ticket' in d['limits']
assert d['limits']['file_ticket']['max_calls'] == 10
assert d['limits']['file_ticket']['window_sec'] == 3600
assert 'agents' in d
assert 'spawn-agent' in d['agents']
assert 'file_ticket' in d['agents']['spawn-agent']
assert len(d['agents']['spawn-agent']['file_ticket']) >= 10
print('7) rate-limit state file OK')
"

echo "PASS"

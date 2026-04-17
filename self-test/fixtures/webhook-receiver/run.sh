#!/usr/bin/env bash
#
# Integration smoke test for scripts/hydra-webhook-receiver.py (spec:
# docs/specs/2026-04-17-github-webhook-receiver.md, ticket #41).
#
# Exercises the HMAC + filter + sentinel-drop flow end-to-end against a
# real running receiver on a random free port:
#
#   1. Starts the receiver in the background with a fixture secret.
#   2. Sends a valid signed `issues.assigned` payload → expects 200 + sentinel.
#   3. Sends the same payload with a bad signature → expects 401 + NO sentinel.
#   4. Sends an `issues.opened` payload (wrong action) → expects 204 + NO sentinel.
#   5. Sends a `pull_request` event (wrong event type) → expects 204 + NO sentinel.
#   6. Asserts the sentinel from step 2 has the documented envelope shape.
#   7. Asserts stderr never contains the request body (no proprietary leak).
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
cleanup() {
  # Kill the server if it's still running.
  if [[ -n "${SERVER_PID:-}" ]]; then
    kill "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
  fi
  rm -rf "$TMP"
}
trap cleanup EXIT

# --- stage fixture config ---------------------------------------------------
SECRET="webhook-smoke-secret-$$"
SENTINEL_DIR="$TMP/sentinels"

PORT=$(python3 -c "import socket; s=socket.socket(); s.bind(('127.0.0.1',0)); print(s.getsockname()[1]); s.close()")

# --- start the server -------------------------------------------------------
HYDRA_WEBHOOK_SECRET="$SECRET" \
HYDRA_WEBHOOK_SENTINEL_DIR="$SENTINEL_DIR" \
  python3 "$ROOT_DIR/scripts/hydra-webhook-receiver.py" \
    --port "$PORT" --bind 127.0.0.1 \
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

# Helper: compute sha256=<hex> over the given file for the given secret.
sign_file() {
  local file="$1" secret="$2"
  python3 -c "
import hashlib, hmac, sys
secret = sys.argv[1].encode()
with open(sys.argv[2], 'rb') as f:
    body = f.read()
print('sha256=' + hmac.new(secret, body, hashlib.sha256).hexdigest())
" "$secret" "$file"
}

# --- craft fixture payloads -------------------------------------------------
cat > "$TMP/assigned.json" <<'JSON'
{
  "action": "assigned",
  "issue": {"number": 42, "title": "pretend-this-is-proprietary-body-PROPRIETARY_SENTINEL_STRING"},
  "repository": {"name": "hydra", "owner": {"login": "tonychang04"}},
  "assignee": {"login": "hydra-bot-test"}
}
JSON

cat > "$TMP/opened.json" <<'JSON'
{
  "action": "opened",
  "issue": {"number": 43, "title": "not-us"},
  "repository": {"name": "hydra", "owner": {"login": "tonychang04"}}
}
JSON

cat > "$TMP/pr.json" <<'JSON'
{
  "action": "closed",
  "pull_request": {"number": 99},
  "repository": {"name": "hydra", "owner": {"login": "tonychang04"}}
}
JSON

SIG_ASSIGNED=$(sign_file "$TMP/assigned.json" "$SECRET")
SIG_OPENED=$(sign_file "$TMP/opened.json" "$SECRET")
SIG_PR=$(sign_file "$TMP/pr.json" "$SECRET")

# --- 1) valid signed assigned event → 200 + sentinel -----------------------
CODE=$(curl -s -o "$TMP/resp1.json" -w "%{http_code}" \
  -X POST "http://127.0.0.1:$PORT/webhook/github" \
  -H "Content-Type: application/json" \
  -H "X-GitHub-Event: issues" \
  -H "X-GitHub-Delivery: fixture-delivery-1" \
  -H "X-Hub-Signature-256: $SIG_ASSIGNED" \
  --data-binary @"$TMP/assigned.json")

if [[ "$CODE" != "200" ]]; then
  echo "FAIL: valid assigned event returned $CODE (expected 200)"
  cat "$TMP/resp1.json" "$TMP/server.log"
  exit 1
fi

# Give the handler a beat to finish writing the sentinel before we list.
sleep 0.2
SENTINEL_COUNT=$(find "$SENTINEL_DIR" -type f -name '*.json' 2>/dev/null | wc -l | tr -d ' ')
if [[ "$SENTINEL_COUNT" != "1" ]]; then
  echo "FAIL: expected exactly 1 sentinel after valid event, got $SENTINEL_COUNT"
  ls -la "$SENTINEL_DIR" 2>/dev/null || true
  cat "$TMP/server.log"
  exit 1
fi

SENTINEL_FILE=$(find "$SENTINEL_DIR" -type f -name '*.json' | head -1)

# --- 2) envelope shape -------------------------------------------------------
python3 -c "
import json, sys
d = json.load(open('$SENTINEL_FILE'))
for key in ('ts', 'repo', 'issue_num', 'event', 'action', 'source'):
    assert key in d, f'sentinel missing {key}: {list(d.keys())}'
assert d['repo'] == 'tonychang04/hydra', f'wrong repo: {d[\"repo\"]}'
assert d['issue_num'] == 42, f'wrong issue_num: {d[\"issue_num\"]}'
assert d['event'] == 'issues', f'wrong event: {d[\"event\"]}'
assert d['action'] == 'assigned', f'wrong action: {d[\"action\"]}'
assert d['source'] == 'github-webhook'
assert d['assignee']['login'] == 'hydra-bot-test'
assert d.get('delivery_id') == 'fixture-delivery-1'
# Sentinel must NOT contain issue body text (security invariant).
raw = open('$SENTINEL_FILE').read()
assert 'PROPRIETARY_SENTINEL_STRING' not in raw, 'leaked issue body into sentinel!'
print('sentinel envelope OK')
"

# --- 3) bad signature → 401, no new sentinel -------------------------------
CODE=$(curl -s -o "$TMP/resp2.json" -w "%{http_code}" \
  -X POST "http://127.0.0.1:$PORT/webhook/github" \
  -H "Content-Type: application/json" \
  -H "X-GitHub-Event: issues" \
  -H "X-Hub-Signature-256: sha256=$(printf '%064d' 0)" \
  --data-binary @"$TMP/assigned.json")

if [[ "$CODE" != "401" ]]; then
  echo "FAIL: bad signature returned $CODE (expected 401)"
  cat "$TMP/resp2.json" "$TMP/server.log"
  exit 1
fi

# --- 4) missing signature → 401 --------------------------------------------
CODE=$(curl -s -o /dev/null -w "%{http_code}" \
  -X POST "http://127.0.0.1:$PORT/webhook/github" \
  -H "Content-Type: application/json" \
  -H "X-GitHub-Event: issues" \
  --data-binary @"$TMP/assigned.json")

if [[ "$CODE" != "401" ]]; then
  echo "FAIL: missing signature returned $CODE (expected 401)"
  exit 1
fi

# --- 5) wrong action (opened) → 204, no new sentinel -----------------------
CODE=$(curl -s -o /dev/null -w "%{http_code}" \
  -X POST "http://127.0.0.1:$PORT/webhook/github" \
  -H "Content-Type: application/json" \
  -H "X-GitHub-Event: issues" \
  -H "X-Hub-Signature-256: $SIG_OPENED" \
  --data-binary @"$TMP/opened.json")

if [[ "$CODE" != "204" ]]; then
  echo "FAIL: wrong-action event returned $CODE (expected 204)"
  exit 1
fi

# --- 6) wrong event type (pull_request) → 204, no new sentinel -------------
CODE=$(curl -s -o /dev/null -w "%{http_code}" \
  -X POST "http://127.0.0.1:$PORT/webhook/github" \
  -H "Content-Type: application/json" \
  -H "X-GitHub-Event: pull_request" \
  -H "X-Hub-Signature-256: $SIG_PR" \
  --data-binary @"$TMP/pr.json")

if [[ "$CODE" != "204" ]]; then
  echo "FAIL: wrong-event event returned $CODE (expected 204)"
  exit 1
fi

# --- 7) total sentinel count still 1 ---------------------------------------
sleep 0.2
SENTINEL_COUNT=$(find "$SENTINEL_DIR" -type f -name '*.json' 2>/dev/null | wc -l | tr -d ' ')
if [[ "$SENTINEL_COUNT" != "1" ]]; then
  echo "FAIL: sentinel count drifted to $SENTINEL_COUNT after rejected / filtered events"
  ls -la "$SENTINEL_DIR" 2>/dev/null || true
  exit 1
fi

# --- 8) 404 on wrong path ---------------------------------------------------
CODE=$(curl -s -o /dev/null -w "%{http_code}" \
  -X POST "http://127.0.0.1:$PORT/not-a-route" \
  -H "Content-Type: application/json" \
  --data '{}')
if [[ "$CODE" != "404" ]]; then
  echo "FAIL: wrong path returned $CODE (expected 404)"
  exit 1
fi

# --- 9) method check — GET /webhook/github → 405 ---------------------------
CODE=$(curl -s -o /dev/null -w "%{http_code}" "http://127.0.0.1:$PORT/webhook/github")
if [[ "$CODE" != "405" ]]; then
  echo "FAIL: GET on /webhook/github returned $CODE (expected 405)"
  exit 1
fi

# --- 10) body-leak guard — stderr must NOT contain the issue body ---------
if grep -q 'PROPRIETARY_SENTINEL_STRING' "$TMP/server.log"; then
  echo "FAIL: server log contains request body text (security leak)"
  grep 'PROPRIETARY_SENTINEL_STRING' "$TMP/server.log" >&2
  exit 1
fi

# --- 11) body-leak guard — stderr must NOT contain the secret --------------
if grep -q "$SECRET" "$TMP/server.log"; then
  echo "FAIL: server log contains the HMAC secret (security leak)"
  exit 1
fi

echo "PASS"

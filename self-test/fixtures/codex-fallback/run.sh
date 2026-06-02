#!/usr/bin/env bash
#
# self-test fixture driver for the codex auto-fallback router (#97):
#   - scripts/select-worker-backend.sh   (read-only router decision)
#   - scripts/set-backend-fallback.sh    (writer: trigger / set / status)
#
# Exercises the full decision table from docs/specs/2026-06-01-codex-auto-fallback.md
# against synthetic state/quota-health.json fixtures, with `--now` injected so
# TTL-expiry is deterministic (no sleeping, no real clock dependency).
#
# Exits 0 on PASS, non-zero on FAIL with a clear stderr message.
# Invoked by self-test/golden-cases.example.json case "codex-fallback-trigger".

set -euo pipefail
export NO_COLOR=1

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd -- "$SCRIPT_DIR/../../.." && pwd)"
ROUTER="$ROOT_DIR/scripts/select-worker-backend.sh"
WRITER="$ROOT_DIR/scripts/set-backend-fallback.sh"

[[ -x "$ROUTER" ]] || { echo "FAIL: $ROUTER not executable" >&2; exit 1; }
[[ -x "$WRITER" ]] || { echo "FAIL: $WRITER not executable" >&2; exit 1; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT INT TERM

# Fixed reference times. The TTL fixtures use 10:12Z as expiry; "now_before"
# is inside the window, "now_after" is past it.
now_before="2026-06-01T10:00:00Z"
now_after="2026-06-01T11:00:00Z"

# write_qh <file> <json> — drop a quota-health fixture.
write_qh() { printf '%s\n' "$2" > "$1"; }

# assert_router <label> <expected> -- <router args...>
assert_router() {
  local label="$1" expected="$2"; shift 2
  [[ "$1" == "--" ]] && shift
  local got
  if ! got="$("$ROUTER" "$@" 2>/dev/null)"; then
    echo "FAIL [$label]: router exited non-zero for args: $*" >&2
    exit 1
  fi
  if [[ "$got" != "$expected" ]]; then
    echo "FAIL [$label]: expected '$expected', got '$got' (args: $*)" >&2
    exit 1
  fi
}

# ---- 1. --help works on both scripts ---------------------------------------

"$ROUTER" --help 2>&1 | grep -q 'Usage:' || { echo "FAIL: router --help missing Usage:" >&2; exit 1; }
"$WRITER" --help 2>&1 | grep -q 'Usage:' || { echo "FAIL: writer --help missing Usage:" >&2; exit 1; }

# ---- 2. absent quota-health → default claude -------------------------------

assert_router "absent-file" "worker-implementation" -- \
  --repo-backend claude --quota-health "$tmp/does-not-exist.json"

# ---- 3. repo preferred_backend=codex, no fallback → codex ------------------

write_qh "$tmp/empty.json" '{}'
assert_router "repo-prefers-codex" "worker-codex-implementation" -- \
  --repo-backend codex --quota-health "$tmp/empty.json" --now "$now_before"

assert_router "repo-prefers-claude" "worker-implementation" -- \
  --repo-backend claude --quota-health "$tmp/empty.json" --now "$now_before"

# auto with no fallback → claude (reactive routing already considered)
assert_router "repo-auto-no-fallback" "worker-implementation" -- \
  --repo-backend auto --quota-health "$tmp/empty.json" --now "$now_before"

# ---- 4. active codex fallback, TTL in future → codex -----------------------

write_qh "$tmp/active.json" '{
  "active_backend": "codex",
  "fallback_reason": "claude-rate-limit",
  "fallback_expires_at": "2026-06-01T10:12:00Z",
  "fallback_on_rate_limit": true
}'
assert_router "active-fallback-in-ttl" "worker-codex-implementation" -- \
  --repo-backend claude --quota-health "$tmp/active.json" --now "$now_before"

# ---- 5. same fixture, now past TTL → claude (read-time recovery) -----------

assert_router "fallback-ttl-expired" "worker-implementation" -- \
  --repo-backend claude --quota-health "$tmp/active.json" --now "$now_after"

# ---- 6. fallback_on_rate_limit=false → off-switch wins ---------------------

write_qh "$tmp/disabled.json" '{
  "active_backend": "codex",
  "fallback_reason": "claude-rate-limit",
  "fallback_expires_at": "2026-06-01T10:12:00Z",
  "fallback_on_rate_limit": false
}'
assert_router "off-switch" "worker-implementation" -- \
  --repo-backend claude --quota-health "$tmp/disabled.json" --now "$now_before"

# ---- 6b. SAFETY: malformed/partial fallback state must fail safe to claude --
# These defend the "no silent permanent switch to codex" invariant: any state
# that says codex but is missing/garbled the TTL must NOT pin codex forever.

# codex active but NO expiry → claude (a fallback with no TTL is not honored).
write_qh "$tmp/noexp.json" '{ "active_backend": "codex", "fallback_on_rate_limit": true }'
assert_router "codex-active-no-ttl" "worker-implementation" -- \
  --repo-backend claude --quota-health "$tmp/noexp.json" --now "$now_before"

# unparseable expiry timestamp → claude (fail safe, not stuck on codex).
write_qh "$tmp/badts.json" '{ "active_backend": "codex", "fallback_expires_at": "garbage", "fallback_on_rate_limit": true }'
assert_router "codex-active-bad-ttl" "worker-implementation" -- \
  --repo-backend claude --quota-health "$tmp/badts.json" --now "$now_before"

# invalid manual_override value → ignored, fall through to default.
write_qh "$tmp/badmo.json" '{ "manual_override": "codexx" }'
assert_router "bad-manual-override" "worker-implementation" -- \
  --repo-backend claude --quota-health "$tmp/badmo.json" --now "$now_before"

# corrupt (non-JSON) quota-health file → treated as empty → default claude.
printf 'not json at all{{{\n' > "$tmp/corrupt.json"
assert_router "corrupt-file" "worker-implementation" -- \
  --repo-backend claude --quota-health "$tmp/corrupt.json" --now "$now_before"

# ---- 7. manual_override=codex, no fallback → codex -------------------------

write_qh "$tmp/override-codex.json" '{ "manual_override": "codex" }'
assert_router "override-codex" "worker-codex-implementation" -- \
  --repo-backend claude --quota-health "$tmp/override-codex.json" --now "$now_before"

# ---- 8. manual_override=claude beats active codex fallback -----------------

write_qh "$tmp/override-claude.json" '{
  "active_backend": "codex",
  "fallback_expires_at": "2026-06-01T10:12:00Z",
  "fallback_on_rate_limit": true,
  "manual_override": "claude"
}'
assert_router "override-claude-beats-fallback" "worker-implementation" -- \
  --repo-backend codex --quota-health "$tmp/override-claude.json" --now "$now_before"

# manual_override=auto falls through to fallback logic (here: active → codex)
write_qh "$tmp/override-auto.json" '{
  "active_backend": "codex",
  "fallback_expires_at": "2026-06-01T10:12:00Z",
  "fallback_on_rate_limit": true,
  "manual_override": "auto"
}'
assert_router "override-auto-falls-through" "worker-codex-implementation" -- \
  --repo-backend claude --quota-health "$tmp/override-auto.json" --now "$now_before"

# ---- 9. WRITER: --trigger sets codex + TTL ---------------------------------

qh="$tmp/writer.json"
"$WRITER" --trigger claude-rate-limit --ttl-hours 1 --quota-health "$qh" --now "$now_before" >/dev/null
ab="$(jq -r '.active_backend' "$qh")"
[[ "$ab" == "codex" ]] || { echo "FAIL: trigger should set active_backend=codex, got '$ab'" >&2; exit 1; }
fr="$(jq -r '.fallback_reason' "$qh")"
[[ "$fr" == "claude-rate-limit" ]] || { echo "FAIL: trigger should set fallback_reason, got '$fr'" >&2; exit 1; }
exp="$(jq -r '.fallback_expires_at' "$qh")"
[[ "$exp" == "2026-06-01T11:00:00Z" ]] || { echo "FAIL: TTL should be now+1h (11:00:00Z), got '$exp'" >&2; exit 1; }
# And the router now serves codex on this freshly-written state.
assert_router "writer-then-router" "worker-codex-implementation" -- \
  --repo-backend claude --quota-health "$qh" --now "$now_before"

# ---- 10. WRITER: --trigger refuses a non-rate-limit class (exit 2) ---------

qh2="$tmp/writer2.json"
write_qh "$qh2" '{}'
set +e
"$WRITER" --trigger lockfile-drift --quota-health "$qh2" --now "$now_before" >/dev/null 2>&1
ec=$?
set -e
[[ "$ec" -eq 2 ]] || { echo "FAIL: trigger with non-rate-limit class should exit 2, got $ec" >&2; exit 1; }
# And it must NOT have switched the backend.
ab2="$(jq -r '.active_backend // "absent"' "$qh2")"
[[ "$ab2" == "absent" ]] || { echo "FAIL: refused trigger must not write active_backend, got '$ab2'" >&2; exit 1; }

# ---- 11. WRITER: --trigger is a no-op when fallback disabled ----------------

qh3="$tmp/writer3.json"
write_qh "$qh3" '{ "fallback_on_rate_limit": false }'
"$WRITER" --trigger anthropic-api-429 --quota-health "$qh3" --now "$now_before" >/dev/null
ab3="$(jq -r '.active_backend // "absent"' "$qh3")"
[[ "$ab3" == "absent" ]] || { echo "FAIL: trigger with fallback disabled must not switch, got '$ab3'" >&2; exit 1; }

# ---- 12. WRITER: --set codex / claude / auto -------------------------------

qh4="$tmp/writer4.json"
write_qh "$qh4" '{}'
"$WRITER" --set codex --quota-health "$qh4" --now "$now_before" >/dev/null
[[ "$(jq -r '.manual_override' "$qh4")" == "codex" ]] || { echo "FAIL: --set codex" >&2; exit 1; }
"$WRITER" --set claude --quota-health "$qh4" --now "$now_before" >/dev/null
[[ "$(jq -r '.manual_override' "$qh4")" == "claude" ]] || { echo "FAIL: --set claude" >&2; exit 1; }

# --set auto clears manual_override AND any active fallback fields.
write_qh "$qh4" '{
  "active_backend": "codex",
  "fallback_reason": "claude-rate-limit",
  "fallback_expires_at": "2026-06-01T10:12:00Z",
  "manual_override": "codex"
}'
"$WRITER" --set auto --quota-health "$qh4" --now "$now_before" >/dev/null
mo="$(jq -r '.manual_override // "cleared"' "$qh4")"
[[ "$mo" == "cleared" ]] || { echo "FAIL: --set auto should clear manual_override, got '$mo'" >&2; exit 1; }
ab4="$(jq -r '.active_backend // "cleared"' "$qh4")"
[[ "$ab4" == "cleared" ]] || { echo "FAIL: --set auto should clear active_backend, got '$ab4'" >&2; exit 1; }
# Router on the cleaned state → claude.
assert_router "after-set-auto" "worker-implementation" -- \
  --repo-backend claude --quota-health "$qh4" --now "$now_before"

# ---- 13. WRITER: --status is read-only + reports backend -------------------

write_qh "$tmp/status.json" '{
  "active_backend": "codex",
  "fallback_reason": "session-token-exhausted",
  "fallback_expires_at": "2026-06-01T10:12:00Z",
  "fallback_on_rate_limit": true
}'
before_hash="$(shasum "$tmp/status.json" | awk '{print $1}')"
out="$("$WRITER" --status --quota-health "$tmp/status.json" --now "$now_before")"
after_hash="$(shasum "$tmp/status.json" | awk '{print $1}')"
[[ "$before_hash" == "$after_hash" ]] || { echo "FAIL: --status mutated the file" >&2; exit 1; }
printf '%s' "$out" | grep -qi 'codex' || { echo "FAIL: --status should mention active backend; got: $out" >&2; exit 1; }
printf '%s' "$out" | grep -qi 'session-token-exhausted' || { echo "FAIL: --status should mention reason; got: $out" >&2; exit 1; }

# ---- 14. router rejects bad usage (exit 2) ---------------------------------

set +e
"$ROUTER" --repo-backend bogus --quota-health "$tmp/empty.json" >/dev/null 2>&1
ec=$?
set -e
[[ "$ec" -eq 2 ]] || { echo "FAIL: router with bad --repo-backend should exit 2, got $ec" >&2; exit 1; }

set +e
"$ROUTER" >/dev/null 2>&1   # missing required --repo-backend
ec=$?
set -e
[[ "$ec" -eq 2 ]] || { echo "FAIL: router with no args should exit 2, got $ec" >&2; exit 1; }

echo "PASS: codex auto-fallback router + writer fixture (#97)"

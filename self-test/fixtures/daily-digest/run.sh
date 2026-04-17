#!/usr/bin/env bash
#
# run.sh — self-test for scripts/build-daily-digest.sh and the
# `./hydra connect digest` wizard wiring.
#
# Covers three composer paths:
#   1. everything-zero:    empty logs/state dirs → "Overnight: quiet." paragraph
#   2. full data:          shipped / stuck / picked / rate-limit clauses present
#   3. truncation:         over-cap paragraph truncates + appends pointer
#
# Plus two wizard paths:
#   4. --dry-run digest:   emits valid JSON, passes schema validation
#   5. --list / --status:  digest row appears in both outputs
#
# Invoked by:
#   - the daily-digest golden case (when added)
#   - operators validating ticket #144 locally:
#         bash self-test/fixtures/daily-digest/run.sh
#
# Spec: docs/specs/2026-04-17-daily-digest.md (ticket #144)

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/../../.." && pwd)"
composer="$repo_root/scripts/build-daily-digest.sh"
connect="$repo_root/scripts/hydra-connect.sh"
digest_schema="$repo_root/state/schemas/digests.schema.json"

fail() { echo "FAIL: $1" >&2; exit 1; }
ok()   { echo "ok: $1"; }

[[ -x "$composer" ]] || fail "scripts/build-daily-digest.sh not executable"
[[ -x "$connect"  ]] || fail "scripts/hydra-connect.sh not executable"
[[ -f "$digest_schema" ]] || fail "state/schemas/digests.schema.json missing"
command -v jq >/dev/null || fail "jq required"

tmpdir="$(mktemp -d -t daily-digest-test.XXXXXX)"
trap 'rm -rf "$tmpdir"' EXIT

mkdir -p "$tmpdir/logs" "$tmpdir/state" "$tmpdir/memory/retros"

# ----------------------------------------------------------------------------
# 1. everything-zero path
# ----------------------------------------------------------------------------
out="$("$composer" --logs-dir "$tmpdir/logs" --state-dir "$tmpdir/state" --memory-dir "$tmpdir/memory")"
[[ "$out" == *"Overnight: quiet."* ]] \
  || fail "empty-env did not produce quiet paragraph: $out"
[[ "$out" == *"Full: ./hydra status."* ]] \
  || fail "empty-env missing full-status pointer: $out"
ok "1. everything-zero path produces the quiet paragraph"

# ----------------------------------------------------------------------------
# 2. full-data path (shipped / stuck / picked)
# ----------------------------------------------------------------------------
cat > "$tmpdir/logs/501.json" <<'JSON'
{"ticket":"tonychang04/hydra#501","result":"merged","pr_url":"https://github.com/x/y/pull/501"}
JSON
cat > "$tmpdir/logs/502.json" <<'JSON'
{"ticket":"tonychang04/hydra#502","result":"merged","pr_url":"https://github.com/x/y/pull/502"}
JSON
cat > "$tmpdir/logs/503.json" <<'JSON'
{"ticket":"tonychang04/hydra#503","result":"pr_opened","pr_url":"https://github.com/x/y/pull/503"}
JSON
cat > "$tmpdir/state/active.json" <<'JSON'
{"workers":[{"ticket":"#42","status":"paused-on-question"}]}
JSON
cat > "$tmpdir/state/autopickup.json" <<'JSON'
{"enabled":true,"last_picked_count":5,"consecutive_rate_limit_hits":0}
JSON

out="$("$composer" --logs-dir "$tmpdir/logs" --state-dir "$tmpdir/state" --memory-dir "$tmpdir/memory")"
chars=$(printf '%s' "$out" | wc -c | tr -d ' ')
(( chars <= 500 )) || fail "full-data paragraph exceeds 500 chars ($chars): $out"
[[ "$out" == *"shipped 3 PRs"* ]]          || fail "missing shipped clause: $out"
[[ "$out" == *"2 auto-merged"* ]]          || fail "missing auto-merged count: $out"
[[ "$out" == *"1 pending your review"* ]]  || fail "missing pending clause: $out"
[[ "$out" == *"tonychang04/hydra#503"* ]]  || fail "missing pending PR ref: $out"
[[ "$out" == *"1 worker stuck on #42"* ]]  || fail "missing stuck clause: $out"
[[ "$out" == *"autopickup picked 5 tickets"* ]] \
  || fail "missing picked clause: $out"
[[ "$out" == *"Retro queued for Monday"* ]] \
  || fail "missing retro clause: $out"
[[ "$out" == *"Full: ./hydra status."* ]] \
  || fail "missing full-status pointer: $out"
ok "2. full-data path produces spec-shaped paragraph within 500 chars ($chars)"

# ----------------------------------------------------------------------------
# 3. truncation path — 50 pending PRs blow past 500 chars
# ----------------------------------------------------------------------------
rm -f "$tmpdir/logs/"*.json
for i in $(seq 1 50); do
  cat > "$tmpdir/logs/$i.json" <<JSON
{"ticket":"tonychang04/hydra#$((500+i))","result":"pr_opened","pr_url":"https://github.com/x/y/pull/$((500+i))"}
JSON
done
rm -f "$tmpdir/state/active.json"
out="$("$composer" --logs-dir "$tmpdir/logs" --state-dir "$tmpdir/state" --memory-dir "$tmpdir/memory")"
chars=$(printf '%s' "$out" | wc -c | tr -d ' ')
(( chars <= 500 )) || fail "truncated paragraph exceeds 500 chars ($chars): $out"
[[ "$out" == *"full: ./hydra status"* ]] \
  || fail "truncation path missing full-status pointer: $out"
[[ "$out" == *"…"* ]] \
  || fail "truncation path missing ellipsis: $out"
ok "3. truncation path truncates + appends pointer (chars=$chars)"

# ----------------------------------------------------------------------------
# 4. wizard dry-run emits schema-valid JSON
# ----------------------------------------------------------------------------
digest_cfg="$tmpdir/state/digests.json"
dry_out="$(HYDRA_CONNECT_DIGEST_FILE="$digest_cfg" \
  "$connect" --dry-run digest --non-interactive 2>/dev/null)"
# dry_out is the jq-formatted JSON blob.
echo "$dry_out" | jq -e . >/dev/null \
  || fail "dry-run did not produce valid JSON: $dry_out"
# Must include the required fields.
for key in enabled channel time destination last_digest_run; do
  echo "$dry_out" | jq -e --arg k "$key" 'has($k)' >/dev/null \
    || fail "dry-run output missing required key '$key'"
done
# And schema-validate the blob.
blob_tmp="$tmpdir/dry-run-blob.json"
echo "$dry_out" > "$blob_tmp"
"$repo_root/scripts/validate-state.sh" --schema "$digest_schema" "$blob_tmp" >/dev/null \
  || fail "dry-run blob failed schema validation"
# And: the dry-run must NOT have written $digest_cfg.
[[ ! -f "$digest_cfg" ]] \
  || fail "dry-run wrote $digest_cfg — should have been preview-only"
ok "4. wizard --dry-run emits schema-valid JSON and writes nothing"

# ----------------------------------------------------------------------------
# 5. --list / --status include a digest row
# ----------------------------------------------------------------------------
list_out="$(HYDRA_CONNECT_DIGEST_FILE="$digest_cfg" "$connect" --list 2>&1)"
grep -Eq '^digest +' <<<"$list_out" \
  || fail "--list missing digest row: $list_out"
status_out="$(HYDRA_CONNECT_DIGEST_FILE="$digest_cfg" "$connect" --status 2>&1 || true)"
grep -Eq '^digest +' <<<"$status_out" \
  || fail "--status missing digest row: $status_out"
ok "5. --list and --status expose the digest connector"

# ----------------------------------------------------------------------------
# 6. webhook URL paste guard — destination='https://...' must error, not write
# ----------------------------------------------------------------------------
mistake_cfg="$tmpdir/digest-webhook-url-mistake.json"
cat > "$mistake_cfg" <<'JSON'
{
  "enabled": true,
  "channel": "webhook",
  "time": "09:00",
  "destination": "https://hooks.example.com/abc123",
  "last_digest_run": null
}
JSON
if HYDRA_CONNECT_DIGEST_FILE="$mistake_cfg" "$connect" digest --non-interactive >/dev/null 2>&1; then
  fail "webhook URL guard failed to reject pasted URL"
fi
ok "6. wizard rejects a webhook destination that looks like a URL"

echo ""
echo "PASS: all daily-digest checks green"

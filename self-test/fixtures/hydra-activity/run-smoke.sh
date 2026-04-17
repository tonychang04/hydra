#!/usr/bin/env bash
# Smoke-test harness for scripts/hydra-activity.sh.
#
# Sets up deterministic mtimes on the fixture logs so the 24h-window filter is
# testable (101 / 102 / 103 are in-window; 099-old.json is out-of-window), then
# runs hydra-activity.sh against the fixtures and verifies both the human-mode
# and --json-mode outputs.
#
# Intended to be invoked by self-test/run.sh via the activity-command-smoke
# golden case.

set -euo pipefail

FIX_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd -- "$FIX_DIR/../../.." && pwd)"
SCRIPT="$ROOT_DIR/scripts/hydra-activity.sh"

LOGS_DIR="$FIX_DIR/logs"
STATE_DIR="$FIX_DIR/state"
MEM_DIR="$FIX_DIR/memory"

# Fresh memory dir — empty retros/ so the count starts at zero; individual
# steps below create retros to test the count path.
rm -rf "$MEM_DIR"
mkdir -p "$MEM_DIR/retros"

# Portable mtime setter — GNU touch uses `-d "N ago"`; BSD touch (macOS) uses
# `-t CCYYMMDDhhmm.SS`. Translate once here so the fixture works on both.
# Arg: seconds-ago (e.g. 7200 for 2h). Echoes the touch -t format.
ts_seconds_ago() {
  local secs="$1"
  if date -v-1S '+%s' >/dev/null 2>&1; then
    # BSD date: -v-Ns offsets relative
    date -v-"${secs}"S '+%Y%m%d%H%M.%S'
  else
    # GNU date
    date -d "@$(( $(date +%s) - secs ))" '+%Y%m%d%H%M.%S'
  fi
}

# Put the in-window fixture logs inside the last 24h (but spaced apart so the
# sort-by-completion-time column is deterministic), and push the out-of-window
# log back 3 days so the window filter drops it.
touch -t "$(ts_seconds_ago 7200)"  "$LOGS_DIR/101.json"   #  2 hours ago
touch -t "$(ts_seconds_ago 14400)" "$LOGS_DIR/102.json"   #  4 hours ago
touch -t "$(ts_seconds_ago 21600)" "$LOGS_DIR/103.json"   #  6 hours ago
touch -t "$(ts_seconds_ago 259200)" "$LOGS_DIR/099-old.json"  # 3 days ago

# Add two retros so the "Retros on disk" line has a non-zero count.
: > "$MEM_DIR/retros/2026-15.md"
: > "$MEM_DIR/retros/2026-16.md"

common_args=(
  --logs-dir "$LOGS_DIR"
  --state-dir "$STATE_DIR"
  --memory-dir "$MEM_DIR"
)

# -----------------------------------------------------------------------------
# Human-mode checks
# -----------------------------------------------------------------------------
human_out="$(NO_COLOR=1 "$SCRIPT" "${common_args[@]}")"

grep -q "Hydra activity" <<<"$human_out" \
  || { echo "FAIL: banner missing from human output"; printf '%s\n' "$human_out"; exit 1; }
grep -q "Completed (last 24h): 3" <<<"$human_out" \
  || { echo "FAIL: expected 'Completed (last 24h): 3'"; printf '%s\n' "$human_out"; exit 1; }
grep -q "Active right now: 1" <<<"$human_out" \
  || { echo "FAIL: expected 'Active right now: 1'"; printf '%s\n' "$human_out"; exit 1; }
grep -q "Stuck" <<<"$human_out" \
  || { echo "FAIL: 'Stuck' section missing"; printf '%s\n' "$human_out"; exit 1; }
grep -q "npm install strips peer markers" <<<"$human_out" \
  || { echo "FAIL: top memory citation not rendered"; printf '%s\n' "$human_out"; exit 1; }
grep -q "Retros on disk: 2" <<<"$human_out" \
  || { echo "FAIL: retro count wrong"; printf '%s\n' "$human_out"; exit 1; }

# The out-of-window log must NOT appear.
if grep -q "repoA#99" <<<"$human_out"; then
  echo "FAIL: 099-old.json appeared in 24h window"
  printf '%s\n' "$human_out"
  exit 1
fi

# -----------------------------------------------------------------------------
# --json mode checks
# -----------------------------------------------------------------------------
json_out="$(NO_COLOR=1 "$SCRIPT" --json "${common_args[@]}")"

echo "$json_out" | jq -e 'has("generated_at") and has("window_hours")' >/dev/null \
  || { echo "FAIL: json envelope missing keys"; echo "$json_out"; exit 1; }
echo "$json_out" | jq -e '.completed | length == 3' >/dev/null \
  || { echo "FAIL: json .completed length != 3"; echo "$json_out"; exit 1; }
echo "$json_out" | jq -e '.active | length == 1' >/dev/null \
  || { echo "FAIL: json .active length != 1"; echo "$json_out"; exit 1; }
echo "$json_out" | jq -e '.stuck | length >= 1' >/dev/null \
  || { echo "FAIL: json .stuck length not >= 1"; echo "$json_out"; exit 1; }
echo "$json_out" | jq -e '.citations_top | length >= 1' >/dev/null \
  || { echo "FAIL: json .citations_top empty"; echo "$json_out"; exit 1; }
echo "$json_out" | jq -e '.retros.count == 2' >/dev/null \
  || { echo "FAIL: json .retros.count != 2"; echo "$json_out"; exit 1; }

# -----------------------------------------------------------------------------
# Corrupt-state smoke: if state/active.json is truncated, script must not crash;
# it should still render the other sections with a safe fallback.
# -----------------------------------------------------------------------------
BAD_STATE="$(mktemp -d)"
trap 'rm -rf "$BAD_STATE"' EXIT
cp "$STATE_DIR/memory-citations.json" "$BAD_STATE/memory-citations.json"
printf '{"workers": [' > "$BAD_STATE/active.json"

NO_COLOR=1 "$SCRIPT" \
  --logs-dir "$LOGS_DIR" \
  --state-dir "$BAD_STATE" \
  --memory-dir "$MEM_DIR" >/dev/null \
  || { echo "FAIL: script crashed on corrupt active.json"; exit 1; }

echo "SMOKE_OK"

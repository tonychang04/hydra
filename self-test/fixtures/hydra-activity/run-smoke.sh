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

# Portable YYYY-MM-DD for N days ago — used to keep the citation fixture's
# `last_cited` dates inside hydra-activity.sh's 7-day window regardless of when
# the suite runs. The committed fixture stores absolute April-2026 dates so it
# stays deterministic; without re-stamping they fall out of the window and the
# "top memory citation" assertion rots over wall-clock time (ticket #201).
# Arg: days-ago (e.g. 0 for today, 2 for 2 days ago). Echoes YYYY-MM-DD.
ymd_days_ago() {
  local days="$1"
  if date -v-1d '+%Y-%m-%d' >/dev/null 2>&1; then
    date -v-"${days}"d '+%Y-%m-%d'   # BSD date (macOS)
  else
    date -d "${days} days ago" '+%Y-%m-%d'  # GNU date
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

# Stage a temp state dir with the same active.json but freshly-dated citations.
# hydra-activity.sh filters citations to the last 7 days; the committed fixture's
# `last_cited` are absolute April-2026 dates that would now fall outside the
# window. Re-stamp them to today / yesterday / 2-days-ago (still within 7d, and
# spaced so the sort-by-count ordering is unaffected). We do this in a temp dir
# so the committed fixture stays byte-for-byte deterministic and git stays clean.
STAGED_STATE="$(mktemp -d)"
trap 'rm -rf "$STAGED_STATE"' EXIT
cp "$STATE_DIR/active.json" "$STAGED_STATE/active.json"
# Re-stamp ONLY existing entries. A bare `.citations[key].last_cited = $d` would
# silently *create* a synthetic key if the fixture is later renamed/trimmed —
# hydra-activity.sh renders an entry with a missing count as count 0, so the
# assertions could pass against a broken fixture. Guard with `has` + `error` so a
# missing target key fails the harness loudly instead of masking the breakage.
if ! jq --arg d0 "$(ymd_days_ago 0)" --arg d1 "$(ymd_days_ago 1)" --arg d2 "$(ymd_days_ago 2)" '
  def restamp($k; $d):
    if (.citations | has($k)) then .citations[$k].last_cited = $d
    else error("citation fixture key missing: \($k)") end;
  restamp("learnings-repoA.md#npm install strips peer markers"; $d0)
  | restamp("learnings-repoA.md#baseline typecheck trick"; $d1)
  | restamp("learnings-repoB.md#docker-compose timeout 120s not enough"; $d2)
' "$STATE_DIR/memory-citations.json" > "$STAGED_STATE/memory-citations.json"; then
  echo "FAIL: could not re-stamp citation fixture (key missing or invalid JSON)"
  exit 1
fi

common_args=(
  --logs-dir "$LOGS_DIR"
  --state-dir "$STAGED_STATE"
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
# Extend (don't replace) the cleanup so the earlier STAGED_STATE dir is also
# removed — a bare `trap ... EXIT` would clobber the prior handler.
trap 'rm -rf "$STAGED_STATE" "$BAD_STATE"' EXIT
cp "$STATE_DIR/memory-citations.json" "$BAD_STATE/memory-citations.json"
printf '{"workers": [' > "$BAD_STATE/active.json"

NO_COLOR=1 "$SCRIPT" \
  --logs-dir "$LOGS_DIR" \
  --state-dir "$BAD_STATE" \
  --memory-dir "$MEM_DIR" >/dev/null \
  || { echo "FAIL: script crashed on corrupt active.json"; exit 1; }

echo "SMOKE_OK"

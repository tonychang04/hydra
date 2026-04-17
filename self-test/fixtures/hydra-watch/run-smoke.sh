#!/usr/bin/env bash
# Smoke-test harness for scripts/hydra-watch.sh.
#
# Runs `./hydra watch --once` (via the script directly) against deterministic
# fixtures in this directory, then greps stdout for expected substrings that
# prove the three panes render: commander state, active workers, recent
# completions. Also exercises the corrupt-JSON + missing-logs paths.
#
# Intended to be invoked by self-test/run.sh via the hydra-watch-smoke golden
# case.

set -euo pipefail

FIX_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd -- "$FIX_DIR/../../.." && pwd)"
SCRIPT="$ROOT_DIR/scripts/hydra-watch.sh"

LOGS_DIR="$FIX_DIR/logs"
STATE_DIR="$FIX_DIR/state"

common_args=(
  --once
  --logs-dir "$LOGS_DIR"
  --state-dir "$STATE_DIR"
)

# -----------------------------------------------------------------------------
# Default render — three panes visible
# -----------------------------------------------------------------------------
out="$(NO_COLOR=1 "$SCRIPT" "${common_args[@]}")"

# banner
grep -q "Hydra watch" <<<"$out" \
  || { echo "FAIL: banner missing"; printf '%s\n' "$out"; exit 1; }

# top line — commander state. active count should be 2 (both fixture workers
# are status=running), today's done count comes from budget-used.json.
grep -q "Commander: online" <<<"$out" \
  || { echo "FAIL: commander state line missing"; printf '%s\n' "$out"; exit 1; }
grep -q "autopickup: on" <<<"$out" \
  || { echo "FAIL: autopickup on not rendered"; printf '%s\n' "$out"; exit 1; }
grep -q "4 done" <<<"$out" \
  || { echo "FAIL: today's done count wrong (expected 4)"; printf '%s\n' "$out"; exit 1; }

# middle pane — active workers, 2 rows with specific fixture IDs + tickets
grep -q "Active workers (2)" <<<"$out" \
  || { echo "FAIL: active worker count != 2"; printf '%s\n' "$out"; exit 1; }
grep -q "af740ff9" <<<"$out" \
  || { echo "FAIL: fixture worker af740ff9 missing"; printf '%s\n' "$out"; exit 1; }
grep -q "abbfd8e3" <<<"$out" \
  || { echo "FAIL: fixture worker abbfd8e3 missing"; printf '%s\n' "$out"; exit 1; }
grep -q "hydra#96" <<<"$out" \
  || { echo "FAIL: fixture ticket hydra#96 missing"; printf '%s\n' "$out"; exit 1; }
grep -q "hydra#19" <<<"$out" \
  || { echo "FAIL: fixture ticket hydra#19 missing"; printf '%s\n' "$out"; exit 1; }

# bottom pane — recent completions. 3 fixture logs with known tickets.
grep -q "Recent completions" <<<"$out" \
  || { echo "FAIL: 'Recent completions' pane missing"; printf '%s\n' "$out"; exit 1; }
grep -q "hydra#82" <<<"$out" \
  || { echo "FAIL: fixture completion hydra#82 missing"; printf '%s\n' "$out"; exit 1; }
grep -q "hydra#51" <<<"$out" \
  || { echo "FAIL: fixture completion hydra#51 missing"; printf '%s\n' "$out"; exit 1; }
grep -q "hydra#77" <<<"$out" \
  || { echo "FAIL: fixture completion hydra#77 missing"; printf '%s\n' "$out"; exit 1; }

# status line
grep -q "q to quit" <<<"$out" \
  || { echo "FAIL: status-line hint missing"; printf '%s\n' "$out"; exit 1; }

# -----------------------------------------------------------------------------
# Corrupt state — truncated active.json must not crash the script; the Active
# pane degrades to "(no running workers)" and everything else still renders.
# -----------------------------------------------------------------------------
BAD_STATE="$(mktemp -d)"
trap 'rm -rf "$BAD_STATE"' EXIT
cp "$STATE_DIR/budget-used.json" "$BAD_STATE/budget-used.json"
cp "$STATE_DIR/autopickup.json"  "$BAD_STATE/autopickup.json"
printf '{"workers": [' > "$BAD_STATE/active.json"

corrupt_out="$(NO_COLOR=1 "$SCRIPT" --once --logs-dir "$LOGS_DIR" --state-dir "$BAD_STATE")"
grep -q "Recent completions" <<<"$corrupt_out" \
  || { echo "FAIL: corrupt active.json broke the render"; printf '%s\n' "$corrupt_out"; exit 1; }
grep -q "no running workers" <<<"$corrupt_out" \
  || { echo "FAIL: corrupt active.json didn't degrade to empty Active pane"; printf '%s\n' "$corrupt_out"; exit 1; }

# -----------------------------------------------------------------------------
# Missing logs dir — a fresh repo with no logs/ must render clean.
# -----------------------------------------------------------------------------
EMPTY_DIR="$(mktemp -d)"
# EMPTY_DIR cleanup piggy-backs on the earlier trap; append.
trap 'rm -rf "$BAD_STATE" "$EMPTY_DIR"' EXIT

no_logs_out="$(NO_COLOR=1 "$SCRIPT" --once --logs-dir "$EMPTY_DIR/nope" --state-dir "$STATE_DIR")"
grep -q "no recent completions" <<<"$no_logs_out" \
  || { echo "FAIL: missing logs dir didn't render '(no recent completions)'"; printf '%s\n' "$no_logs_out"; exit 1; }
grep -q "Active workers (2)" <<<"$no_logs_out" \
  || { echo "FAIL: missing logs dir broke the active pane"; printf '%s\n' "$no_logs_out"; exit 1; }

echo "SMOKE_OK"

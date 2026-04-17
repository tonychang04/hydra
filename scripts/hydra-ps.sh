#!/usr/bin/env bash
#
# hydra-ps.sh — per-worker detail for in-flight workers from state/active.json.
# Prose table by default; machine-readable JSON with --json.
#
# Usage: ./hydra ps [--json]
#
# --json emits a stable machine-readable shape per
# state/schemas/hydra-status-output.schema.json (the ps_output definition).
# See docs/specs/2026-04-17-json-output-mode.md (ticket #105).
#
# Spec: docs/specs/2026-04-17-json-output-mode.md

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"

# shellcheck disable=SC1091
[[ -f "$ROOT_DIR/.hydra.env" ]] && source "$ROOT_DIR/.hydra.env"

# HYDRA_STATE_DIR lets callers (notably self-tests) point the script at a
# fixture directory instead of the real state/ tree. Defaults to $ROOT_DIR/state.
STATE_DIR="${HYDRA_STATE_DIR:-$ROOT_DIR/state}"

usage() {
  cat <<'EOF'
Usage: ./hydra ps [options]

Prints per-worker detail for every in-flight worker tracked in
state/active.json. Each row (or JSON object) includes id, ticket, repo,
tier, started_at, worktree, branch, status, and minutes_running.

Does NOT launch a Claude session. Safe for scripts / cron / SSH.

Options:
  --json     Emit machine-readable JSON per
             state/schemas/hydra-status-output.schema.json (ps_output).
             Suppresses ANSI colors and the human table.
  -h, --help Show this help.

Environment:
  HYDRA_STATE_DIR   Override the state/ directory (default: $ROOT/state).
                    Used by self-tests to point at deterministic fixtures.

Exit codes:
  0   OK (including when state/active.json is missing — emits an empty set)
  1   state/active.json present but malformed JSON
  2   usage error
EOF
}

json_mode=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --json) json_mode=1; shift ;;
    *) echo "✗ unknown arg: $1" >&2; usage >&2; exit 2 ;;
  esac
done

# JSON mode suppresses ANSI colors unconditionally.
if [[ "$json_mode" -eq 0 ]] && [[ -t 1 ]] && [[ "${NO_COLOR:-}" != "1" ]]; then
  C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'; C_RESET=$'\033[0m'
else
  C_BOLD=""; C_DIM=""; C_RESET=""
fi

active_file="$STATE_DIR/active.json"

# -----------------------------------------------------------------------------
# Load workers. Empty array if the file is missing; exit 1 if it exists but
# is malformed (matches the "be strict on present-but-broken, lenient on
# absent" pattern used elsewhere in the CLI).
# -----------------------------------------------------------------------------
if [[ -f "$active_file" ]]; then
  if ! jq empty "$active_file" 2>/dev/null; then
    echo "✗ $active_file is not valid JSON" >&2
    exit 1
  fi
  workers_raw="$(jq -c '(.workers // [])' "$active_file")"
else
  workers_raw="[]"
fi

now_epoch="$(date -u +%s)"

# Augment each worker with minutes_running = (now - started_at) / 60, rounded
# to one decimal. started_at is ISO-8601 per active.schema.json. Use python
# (universally available on macOS + linux) for cross-platform date parsing —
# macOS `date -d` is BSD-only and doesn't accept ISO-8601.
workers_augmented="$(printf '%s' "$workers_raw" | python3 -c '
import json, sys
from datetime import datetime, timezone

now_epoch = int(sys.argv[1])
workers = json.load(sys.stdin)
for w in workers:
    started = w.get("started_at")
    if not started:
        w["minutes_running"] = 0
        continue
    try:
        # Normalize "Z" suffix to UTC offset for fromisoformat.
        s = started
        if s.endswith("Z"):
            s = s[:-1] + "+00:00"
        dt = datetime.fromisoformat(s)
        if dt.tzinfo is None:
            dt = dt.replace(tzinfo=timezone.utc)
        started_epoch = int(dt.timestamp())
        delta_min = max(0, (now_epoch - started_epoch) / 60.0)
        # Round to 1 decimal, coerce to float for stable JSON.
        w["minutes_running"] = round(delta_min, 1)
    except Exception:
        w["minutes_running"] = 0
print(json.dumps(workers))
' "$now_epoch")"

# -----------------------------------------------------------------------------
# JSON mode — emit the ps_output shape defined in
# state/schemas/hydra-status-output.schema.json.
# -----------------------------------------------------------------------------
if [[ "$json_mode" -eq 1 ]]; then
  generated_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  jq -n \
    --arg version "1.0" \
    --arg generated_at "$generated_at" \
    --argjson workers "$workers_augmented" \
    '{
      version: $version,
      generated_at: $generated_at,
      workers: $workers
    }'
  exit 0
fi

# -----------------------------------------------------------------------------
# prose path — simple table. One row per worker; empty state gets a banner.
# -----------------------------------------------------------------------------
printf "%s▸ Hydra ps%s\n" "$C_BOLD" "$C_RESET"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

worker_count="$(printf '%s' "$workers_augmented" | jq 'length')"
if [[ "$worker_count" -eq 0 ]]; then
  printf "  %s(no active workers)%s\n" "$C_DIM" "$C_RESET"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  exit 0
fi

# Column widths tuned to common values (ids ~8 chars, tiers 2 chars, etc.).
printf "  %-10s %-28s %-22s %-4s %-22s %-7s %-10s\n" \
  "ID" "TICKET" "REPO" "TIER" "STARTED_AT" "MINS" "STATUS"
printf "  %-10s %-28s %-22s %-4s %-22s %-7s %-10s\n" \
  "----------" "----------------------------" "----------------------" "----" "----------------------" "-------" "----------"

printf '%s' "$workers_augmented" | jq -r '.[] | [
  .id,
  .ticket,
  .repo,
  .tier,
  .started_at,
  (.minutes_running | tostring),
  .status
] | @tsv' | while IFS=$'\t' read -r id ticket repo tier started mins status; do
  printf "  %-10s %-28s %-22s %-4s %-22s %-7s %-10s\n" \
    "$id" "$ticket" "$repo" "$tier" "$started" "$mins" "$status"
done

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
exit 0

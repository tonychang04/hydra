#!/usr/bin/env bash
#
# hydra-status.sh — read-only snapshot that mirrors Commander's session-start
# greeting. Does NOT open a chat / launch claude. Safe to run from scripts or
# cron.
#
# Usage: ./hydra status [--with-tickets]
#
# Spec: docs/specs/2026-04-16-hydra-cli.md (ticket #25)

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"

# shellcheck disable=SC1091
[[ -f "$ROOT_DIR/.hydra.env" ]] && source "$ROOT_DIR/.hydra.env"

usage() {
  cat <<'EOF'
Usage: ./hydra status [options]

Prints a read-only snapshot of Hydra state:
  - tickets ready (best-effort gh count if --with-tickets)
  - active workers from state/active.json
  - today's throughput from state/budget-used.json
  - autopickup state from state/autopickup.json
  - PAUSE file present / absent
  - pending dispatches in state/pending-dispatches.json

Does NOT launch a Claude session. Safe for scripts / cron / SSH.

Options:
  --with-tickets    Also count `gh issue list --assignee @me` across enabled
                    repos. Requires gh CLI + auth. Slower (N network calls).
  -h, --help        Show this help.

Exit codes:
  0   OK (including when state files are missing — prints "unset")
  1   repo root malformed
EOF
}

if [[ -t 1 ]] && [[ "${NO_COLOR:-}" != "1" ]]; then
  C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'; C_GREEN=$'\033[32m'; C_RED=$'\033[31m'
  C_YELLOW=$'\033[33m'; C_RESET=$'\033[0m'
else
  C_BOLD=""; C_DIM=""; C_GREEN=""; C_RED=""; C_YELLOW=""; C_RESET=""
fi

with_tickets=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --with-tickets) with_tickets=1; shift ;;
    *) echo "✗ unknown arg: $1" >&2; usage >&2; exit 2 ;;
  esac
done

# -----------------------------------------------------------------------------
# helpers
# -----------------------------------------------------------------------------
jq_or() {
  # $1 = file, $2 = jq filter, $3 = fallback
  local f="$1" filter="$2" fb="$3"
  if [[ -f "$f" ]] && jq empty "$f" 2>/dev/null; then
    jq -r "$filter" "$f" 2>/dev/null || printf '%s' "$fb"
  else
    printf '%s' "$fb"
  fi
}

# -----------------------------------------------------------------------------
# read state
# -----------------------------------------------------------------------------
active_count="$(jq_or "$ROOT_DIR/state/active.json" '(.workers // []) | length' "0")"
budget_file="$ROOT_DIR/state/budget-used.json"
tickets_done="$(jq_or "$budget_file" '.tickets_completed_today // 0' "0")"
tickets_failed="$(jq_or "$budget_file" '.tickets_failed_today // 0' "0")"
wall_clock_min="$(jq_or "$budget_file" '.total_worker_wall_clock_minutes_today // 0' "0")"

auto_file="$ROOT_DIR/state/autopickup.json"
auto_enabled="$(jq_or "$auto_file" '.enabled // false' "false")"
auto_interval="$(jq_or "$auto_file" '.interval_min // 30' "30")"
auto_last="$(jq_or "$auto_file" '.last_run // "never"' "never")"
auto_streak="$(jq_or "$auto_file" '.consecutive_rate_limit_hits // 0' "0")"

pause_state="off"
if [[ -f "$ROOT_DIR/PAUSE" ]] || [[ -f "$ROOT_DIR/commander/PAUSE" ]]; then
  pause_state="on"
fi

pending_file="$ROOT_DIR/state/pending-dispatches.json"
pending_count="0"
if [[ -f "$pending_file" ]] && jq empty "$pending_file" 2>/dev/null; then
  pending_count="$(jq -r '(.queue // []) | length' "$pending_file" 2>/dev/null || echo 0)"
fi

# -----------------------------------------------------------------------------
# repo counts
# -----------------------------------------------------------------------------
repos_file="$ROOT_DIR/state/repos.json"
enabled_repos_count="0"
total_repos_count="0"
if [[ -f "$repos_file" ]] && jq empty "$repos_file" 2>/dev/null; then
  total_repos_count="$(jq -r '(.repos // []) | length' "$repos_file")"
  enabled_repos_count="$(jq -r '(.repos // []) | map(select(.enabled == true)) | length' "$repos_file")"
fi

# -----------------------------------------------------------------------------
# optional: tickets ready count (best-effort)
# -----------------------------------------------------------------------------
tickets_ready="unknown"
if [[ "$with_tickets" -eq 1 ]]; then
  if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
    if [[ -f "$repos_file" ]]; then
      total=0
      while IFS=$'\t' read -r owner repo trigger; do
        [[ -z "$owner" ]] && continue
        case "$trigger" in
          assignee)
            n="$(gh issue list --repo "$owner/$repo" --assignee @me --state open --json number --jq 'length' 2>/dev/null || echo 0)"
            ;;
          label)
            n="$(gh issue list --repo "$owner/$repo" --label commander-ready --state open --json number --jq 'length' 2>/dev/null || echo 0)"
            ;;
          linear|*)
            n=0
            ;;
        esac
        total=$((total + n))
      done < <(jq -r '.repos // [] | map(select(.enabled == true)) | .[] | [.owner, .name, (.ticket_trigger // "assignee")] | @tsv' "$repos_file")
      tickets_ready="$total"
    fi
  else
    tickets_ready="skipped (no gh)"
  fi
fi

# -----------------------------------------------------------------------------
# print
# -----------------------------------------------------------------------------
printf "%s▸ Hydra status%s\n" "$C_BOLD" "$C_RESET"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

printf "  Repos:        %s enabled / %s total\n" "$enabled_repos_count" "$total_repos_count"
printf "  Active:       %s worker(s)\n" "$active_count"
printf "  Today:        %s done, %s failed, %s min wall-clock\n" \
  "$tickets_done" "$tickets_failed" "$wall_clock_min"

if [[ "$auto_enabled" == "true" ]]; then
  printf "  Autopickup:   %son%s (every %s min, last_run: %s, rate_limit_streak: %s)\n" \
    "$C_GREEN" "$C_RESET" "$auto_interval" "$auto_last" "$auto_streak"
else
  printf "  Autopickup:   %soff%s (interval_min=%s, last_run: %s)\n" \
    "$C_DIM" "$C_RESET" "$auto_interval" "$auto_last"
fi

if [[ "$pause_state" == "on" ]]; then
  printf "  Pause:        %son%s (PAUSE file present — spawn refused)\n" "$C_RED" "$C_RESET"
else
  printf "  Pause:        off\n"
fi

printf "  Pending:      %s dispatch(es) queued via ./hydra issue\n" "$pending_count"

if [[ "$with_tickets" -eq 1 ]]; then
  printf "  Tickets ready: %s\n" "$tickets_ready"
else
  printf "  %sTickets ready: run with --with-tickets to count via gh%s\n" "$C_DIM" "$C_RESET"
fi

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
exit 0

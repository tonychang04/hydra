#!/usr/bin/env bash
#
# select-worker-backend.sh — resolve which worker subagent type Commander
# should spawn, given a repo's preferred backend and the current quota-health
# state. This is the #97 router that lands #96's dual-backend primitive.
#
# It's the single source of truth for the codex auto-fallback decision — so
# CLAUDE.md, the self-test, and any future MCP dispatcher all agree on when a
# spawn routes to Claude vs Codex. Mirrors scripts/merge-policy-lookup.sh
# (a small read-only lookup Commander calls inside its Operating loop).
#
# READ-ONLY. This script never mutates quota-health.json — auto-recovery is a
# read-time TTL-expiry decision, not a write. The writer side lives in
# scripts/set-backend-fallback.sh.
#
# Usage:
#   select-worker-backend.sh --repo-backend <claude|codex|auto>
#                            [--quota-health <path>] [--now <iso8601>]
#
# Output (stdout): one of
#   worker-implementation          (Claude backend — default)
#   worker-codex-implementation    (Codex backend)
# A one-line human reason is printed to stderr (for the operator chat line).
#
# Decision precedence (first match wins) — full rationale in the spec:
#   1. manual_override == "codex"|"claude"  → that backend (operator's explicit
#      `backend codex` / `backend claude` beats an active auto-fallback).
#   2. fallback_on_rate_limit == false      → repo preferred (auto-switch off).
#   3. active_backend == "codex" AND fallback_expires_at in the future → codex.
#   4. default → repo preferred_backend ("codex" → codex; else claude).
#
# Exit codes:
#   0  success; subagent type printed on stdout
#   2  usage error (missing/invalid --repo-backend, bad flag)
#
# Spec: docs/specs/2026-06-01-codex-auto-fallback.md (ticket #97)
# Depends on: docs/specs/2026-04-17-codex-worker-backend.md (ticket #96)

set -euo pipefail

CLAUDE_AGENT="worker-implementation"
CODEX_AGENT="worker-codex-implementation"

usage() {
  cat <<'EOF'
Usage: select-worker-backend.sh --repo-backend <claude|codex|auto>
                                [--quota-health <path>] [--now <iso8601>]

Resolves the worker subagent type Commander should spawn, applying the codex
auto-fallback decision (ticket #97).

Options:
  --repo-backend <b>   Repo's preferred_backend from state/repos.json
                       (claude | codex | auto). Required.
  --quota-health <p>   Path to quota-health.json (default: state/quota-health.json).
                       Absent/empty file → safe default (claude).
  --now <iso8601>      Override "now" for TTL comparison (default: date -u).
                       Injected by the self-test for deterministic expiry.
  -h, --help           Show this help.

Output (stdout):
  worker-implementation | worker-codex-implementation

Exit codes:
  0 = decision printed · 2 = usage error
EOF
}

repo_backend=""
quota_health="state/quota-health.json"
now_iso=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo-backend)
      [[ $# -ge 2 ]] || { echo "select-worker-backend: --repo-backend needs a value" >&2; usage >&2; exit 2; }
      repo_backend="$2"; shift 2 ;;
    --repo-backend=*) repo_backend="${1#--repo-backend=}"; shift ;;
    --quota-health)
      [[ $# -ge 2 ]] || { echo "select-worker-backend: --quota-health needs a value" >&2; usage >&2; exit 2; }
      quota_health="$2"; shift 2 ;;
    --quota-health=*) quota_health="${1#--quota-health=}"; shift ;;
    --now)
      [[ $# -ge 2 ]] || { echo "select-worker-backend: --now needs a value" >&2; usage >&2; exit 2; }
      now_iso="$2"; shift 2 ;;
    --now=*) now_iso="${1#--now=}"; shift ;;
    -h|--help) usage; exit 0 ;;
    --) shift; break ;;
    -*) echo "select-worker-backend: unknown option: $1" >&2; usage >&2; exit 2 ;;
    *)  echo "select-worker-backend: unexpected positional arg: $1" >&2; usage >&2; exit 2 ;;
  esac
done

case "$repo_backend" in
  claude|codex|auto) ;;
  "") echo "select-worker-backend: --repo-backend is required" >&2; usage >&2; exit 2 ;;
  *)  echo "select-worker-backend: invalid --repo-backend '$repo_backend' (expected claude|codex|auto)" >&2; exit 2 ;;
esac

command -v jq >/dev/null 2>&1 || { echo "select-worker-backend: jq not found on PATH" >&2; exit 2; }

# repo_preferred_agent — the agent the repo's preferred_backend maps to,
# ignoring any fallback. "auto" resolves to claude here (reactive routing is
# applied separately, above this fallthrough).
repo_preferred_agent() {
  case "$repo_backend" in
    codex) printf '%s' "$CODEX_AGENT" ;;
    *)     printf '%s' "$CLAUDE_AGENT" ;;
  esac
}

decide_default() {
  printf '%s' "$(repo_preferred_agent)"
}

# Read quota-health (if present + valid JSON). Treat any missing/invalid file
# as an empty object → safe default path.
qh='{}'
if [[ -f "$quota_health" ]] && jq empty "$quota_health" >/dev/null 2>&1; then
  qh="$(cat "$quota_health")"
fi

manual_override="$(jq -r '.manual_override // empty' <<<"$qh")"
fallback_enabled="$(jq -r 'if (has("fallback_on_rate_limit") and .fallback_on_rate_limit == false) then "false" else "true" end' <<<"$qh")"
active_backend="$(jq -r '.active_backend // empty' <<<"$qh")"
expires_at="$(jq -r '.fallback_expires_at // empty' <<<"$qh")"
fallback_reason="$(jq -r '.fallback_reason // empty' <<<"$qh")"

emit() {
  # $1 = agent, $2 = reason (stderr)
  echo "$2" >&2
  printf '%s\n' "$1"
}

# --- precedence 1: explicit manual override of a concrete backend ----------
case "$manual_override" in
  codex)  emit "$CODEX_AGENT"  "backend: codex (manual override)"; exit 0 ;;
  claude) emit "$CLAUDE_AGENT" "backend: claude (manual override)"; exit 0 ;;
  # "auto" or empty → fall through to fallback logic.
esac

# --- precedence 2: fallback explicitly disabled ----------------------------
if [[ "$fallback_enabled" == "false" ]]; then
  emit "$(decide_default)" "backend: $(decide_default) (auto-fallback disabled)"
  exit 0
fi

# --- precedence 3: active, non-expired codex fallback ----------------------
if [[ "$active_backend" == "codex" && -n "$expires_at" ]]; then
  # epoch compare; if either timestamp can't be parsed, fail safe to default.
  now_epoch=""
  exp_epoch=""
  if [[ -n "$now_iso" ]]; then
    now_epoch="$(date -u -d "$now_iso" +%s 2>/dev/null || date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$now_iso" +%s 2>/dev/null || echo "")"
  else
    now_epoch="$(date -u +%s)"
  fi
  exp_epoch="$(date -u -d "$expires_at" +%s 2>/dev/null || date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$expires_at" +%s 2>/dev/null || echo "")"

  if [[ -n "$now_epoch" && -n "$exp_epoch" && "$now_epoch" -lt "$exp_epoch" ]]; then
    reason_str="${fallback_reason:-claude-rate-limit}"
    emit "$CODEX_AGENT" "backend: codex (active fallback: $reason_str, until $expires_at)"
    exit 0
  fi
  # else: TTL expired → read-time auto-recovery, drop to default.
fi

# --- precedence 4: default to repo preferred -------------------------------
emit "$(decide_default)" "backend: $(decide_default) (repo preferred=$repo_backend)"
exit 0

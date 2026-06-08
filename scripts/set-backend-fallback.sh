#!/usr/bin/env bash
#
# set-backend-fallback.sh — the writer side of the #97 codex auto-fallback.
# Mutates state/quota-health.json to flip the active backend on a rate-limit,
# to apply the operator's `backend <x>` commands, or to report status.
#
# The router (scripts/select-worker-backend.sh) is read-only and reads what
# this script writes. Keep the two in sync via the shared spec.
#
# Usage:
#   set-backend-fallback.sh --trigger <class> [--ttl-hours N] [--quota-health <p>] [--now <iso8601>]
#   set-backend-fallback.sh --set <claude|codex|auto>          [--quota-health <p>] [--now <iso8601>]
#   set-backend-fallback.sh --status                            [--quota-health <p>] [--now <iso8601>]
#
# Modes:
#   --trigger <class>   A rate-limit was detected. <class> must be one of the
#                       allow-listed rate-limit classes (claude-rate-limit,
#                       anthropic-api-429, session-token-exhausted) — any other
#                       class is REFUSED (exit 2) so schema drift, lock drift,
#                       or a network blip never switches the backend. Sets
#                       active_backend=codex, fallback_reason=<class>,
#                       fallback_expires_at=now+N (default N=1), and records
#                       last_rate_limit_at / rate_limit_class. No-op when
#                       fallback_on_rate_limit is false (the operator off-switch).
#
#   --set <b>           The `backend <x>` operator commands.
#                       codex/claude → set manual_override to that value.
#                       auto         → clear manual_override AND any active
#                                      fallback fields (re-enable auto-fallback,
#                                      start clean).
#
#   --status            Read-only. Print active backend + reason + TTL remaining.
#
# Security: never logs token/quota *values* — only the class string and ISO
# timestamps. Writes are atomic (temp file + mv).
#
# Exit codes:
#   0  success
#   1  bad state file (invalid JSON) / write failure
#   2  usage error / refused trigger class
#
# Spec: docs/specs/2026-06-01-codex-auto-fallback.md (ticket #97)

set -euo pipefail

# Allow-list of rate-limit classes that may trip the fallback. Anything else
# is refused — this is the guard against non-rate-limit errors switching the
# backend (ticket #97 review focus (a)).
RL_CLASSES=("claude-rate-limit" "anthropic-api-429" "session-token-exhausted")

usage() {
  cat <<'EOF'
Usage:
  set-backend-fallback.sh --trigger <class> [--ttl-hours N] [--quota-health <p>] [--now <iso8601>]
  set-backend-fallback.sh --set <claude|codex|auto>          [--quota-health <p>] [--now <iso8601>]
  set-backend-fallback.sh --status                            [--quota-health <p>] [--now <iso8601>]

Modes:
  --trigger <class>   Flip to codex on a rate-limit. <class> must be one of:
                      claude-rate-limit | anthropic-api-429 | session-token-exhausted.
                      Any other class is refused (exit 2). No-op when
                      fallback_on_rate_limit is false.
  --set <b>           backend command. codex/claude set manual_override;
                      auto clears manual_override + active fallback fields.
  --status            Read-only; print active backend + reason + TTL remaining.

Options:
  --ttl-hours N        Fallback lifetime in hours (default 1). --trigger only.
  --quota-health <p>   Path to quota-health.json (default: state/quota-health.json).
  --now <iso8601>      Override "now" (default: date -u). For deterministic tests.
  -h, --help           Show this help.

Exit codes:
  0 = ok · 1 = bad state file / write failure · 2 = usage / refused class
EOF
}

mode=""
trigger_class=""
set_value=""
ttl_hours="1"
quota_health="state/quota-health.json"
now_iso=""

set_mode() {
  [[ -z "$mode" ]] || { echo "set-backend-fallback: --trigger / --set / --status are mutually exclusive" >&2; usage >&2; exit 2; }
  mode="$1"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --trigger)
      set_mode trigger
      [[ $# -ge 2 ]] || { echo "set-backend-fallback: --trigger needs a class" >&2; usage >&2; exit 2; }
      trigger_class="$2"; shift 2 ;;
    --trigger=*) set_mode trigger; trigger_class="${1#--trigger=}"; shift ;;
    --set)
      set_mode set
      [[ $# -ge 2 ]] || { echo "set-backend-fallback: --set needs a value" >&2; usage >&2; exit 2; }
      set_value="$2"; shift 2 ;;
    --set=*) set_mode set; set_value="${1#--set=}"; shift ;;
    --status) set_mode status; shift ;;
    --ttl-hours)
      [[ $# -ge 2 ]] || { echo "set-backend-fallback: --ttl-hours needs a value" >&2; usage >&2; exit 2; }
      ttl_hours="$2"; shift 2 ;;
    --ttl-hours=*) ttl_hours="${1#--ttl-hours=}"; shift ;;
    --quota-health)
      [[ $# -ge 2 ]] || { echo "set-backend-fallback: --quota-health needs a value" >&2; usage >&2; exit 2; }
      quota_health="$2"; shift 2 ;;
    --quota-health=*) quota_health="${1#--quota-health=}"; shift ;;
    --now)
      [[ $# -ge 2 ]] || { echo "set-backend-fallback: --now needs a value" >&2; usage >&2; exit 2; }
      now_iso="$2"; shift 2 ;;
    --now=*) now_iso="${1#--now=}"; shift ;;
    -h|--help) usage; exit 0 ;;
    --) shift; break ;;
    -*) echo "set-backend-fallback: unknown option: $1" >&2; usage >&2; exit 2 ;;
    *)  echo "set-backend-fallback: unexpected positional arg: $1" >&2; usage >&2; exit 2 ;;
  esac
done

[[ -n "$mode" ]] || { echo "set-backend-fallback: one of --trigger / --set / --status is required" >&2; usage >&2; exit 2; }

command -v jq >/dev/null 2>&1 || { echo "set-backend-fallback: jq not found on PATH" >&2; exit 1; }

# Resolve "now" to an epoch + a normalized ISO string we control.
to_epoch() {
  local iso="$1"
  date -u -d "$iso" +%s 2>/dev/null || date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$iso" +%s 2>/dev/null || echo ""
}
epoch_to_iso() {
  local e="$1"
  date -u -d "@$e" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -r "$e" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo ""
}

if [[ -n "$now_iso" ]]; then
  now_epoch="$(to_epoch "$now_iso")"
  [[ -n "$now_epoch" ]] || { echo "set-backend-fallback: could not parse --now '$now_iso'" >&2; exit 2; }
else
  now_epoch="$(date -u +%s)"
fi
now_norm="$(epoch_to_iso "$now_epoch")"

# Load current state (empty object if absent). Bail on a corrupt non-empty file.
if [[ -f "$quota_health" ]]; then
  if ! jq empty "$quota_health" >/dev/null 2>&1; then
    echo "set-backend-fallback: $quota_health is not valid JSON" >&2
    exit 1
  fi
  cur="$(cat "$quota_health")"
else
  cur='{}'
fi

# Atomic write helper.
write_state() {
  local new_json="$1"
  local dir; dir="$(dirname "$quota_health")"
  mkdir -p "$dir"
  local tmp; tmp="$(mktemp "${dir}/.quota-health.XXXXXX")"
  printf '%s\n' "$new_json" > "$tmp"
  mv "$tmp" "$quota_health"
}

case "$mode" in
  status)
    ab="$(jq -r '.active_backend // "claude"' <<<"$cur")"
    reason="$(jq -r '.fallback_reason // "none"' <<<"$cur")"
    exp="$(jq -r '.fallback_expires_at // empty' <<<"$cur")"
    enabled="$(jq -r 'if (has("fallback_on_rate_limit") and .fallback_on_rate_limit == false) then "disabled" else "enabled" end' <<<"$cur")"
    override="$(jq -r '.manual_override // "none"' <<<"$cur")"
    ttl_str="n/a"
    if [[ -n "$exp" ]]; then
      exp_epoch="$(to_epoch "$exp")"
      if [[ -n "$exp_epoch" ]]; then
        remaining=$(( exp_epoch - now_epoch ))
        if [[ "$remaining" -gt 0 ]]; then
          ttl_str="$(( remaining / 60 ))m remaining (until $exp)"
        else
          ttl_str="expired (was $exp)"
        fi
      fi
    fi
    echo "active_backend: $ab"
    echo "fallback_reason: $reason"
    echo "fallback_ttl: $ttl_str"
    echo "auto_fallback: $enabled"
    echo "manual_override: $override"
    exit 0
    ;;

  set)
    case "$set_value" in
      codex|claude)
        new="$(jq --arg v "$set_value" '.manual_override = $v' <<<"$cur")"
        write_state "$new"
        echo "manual_override set to '$set_value' — overrides auto-fallback until 'backend auto'."
        exit 0
        ;;
      auto)
        # Clear override AND any active fallback fields → start clean.
        new="$(jq 'del(.manual_override, .active_backend, .fallback_reason, .fallback_expires_at)' <<<"$cur")"
        write_state "$new"
        echo "backend auto — cleared manual override and any active fallback; auto-fallback re-enabled."
        exit 0
        ;;
      *)
        echo "set-backend-fallback: --set must be one of claude|codex|auto (got '$set_value')" >&2
        exit 2
        ;;
    esac
    ;;

  trigger)
    # Validate the class against the allow-list. Refuse anything else.
    allowed=0
    for c in "${RL_CLASSES[@]}"; do
      [[ "$trigger_class" == "$c" ]] && allowed=1 && break
    done
    if [[ "$allowed" -ne 1 ]]; then
      echo "set-backend-fallback: refusing --trigger with non-rate-limit class '$trigger_class' (allowed: ${RL_CLASSES[*]})" >&2
      exit 2
    fi

    # Off-switch: no-op when fallback disabled. Still record the signal time so
    # `quota` reporting is accurate, but do NOT switch the backend.
    enabled="$(jq -r 'if (has("fallback_on_rate_limit") and .fallback_on_rate_limit == false) then "false" else "true" end' <<<"$cur")"
    if [[ "$enabled" == "false" ]]; then
      new="$(jq --arg t "$now_norm" --arg c "$trigger_class" \
        '.last_rate_limit_at = $t | .rate_limit_class = $c' <<<"$cur")"
      write_state "$new"
      echo "rate-limit recorded ($trigger_class) but auto-fallback is disabled — backend unchanged."
      exit 0
    fi

    # Validate ttl_hours is a positive integer.
    if ! [[ "$ttl_hours" =~ ^[0-9]+$ ]] || [[ "$ttl_hours" -lt 1 ]]; then
      echo "set-backend-fallback: --ttl-hours must be a positive integer (got '$ttl_hours')" >&2
      exit 2
    fi

    exp_epoch=$(( now_epoch + ttl_hours * 3600 ))
    exp_iso="$(epoch_to_iso "$exp_epoch")"
    [[ -n "$exp_iso" ]] || { echo "set-backend-fallback: failed to compute TTL expiry" >&2; exit 1; }

    new="$(jq \
      --arg t "$now_norm" \
      --arg c "$trigger_class" \
      --arg exp "$exp_iso" \
      '.active_backend = "codex"
       | .fallback_reason = $c
       | .fallback_expires_at = $exp
       | .last_rate_limit_at = $t
       | .rate_limit_class = $c' <<<"$cur")"
    write_state "$new"
    echo "⚠ $trigger_class detected — switched to codex backend until $exp_iso. Re-enable with 'backend claude' or wait for auto-recovery."
    exit 0
    ;;
esac

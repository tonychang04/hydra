#!/usr/bin/env bash
#
# hydra-setup.sh — first-run / idempotent setup wizard.
#
# Wraps ./setup.sh (env check + .hydra.env + launcher regen + state staging)
# and layers on:
#   1. Repo picker (owner/name lines; blank line to finish)
#   2. Autopickup interval + auto-enable config
#   3. Connector hint (deferred to ./hydra connect)
#   4. state/setup-complete.json fingerprint (schema-validated)
#
# Safe to re-run. On re-entry, prints current config and exits unless
# the operator chooses [u]pdate or passes flags that change state.
#
# Usage:
#   ./hydra setup
#   ./hydra setup --non-interactive --repos=owner/a,owner/b [--autopickup-interval=30] [--autopickup-auto-enable=true]
#
# Non-interactive mode is implied when stdin is not a TTY.
#
# Spec: docs/specs/2026-04-17-setup-wizard.md (ticket #152)

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"

# -----------------------------------------------------------------------------
# color
# -----------------------------------------------------------------------------
if [[ -t 1 ]] && [[ "${NO_COLOR:-}" != "1" ]]; then
  C_GREEN=$'\033[32m'
  C_YELLOW=$'\033[33m'
  C_RED=$'\033[31m'
  C_BOLD=$'\033[1m'
  C_DIM=$'\033[2m'
  C_RESET=$'\033[0m'
else
  C_GREEN=""; C_YELLOW=""; C_RED=""; C_BOLD=""; C_DIM=""; C_RESET=""
fi

say()  { printf "\n%s▸ %s%s\n" "$C_BOLD" "$*" "$C_RESET"; }
step() { printf "\n%s[%s]%s %s%s%s\n" "$C_DIM" "$1" "$C_RESET" "$C_BOLD" "$2" "$C_RESET"; }
ok()   { printf "  %s✓%s %s\n" "$C_GREEN" "$C_RESET" "$*"; }
warn() { printf "  %s⚠%s %s\n" "$C_YELLOW" "$C_RESET" "$*"; }
err()  { printf "  %s✗%s %s\n" "$C_RED" "$C_RESET" "$*" >&2; }
dim()  { printf "    %s%s%s\n" "$C_DIM" "$*" "$C_RESET"; }

usage() {
  cat <<'EOF'
Usage: ./hydra setup [options]

First-run wizard: env check + repo picker + autopickup config + connector hint.
Safe to re-run (idempotent; shows current config; never clobbers without consent).

Options:
  --non-interactive           Skip all prompts; require flags for any config.
                              Also auto-enabled when stdin is not a TTY.
  --repos=A/B,C/D             Comma-separated list of owner/name slugs to add.
                              Each repo's local clone must already exist on disk
                              (the wrapper calls ./hydra add-repo under the hood).
  --autopickup-interval=N     Minutes between autopickup ticks (5..120). Default 30.
  --autopickup-auto-enable=B  true|false — flip state/autopickup.json's
                              auto_enable_on_session_start. Default true.
  -h, --help                  Show this help.

Exit codes:
  0  setup completed (or already complete with no changes)
  1  I/O or validation error (schema, git, bad slug)
  2  usage error / unknown flag

Spec: docs/specs/2026-04-17-setup-wizard.md (ticket #152)
EOF
}

# -----------------------------------------------------------------------------
# args
# -----------------------------------------------------------------------------
INTERACTIVE=1
REPOS_CSV=""
AUTOPICKUP_INTERVAL=""
AUTOPICKUP_AUTO_ENABLE=""
REPOS_CSV_SET=0
AUTOPICKUP_INTERVAL_SET=0
AUTOPICKUP_AUTO_ENABLE_SET=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --non-interactive|--ci) INTERACTIVE=0; shift ;;
    --repos)
      [[ $# -ge 2 ]] || { err "--repos needs a value"; usage >&2; exit 2; }
      REPOS_CSV="$2"; REPOS_CSV_SET=1; shift 2 ;;
    --repos=*)
      REPOS_CSV="${1#--repos=}"; REPOS_CSV_SET=1; shift ;;
    --autopickup-interval)
      [[ $# -ge 2 ]] || { err "--autopickup-interval needs a value"; usage >&2; exit 2; }
      AUTOPICKUP_INTERVAL="$2"; AUTOPICKUP_INTERVAL_SET=1; shift 2 ;;
    --autopickup-interval=*)
      AUTOPICKUP_INTERVAL="${1#--autopickup-interval=}"; AUTOPICKUP_INTERVAL_SET=1; shift ;;
    --autopickup-auto-enable)
      [[ $# -ge 2 ]] || { err "--autopickup-auto-enable needs a value"; usage >&2; exit 2; }
      AUTOPICKUP_AUTO_ENABLE="$2"; AUTOPICKUP_AUTO_ENABLE_SET=1; shift 2 ;;
    --autopickup-auto-enable=*)
      AUTOPICKUP_AUTO_ENABLE="${1#--autopickup-auto-enable=}"; AUTOPICKUP_AUTO_ENABLE_SET=1; shift ;;
    --) shift; break ;;
    -*)
      err "unknown flag: $1"; usage >&2; exit 2 ;;
    *)
      err "unexpected positional argument: $1"; usage >&2; exit 2 ;;
  esac
done

# Auto-detect non-interactive: closed stdin, HYDRA_NON_INTERACTIVE, CI=true.
if [[ ! -t 0 ]] || [[ "${HYDRA_NON_INTERACTIVE:-}" = "1" ]] || [[ "${CI:-}" = "true" ]]; then
  INTERACTIVE=0
fi

# Validate autopickup interval early if provided.
if [[ "$AUTOPICKUP_INTERVAL_SET" -eq 1 ]]; then
  if ! [[ "$AUTOPICKUP_INTERVAL" =~ ^[0-9]+$ ]] \
     || [[ "$AUTOPICKUP_INTERVAL" -lt 5 ]] \
     || [[ "$AUTOPICKUP_INTERVAL" -gt 120 ]]; then
    err "--autopickup-interval must be an integer in [5, 120], got '$AUTOPICKUP_INTERVAL'"
    exit 2
  fi
fi

# Validate autopickup-auto-enable early if provided.
if [[ "$AUTOPICKUP_AUTO_ENABLE_SET" -eq 1 ]]; then
  case "$AUTOPICKUP_AUTO_ENABLE" in
    true|false) ;;
    *) err "--autopickup-auto-enable must be 'true' or 'false', got '$AUTOPICKUP_AUTO_ENABLE'"; exit 2 ;;
  esac
fi

cd "$ROOT_DIR"

# -----------------------------------------------------------------------------
# helpers
# -----------------------------------------------------------------------------
atomic_write_json() {
  # atomic_write_json <target> <jq-filter> [<jq-args>...]
  # Pipe existing file (or empty object) through jq, schema-validate tmpfile,
  # then mv. Returns nonzero on validation fail (leaves original untouched).
  local target="$1"; shift
  local filter="$1"; shift
  local tmp
  tmp="$(mktemp "${target}.XXXXXX")"

  local input
  if [[ -f "$target" ]]; then
    input="$(cat "$target")"
  else
    input="{}"
  fi

  if ! printf '%s' "$input" | jq "$@" "$filter" > "$tmp"; then
    err "jq failed for $target"
    rm -f "$tmp"
    return 1
  fi

  # Resolve the schema explicitly: validate-state.sh auto-detects by stripping
  # .json from the basename, but our tmpfile is <target>.XXXXXX (no .json
  # suffix) so auto-detection picks the wrong schema name. Point at the
  # schema derived from the *target* basename instead.
  local target_base
  target_base="$(basename "$target" .json)"
  local schema_file="$ROOT_DIR/state/schemas/${target_base}.schema.json"
  if ! "$ROOT_DIR/scripts/validate-state.sh" --schema "$schema_file" "$tmp" >/dev/null 2>&1; then
    # Re-run with output so operator sees what failed.
    "$ROOT_DIR/scripts/validate-state.sh" --schema "$schema_file" "$tmp" >&2 || true
    err "schema validation failed for $target — not writing"
    rm -f "$tmp"
    return 1
  fi

  mv "$tmp" "$target"
}

launcher_marker() {
  # Returns 8-hex marker for the current ./hydra launcher, or "unknown"
  # if tooling is missing. Never exits nonzero — setup-complete write
  # shouldn't fail just because sha256 isn't on PATH.
  if [[ -x "$ROOT_DIR/scripts/launcher-marker.sh" ]] && [[ -f "$ROOT_DIR/hydra" ]]; then
    local m
    m="$("$ROOT_DIR/scripts/launcher-marker.sh" extract "$ROOT_DIR/hydra" 2>/dev/null || true)"
    # 8 lowercase hex chars expected
    if [[ "$m" =~ ^[0-9a-f]{8}$ ]]; then
      printf '%s' "$m"
      return 0
    fi
  fi
  printf 'unknown'
}

iso_utc_now() {
  date -u +"%Y-%m-%dT%H:%M:%SZ"
}

valid_slug() {
  [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*/[A-Za-z0-9][A-Za-z0-9_.-]*$ ]]
}

# -----------------------------------------------------------------------------
# idempotent re-run check
# -----------------------------------------------------------------------------
COMPLETE_FILE="$ROOT_DIR/state/setup-complete.json"
ACTION="first-run"  # first-run | update | no-op

if [[ -f "$COMPLETE_FILE" ]]; then
  prev_when="$(jq -r '.completed_at // "unknown"' "$COMPLETE_FILE" 2>/dev/null || echo unknown)"
  prev_mode="$(jq -r '.mode // "unknown"' "$COMPLETE_FILE" 2>/dev/null || echo unknown)"
  prev_ver="$(jq -r '.version // "unknown"' "$COMPLETE_FILE" 2>/dev/null || echo unknown)"

  say "Hydra setup at $ROOT_DIR"
  dim "Setup already completed on $prev_when ($prev_mode, version $prev_ver)."

  # Report current config.
  printf "\n%sCurrent config:%s\n" "$C_BOLD" "$C_RESET"
  if [[ -f "$ROOT_DIR/state/repos.json" ]]; then
    repo_count="$(jq -r '.repos // [] | length' "$ROOT_DIR/state/repos.json" 2>/dev/null || echo 0)"
    dim "Repos ($repo_count):"
    jq -r '.repos // [] | .[] | "    " + (if .enabled then "✓" else "○" end) + " " + .owner + "/" + .name + " (trigger=" + (.ticket_trigger // "assignee") + ")"' "$ROOT_DIR/state/repos.json" 2>/dev/null || true
  else
    dim "Repos: (none tracked yet)"
  fi
  if [[ -f "$ROOT_DIR/state/autopickup.json" ]]; then
    ap_int="$(jq -r '.interval_min' "$ROOT_DIR/state/autopickup.json" 2>/dev/null || echo ?)"
    ap_enabled="$(jq -r '.enabled' "$ROOT_DIR/state/autopickup.json" 2>/dev/null || echo ?)"
    ap_auto="$(jq -r '.auto_enable_on_session_start' "$ROOT_DIR/state/autopickup.json" 2>/dev/null || echo ?)"
    dim "Autopickup: enabled=$ap_enabled (auto_on_session_start=$ap_auto), interval=${ap_int}min"
  fi

  # Decide what to do.
  if [[ "$INTERACTIVE" -eq 0 ]]; then
    # Non-interactive re-run. If any state-changing flag was set, apply it; else no-op.
    if [[ "$REPOS_CSV_SET" -eq 1 ]] || [[ "$AUTOPICKUP_INTERVAL_SET" -eq 1 ]] || [[ "$AUTOPICKUP_AUTO_ENABLE_SET" -eq 1 ]]; then
      ACTION="update"
      dim "(non-interactive re-run with flags — applying updates)"
    else
      ACTION="no-op"
      printf "\n%s━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━%s\n" "$C_DIM" "$C_RESET"
      printf "Setup already complete — no changes.\n"
      exit 0
    fi
  else
    printf "\nWhat now? [u]pdate / [q]uit [q]: "
    IFS= read -r choice || choice=""
    choice="${choice:-q}"
    case "$choice" in
      u|U|update) ACTION="update" ;;
      q|Q|quit|*) ACTION="no-op"; printf "\nNo changes.\n"; exit 0 ;;
    esac
  fi
fi

# -----------------------------------------------------------------------------
# [1/4] Delegate to ./setup.sh (env check + .hydra.env + launcher regen + state staging)
# -----------------------------------------------------------------------------
step "1/4" "Environment check + base config"

# Pass only the flags setup.sh understands. --ci is setup.sh's alias for
# --non-interactive; we use --non-interactive here to stay explicit.
SETUP_ARGS=()
if [[ "$INTERACTIVE" -eq 0 ]]; then
  SETUP_ARGS+=("--non-interactive")
fi

if ! bash "$ROOT_DIR/setup.sh" ${SETUP_ARGS[@]+"${SETUP_ARGS[@]}"}; then
  err "./setup.sh failed — fix the errors above and re-run ./hydra setup"
  exit 1
fi

# -----------------------------------------------------------------------------
# [2/4] Repo picker
# -----------------------------------------------------------------------------
step "2/4" "Add repos to track"
dim "One per line as owner/name. Blank line to finish. (Add more later: ./hydra add-repo)"

# Build the list of slugs to add.
declare -a SLUGS=()

if [[ "$REPOS_CSV_SET" -eq 1 ]]; then
  # Split the CSV. Trim whitespace per entry.
  IFS=',' read -r -a _csv <<< "$REPOS_CSV"
  for slug in "${_csv[@]}"; do
    slug="${slug// /}"
    [[ -z "$slug" ]] && continue
    if ! valid_slug "$slug"; then
      err "invalid slug '$slug' — expected <owner>/<name>"
      exit 1
    fi
    SLUGS+=("$slug")
  done
elif [[ "$INTERACTIVE" -eq 1 ]]; then
  while :; do
    printf "  %s>%s " "$C_BOLD" "$C_RESET"
    IFS= read -r line || line=""
    # Blank → finish.
    if [[ -z "${line// /}" ]]; then
      break
    fi
    slug="${line// /}"
    if ! valid_slug "$slug"; then
      warn "not a valid <owner>/<name>: '$line' — try again (or blank to finish)"
      continue
    fi
    SLUGS+=("$slug")
  done
else
  dim "(non-interactive, no --repos= — skipping repo picker; add later with ./hydra add-repo)"
fi

# Add each. Skip gracefully if already present (add-repo errors with exit 2
# on duplicate without --force; we treat that as "already tracked, move on").
if [[ ${#SLUGS[@]} -gt 0 ]]; then
  for slug in "${SLUGS[@]}"; do
    # We intentionally do NOT pass --force. Duplicate = already tracked.
    set +e
    out="$(bash "$ROOT_DIR/scripts/hydra-add-repo.sh" "$slug" --non-interactive 2>&1)"
    rc=$?
    set -e
    case $rc in
      0)  ok "$slug added" ;;
      2)
        # Exit 2 on duplicate without --force. Other usage errors also map here
        # but should be rare at this point (we already shape-validated the slug).
        if printf '%s' "$out" | grep -q "already exists"; then
          warn "$slug already tracked — leaving as-is"
        else
          err "$slug failed: $out"
          exit 1
        fi
        ;;
      *)
        err "$slug failed (hydra-add-repo.sh exit $rc):"
        printf '%s\n' "$out" | sed 's/^/    /' >&2
        if [[ "$INTERACTIVE" -eq 1 ]]; then
          warn "skipping $slug — you can add it later with: ./hydra add-repo $slug --local-path /path/to/clone"
        else
          exit 1
        fi
        ;;
    esac
  done
fi

repo_count="$(jq -r '.repos // [] | length' "$ROOT_DIR/state/repos.json" 2>/dev/null || echo 0)"
ok "$repo_count repo(s) in state/repos.json"

# -----------------------------------------------------------------------------
# [3/4] Autopickup config
# -----------------------------------------------------------------------------
step "3/4" "Configure autopickup"
dim "Autopickup polls your repos at a fixed interval and spawns workers."

# Gather desired interval.
if [[ "$AUTOPICKUP_INTERVAL_SET" -eq 1 ]]; then
  ap_interval="$AUTOPICKUP_INTERVAL"
elif [[ "$INTERACTIVE" -eq 1 ]]; then
  # Read current interval as default (setup.sh seeded 30 on fresh install).
  current_int="30"
  if [[ -f "$ROOT_DIR/state/autopickup.json" ]]; then
    current_int="$(jq -r '.interval_min // 30' "$ROOT_DIR/state/autopickup.json" 2>/dev/null || echo 30)"
  fi
  printf "  Interval (5–120 minutes) [%s]: " "$current_int"
  IFS= read -r line || line=""
  ap_interval="${line:-$current_int}"
  if ! [[ "$ap_interval" =~ ^[0-9]+$ ]] || [[ "$ap_interval" -lt 5 ]] || [[ "$ap_interval" -gt 120 ]]; then
    warn "interval must be 5..120 — using default 30"
    ap_interval=30
  fi
else
  ap_interval=""  # no change
fi

# Gather desired auto-enable.
if [[ "$AUTOPICKUP_AUTO_ENABLE_SET" -eq 1 ]]; then
  ap_auto="$AUTOPICKUP_AUTO_ENABLE"
elif [[ "$INTERACTIVE" -eq 1 ]]; then
  printf "  Auto-enable on session start? [Y/n]: "
  IFS= read -r line || line=""
  case "${line:-y}" in
    y|Y|yes|true|1) ap_auto="true" ;;
    n|N|no|false|0) ap_auto="false" ;;
    *) warn "unrecognized answer — using default (yes)"; ap_auto="true" ;;
  esac
else
  ap_auto=""  # no change
fi

# Apply if either set.
if [[ -n "$ap_interval" ]] || [[ -n "$ap_auto" ]]; then
  # Build a jq update filter that only touches fields we're changing.
  filter='.'
  args=()
  if [[ -n "$ap_interval" ]]; then
    filter="$filter | .interval_min = (\$i | tonumber)"
    args+=(--arg i "$ap_interval")
  fi
  if [[ -n "$ap_auto" ]]; then
    # Coerce to boolean via fromjson (quotes around true/false are bash strings).
    filter="$filter | .auto_enable_on_session_start = (\$a | test(\"^true$\"))"
    args+=(--arg a "$ap_auto")
  fi
  # Ensure required keys are present (setup.sh seeded them; belt-and-braces).
  # Use `has(k)` — jq's // operator treats `false` as "not a value", which
  # would clobber an explicit `false` set one step earlier.
  filter="$filter | (if has(\"enabled\") then . else .enabled = false end) | (if has(\"interval_min\") then . else .interval_min = 30 end) | (if has(\"last_run\") then . else .last_run = null end) | (if has(\"last_picked_count\") then . else .last_picked_count = 0 end) | (if has(\"consecutive_rate_limit_hits\") then . else .consecutive_rate_limit_hits = 0 end) | (if has(\"auto_enable_on_session_start\") then . else .auto_enable_on_session_start = true end)"

  if atomic_write_json "$ROOT_DIR/state/autopickup.json" "$filter" "${args[@]}"; then
    ok "state/autopickup.json updated"
  else
    err "state/autopickup.json update failed"
    exit 1
  fi
else
  ok "state/autopickup.json unchanged"
fi

# -----------------------------------------------------------------------------
# [4/4] Connectors (deferred)
# -----------------------------------------------------------------------------
step "4/4" "Connectors (optional)"
dim "Linear, Slack, and upstream Supervisor MCP wire up via ./hydra connect."
dim "Run \`./hydra connect <linear|slack|supervisor>\` when you're ready — setup leaves that UI untouched."

# -----------------------------------------------------------------------------
# Fingerprint
# -----------------------------------------------------------------------------
say "Writing setup-complete fingerprint"
version="$(launcher_marker)"
completed_at="$(iso_utc_now)"
mode="interactive"
if [[ "$INTERACTIVE" -eq 0 ]]; then
  mode="non-interactive"
fi

# The schema requires 8-hex version. If we couldn't compute one, fall back
# to "00000000" rather than writing "unknown" (schema pattern is ^[0-9a-f]{8}$).
if ! [[ "$version" =~ ^[0-9a-f]{8}$ ]]; then
  warn "launcher marker unavailable — writing version=00000000"
  version="00000000"
fi

filter='. = {version: $v, completed_at: $t, mode: $m}'
args=(--arg v "$version" --arg t "$completed_at" --arg m "$mode")
if atomic_write_json "$COMPLETE_FILE" "$filter" "${args[@]}"; then
  ok "state/setup-complete.json (version=$version, mode=$mode)"
else
  err "state/setup-complete.json write failed"
  exit 1
fi

# -----------------------------------------------------------------------------
# Summary
# -----------------------------------------------------------------------------
printf "\n%s━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━%s\n" "$C_DIM" "$C_RESET"
printf "%sSetup complete.%s\n\n" "$C_BOLD" "$C_RESET"
cat <<EOF
Next:
  ./hydra              Launch the commander
  ./hydra list-repos   Show tracked repos
  ./hydra doctor       Re-run the install sanity-check
  ./hydra connect <x>  Wire up Linear / Slack / Supervisor

Docs: README.md (what) · USING.md (how) · docs/specs/ (why)
EOF

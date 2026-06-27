#!/usr/bin/env bash
#
# hydra-setup.sh — first-time setup wizard.
#
# Usage: ./hydra setup [--non-interactive --strict --repos=A,B --autopickup-interval=N]
#
# Linear flow:
#   1. env check    — delegates to `./hydra doctor --category environment`
#   2. repos loop   — prompt for <owner>/<name> slugs, append via hydra-add-repo.sh
#   3. autopickup   — prompt for interval in [5,120]; write state/autopickup.json
#   4. connector hint (no sub-wizards — just prints pointers)
#   5. fingerprint  — write state/setup-complete.json (incl. repos_registered)
#
# Spec: docs/specs/2026-04-17-setup-wizard.md (ticket #168)
# Spec: docs/specs/2026-05-23-setup-wizard-polish.md (ticket #172 — --strict,
#       repos_registered, defensive env source)
#
# Hard rules:
#   - set -euo pipefail
#   - bash + jq only (no Python/Node)
#   - atomic writes on all state/*.json (tmp + mv)
#   - never touches CLAUDE.md, policy.md, budget.json, settings.local.json,
#     worker subagents
#   - delegates env check + per-repo add — does not duplicate either

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"

# ---------------------------------------------------------------------------
# color / output helpers
# ---------------------------------------------------------------------------
if [[ -t 1 ]] && [[ "${NO_COLOR:-}" != "1" ]]; then
  C_GREEN=$'\033[32m'
  C_RED=$'\033[31m'
  C_YELLOW=$'\033[33m'
  C_DIM=$'\033[2m'
  C_BOLD=$'\033[1m'
  C_RESET=$'\033[0m'
else
  C_GREEN=""; C_RED=""; C_YELLOW=""; C_DIM=""; C_BOLD=""; C_RESET=""
fi

err()  { printf "%s✗%s %s\n" "$C_RED"    "$C_RESET" "$*" >&2; }
ok()   { printf "%s✓%s %s\n" "$C_GREEN"  "$C_RESET" "$*"; }
warn() { printf "%s⚠%s %s\n" "$C_YELLOW" "$C_RESET" "$*" >&2; }
step() { printf "\n%s▸ %s%s\n" "$C_BOLD" "$*" "$C_RESET"; }

# ---------------------------------------------------------------------------
# defensive .hydra.env source
# ---------------------------------------------------------------------------
# Source .hydra.env (if present) so downstream helpers see HYDRA_ROOT etc.
# A missing file is fine — a fresh install legitimately has no .hydra.env yet.
# A *malformed* file (syntax error, partial write) must NOT abort the wizard
# with a raw `set -e` bash trace; catch it and report through the uniform
# err() path with a clean non-zero return.
#
# Subtlety: a *parse-time* syntax error in a sourced file (e.g. an unterminated
# quote) aborts the sourcing shell outright — an `if ! source …` guard does NOT
# catch it, because the failure happens before the guard's exit code is even
# evaluated. So we first parse-check the file with `bash -n` in a subshell
# (parse-only, no execution, cannot abort us); only if it parses do we source
# it, where the `if !` guard still catches any runtime error.
source_hydra_env() {
  local env_file="$ROOT_DIR/.hydra.env"
  [[ -f "$env_file" ]] || return 0
  if ! bash -n "$env_file" 2>/dev/null; then
    err "$env_file is malformed (syntax error) — refusing to source it."
    err "Fix or remove it (a fresh install can regenerate it), then re-run. See: ./hydra doctor."
    return 1
  fi
  # shellcheck disable=SC1090
  if ! source "$env_file" 2>/dev/null; then
    err "failed to source $env_file — the file is unreadable or errored at runtime."
    err "Fix or remove it (a fresh install can regenerate it), then re-run. See: ./hydra doctor."
    return 1
  fi
  return 0
}

source_hydra_env || exit 1

usage() {
  cat <<'EOF'
Usage: ./hydra setup [options]

First-time setup wizard for Hydra. Walks a fresh operator through the minimum
configuration needed to run a spawn loop: env check, repo picker, autopickup
interval, and a fingerprint file at state/setup-complete.json.

Options:
  --non-interactive             Skip all prompts. Accept defaults or flag values.
  --strict                      Fail (exit 2) if ANY repo slug fails validation
                                or registration, instead of warning and
                                continuing. For CI / scripted installs where a
                                partially-applied config must not exit green.
                                Default is permissive (warn + continue).
  --repos=<slugs>               Comma-separated owner/name slugs to register.
                                Only valid with --non-interactive.
  --autopickup-interval=<N>     Integer in [5,120]. Default: 30.
  -h, --help                    Show this help.

Examples:
  # Interactive:
  ./hydra setup

  # CI / scripted (permissive — bad slugs warn, wizard exits 0):
  ./hydra setup --non-interactive \
    --repos=tonychang04/hydra,myorg/myapp \
    --autopickup-interval=30

  # CI / scripted (strict — any bad slug fails the whole run):
  ./hydra setup --non-interactive --strict \
    --repos=tonychang04/hydra,myorg/myapp

Spec: docs/specs/2026-04-17-setup-wizard.md (ticket #168)
Spec: docs/specs/2026-05-23-setup-wizard-polish.md (ticket #172)

Exit codes:
  0   wizard completed
  1   env check failed, I/O error, or unrecoverable validation failure
  2   usage error (bad flags, bad interval, malformed slug in --repos), or
      a repo that failed to register while --strict is set
EOF
}

# ---------------------------------------------------------------------------
# args
# ---------------------------------------------------------------------------
non_interactive=0
strict=0
repos_csv=""
autopickup_interval=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --non-interactive) non_interactive=1; shift ;;
    --strict) strict=1; shift ;;
    --repos) [[ $# -ge 2 ]] || { err "--repos needs a value"; usage >&2; exit 2; }; repos_csv="$2"; shift 2 ;;
    --repos=*) repos_csv="${1#--repos=}"; shift ;;
    --autopickup-interval)
      [[ $# -ge 2 ]] || { err "--autopickup-interval needs a value"; usage >&2; exit 2; }
      autopickup_interval="$2"; shift 2 ;;
    --autopickup-interval=*) autopickup_interval="${1#--autopickup-interval=}"; shift ;;
    *) err "unknown flag: $1"; usage >&2; exit 2 ;;
  esac
done

if [[ -n "$repos_csv" ]] && [[ "$non_interactive" -ne 1 ]]; then
  err "--repos only valid with --non-interactive (interactive mode uses the prompt loop)"
  usage >&2
  exit 2
fi

# ---------------------------------------------------------------------------
# dependency check — jq + doctor script
# ---------------------------------------------------------------------------
command -v jq >/dev/null || { err "jq not found in PATH — install jq first"; exit 1; }

doctor_script="$ROOT_DIR/scripts/hydra-doctor.sh"
add_repo_script="$ROOT_DIR/scripts/hydra-add-repo.sh"
[[ -x "$doctor_script" ]]   || { err "scripts/hydra-doctor.sh missing or not executable"; exit 1; }
[[ -x "$add_repo_script" ]] || { err "scripts/hydra-add-repo.sh missing or not executable"; exit 1; }

# ---------------------------------------------------------------------------
# validate --autopickup-interval up-front
# ---------------------------------------------------------------------------
validate_interval() {
  local n="$1"
  if ! [[ "$n" =~ ^[0-9]+$ ]]; then
    return 1
  fi
  if (( n < 5 || n > 120 )); then
    return 1
  fi
  return 0
}

if [[ -n "$autopickup_interval" ]]; then
  if ! validate_interval "$autopickup_interval"; then
    err "--autopickup-interval must be an integer in [5, 120]; got '$autopickup_interval'"
    exit 2
  fi
fi

# ---------------------------------------------------------------------------
# step 1 — env check (delegate to doctor)
# ---------------------------------------------------------------------------
step "Step 1 — environment check"
if ! HYDRA_ROOT="$ROOT_DIR" "$doctor_script" --category environment; then
  err "environment check failed. Fix the issues above, then re-run ./hydra setup."
  exit 1
fi
ok "environment OK"

# ---------------------------------------------------------------------------
# step 2 — repos
# ---------------------------------------------------------------------------
step "Step 2 — repos to track"

# Validate a single slug (exit 2 if bad). Mirrors hydra-add-repo.sh regex.
validate_slug() {
  local slug="$1"
  [[ "$slug" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]
}

# Append one slug via hydra-add-repo.sh, non-interactive. Prints inner errors
# to stderr and returns the inner exit code. The return code is interpreted by
# register_repo below — this helper itself never decides whether to abort.
#   0 = added, 1 = inner-script failure (e.g. no local clone), 2 = bad slug
add_one_repo() {
  local slug="$1"
  if ! validate_slug "$slug"; then
    err "invalid slug '$slug' — expected <owner>/<name>"
    return 2
  fi
  # Pass --non-interactive so the inner script doesn't prompt. It will
  # auto-suggest local_path from common parent dirs; if no candidate exists,
  # it errors and we surface that.
  if "$add_repo_script" "$slug" --trigger assignee --non-interactive; then
    ok "added $slug"
    return 0
  else
    return 1
  fi
}

# Count of repos that actually landed in state/repos.json. Written into the
# fingerprint (step 5) so a consumer can tell "completed, empty" from
# "completed with repos" without re-parsing state/repos.json.
repos_registered=0

# register_repo — single choke point for adding a slug. Increments the counter
# on success; honors --strict on any failure. In permissive mode (default) a
# failed entry warns and the wizard continues. In strict mode the first failure
# aborts the whole wizard with exit 2 — for CI / scripted installs that must
# not exit green on a partially-applied config.
register_repo() {
  local slug="$1"
  local rc=0
  add_one_repo "$slug" || rc=$?
  if [[ "$rc" -eq 0 ]]; then
    repos_registered=$((repos_registered + 1))
    return 0
  fi
  if [[ "$strict" -eq 1 ]]; then
    err "--strict: could not register '$slug' (exit $rc) — aborting."
    exit 2
  fi
  warn "could not add '$slug' (see error above — continuing)"
  return 1
}

if [[ "$non_interactive" -eq 1 ]]; then
  if [[ -n "$repos_csv" ]]; then
    # Split CSV, skip blanks.
    IFS=',' read -r -a slugs <<< "$repos_csv"
    for slug in "${slugs[@]}"; do
      slug="$(printf '%s' "$slug" | tr -d '[:space:]')"
      [[ -z "$slug" ]] && continue
      register_repo "$slug" || true
    done
  else
    warn "--non-interactive with no --repos — skipping repo registration (you can add later with ./hydra add-repo)"
  fi
else
  printf "%sEnter repos to track, one per line. Blank line to finish.%s\n" "$C_DIM" "$C_RESET"
  while :; do
    printf "  %srepo slug%s (owner/name): " "$C_BOLD" "$C_RESET"
    IFS= read -r line || break
    slug="$(printf '%s' "$line" | tr -d '[:space:]')"
    [[ -z "$slug" ]] && break
    register_repo "$slug" || true
  done
fi

# ---------------------------------------------------------------------------
# step 3 — autopickup interval
# ---------------------------------------------------------------------------
step "Step 3 — autopickup interval"

if [[ -z "$autopickup_interval" ]]; then
  if [[ "$non_interactive" -eq 1 ]]; then
    autopickup_interval=15
  else
    while :; do
      printf "  %sinterval in minutes%s [15]: " "$C_BOLD" "$C_RESET"
      IFS= read -r line || line=""
      line="${line:-15}"
      if validate_interval "$line"; then
        autopickup_interval="$line"
        break
      fi
      warn "invalid — must be an integer in [5, 120]"
    done
  fi
fi

autopickup_file="$ROOT_DIR/state/autopickup.json"
tmp="$(mktemp)"
# shellcheck disable=SC2064
trap "rm -f '$tmp'" EXIT

if [[ -f "$autopickup_file" ]]; then
  # Preserve existing keys (last_run, consecutive_rate_limit_hits, etc.);
  # only overwrite interval_min + auto_enable_on_session_start.
  if ! jq empty "$autopickup_file" 2>/dev/null; then
    err "state/autopickup.json exists but is not valid JSON — refusing to overwrite blindly"
    exit 1
  fi
  jq --argjson iv "$autopickup_interval" \
    '. + {interval_min: $iv, auto_enable_on_session_start: true}' \
    "$autopickup_file" > "$tmp"
else
  # Fresh file — write the minimal shape the schema requires.
  jq -n --argjson iv "$autopickup_interval" '{
    enabled: false,
    interval_min: $iv,
    auto_enable_on_session_start: true,
    last_run: null,
    last_picked_count: 0,
    consecutive_rate_limit_hits: 0
  }' > "$tmp"
fi
mv "$tmp" "$autopickup_file"
trap - EXIT
ok "autopickup interval set to $autopickup_interval min (state/autopickup.json)"

# ---------------------------------------------------------------------------
# step 4 — connector hint (no sub-wizards — pointers only)
# ---------------------------------------------------------------------------
step "Step 4 — connectors (optional, run on demand)"
cat <<EOF
  ./hydra connect linear     — poll Linear tickets via MCP
  ./hydra connect slack      — post PR-ready notifications
  ./hydra connect supervisor — escalate worker questions to an upstream agent
  ./hydra connect digest     — push a daily status paragraph
EOF

# ---------------------------------------------------------------------------
# step 5 — fingerprint
# ---------------------------------------------------------------------------
step "Step 5 — write setup-complete fingerprint"
fingerprint_file="$ROOT_DIR/state/setup-complete.json"
tmp="$(mktemp)"
# shellcheck disable=SC2064
trap "rm -f '$tmp'" EXIT

completed_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
mode_label="interactive"
[[ "$non_interactive" -eq 1 ]] && mode_label="non-interactive"

jq -n \
  --arg completed_at "$completed_at" \
  --arg mode "$mode_label" \
  --argjson repos_registered "$repos_registered" \
  '{version: 1, completed_at: $completed_at, mode: $mode, repos_registered: $repos_registered}' > "$tmp"
mv "$tmp" "$fingerprint_file"
trap - EXIT
ok "wrote $fingerprint_file ($repos_registered repo(s) registered)"

printf "\n%sSetup complete.%s\n" "$C_GREEN$C_BOLD" "$C_RESET"
printf "  Run %s./hydra status%s to see Commander state, or %s./hydra%s to launch a Commander session.\n" \
  "$C_BOLD" "$C_RESET" "$C_BOLD" "$C_RESET"

exit 0

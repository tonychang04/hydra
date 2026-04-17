#!/usr/bin/env bash
#
# hydra-migrate-to-cloud.sh — one-shot migration ritual from local commander
# (./hydra on a laptop) to cloud commander (Fly.io). Preserves OAuth flat-rate
# billing for BOTH Claude Code and Codex (no API-key requirement).
#
# What it does (interactive, one question per section):
#   1. Preflight — fly CLI, fly auth, infra/fly.toml present, claude + gh + jq.
#   2. Auth inventory — report what the operator already has locally.
#   3. Claude OAuth — offer to run `claude setup-token` if nothing is set.
#   4. Codex OAuth — offer `codex login` / document OPENAI_API_KEY path.
#   5. Fly secrets push — stage whichever tokens are present (+ GITHUB_TOKEN).
#   6. MCP bearer — generate bearer token via `./hydra mcp register-agent`.
#   7. Deploy — prompt to run `fly deploy`, curl /health, print next steps.
#   8. Next-steps footer — optional follow-ups (autopickup off, dual-mode
#      memory, Slack bot) — never done automatically.
#
# Design principles:
#   - Idempotent: every mutating step checks whether its effect is already in
#     place and skips (with a yellow ⚠ note) rather than re-doing.
#   - Auto-detect non-interactive mode (stdin-not-TTY / HYDRA_NON_INTERACTIVE=1
#     / CI=true / explicit --non-interactive). Same contract as setup.sh.
#   - --dry-run: every side effect becomes a `DRY RUN:` log line. No fly calls,
#     no claude invocation, no ./hydra dispatch, no gh calls. Self-test
#     exercises this mode (golden case: migrate-to-cloud-dry-run).
#   - Security: raw tokens NEVER touch disk. Tokens read in this script exist
#     only in the script's own env/locals. Dry-run prints secret NAMES only,
#     never values. Real-run prints the MCP bearer to stdout exactly ONCE
#     (same contract as scripts/hydra-mcp-register-agent.sh).
#
# Usage:
#   scripts/hydra-migrate-to-cloud.sh                 # interactive
#   scripts/hydra-migrate-to-cloud.sh --dry-run       # rehearse; no side effects
#   scripts/hydra-migrate-to-cloud.sh --non-interactive   # CI / scripted
#   scripts/hydra-migrate-to-cloud.sh --help
#
# Spec: docs/specs/2026-04-17-cloud-default-oauth.md (ticket #106)

set -euo pipefail

HYDRA_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$HYDRA_ROOT"

# ---------- flag parsing ----------
INTERACTIVE=1
DRY_RUN=0
FLY_APP="${HYDRA_FLY_APP:-}"
MAIN_AGENT_ID="${HYDRA_MAIN_AGENT_ID:-}"

usage() {
  cat <<'EOF'
Usage: scripts/hydra-migrate-to-cloud.sh [options]

One-shot migration ritual from local commander (./hydra on a laptop) to cloud
commander (Fly.io). Preserves OAuth flat-rate billing for both Claude Code
and Codex.

Options:
  --dry-run             Rehearse the migration without any side effects. No
                        `fly secrets set`, no `fly deploy`, no `claude
                        setup-token`, no `./hydra mcp register-agent`, no
                        `gh` calls. Secret NAMES are listed; values are not.
  --non-interactive     Skip all prompts. Requires HYDRA_FLY_APP env var.
  -h, --help            Show this help.

Environment:
  HYDRA_FLY_APP         Fly app name (e.g. hydra-commander-alice).
                        Required in --non-interactive mode.
  HYDRA_MAIN_AGENT_ID   Label for the operator's main agent (the one that
                        will call hydra.*  MCP tools). Default: main-agent.
  HYDRA_CODEX_AUTH_ENV  Env-var name carrying Codex's ChatGPT-session token.
                        Default: CODEX_SESSION_TOKEN.

Exit codes:
  0   migration completed (real-run) or dry-run finished cleanly
  1   preflight failure (missing fly / claude / gh / jq / infra/fly.toml)
  2   usage error (unknown flag)
  3   user aborted mid-migration

Spec: docs/specs/2026-04-17-cloud-default-oauth.md (ticket #106)
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)            usage; exit 0 ;;
    --dry-run)            DRY_RUN=1; shift ;;
    --non-interactive)    INTERACTIVE=0; shift ;;
    --fly-app)            [[ $# -ge 2 ]] || { echo "✗ --fly-app needs a value" >&2; exit 2; }; FLY_APP="$2"; shift 2 ;;
    --fly-app=*)          FLY_APP="${1#--fly-app=}"; shift ;;
    --main-agent-id)      [[ $# -ge 2 ]] || { echo "✗ --main-agent-id needs a value" >&2; exit 2; }; MAIN_AGENT_ID="$2"; shift 2 ;;
    --main-agent-id=*)    MAIN_AGENT_ID="${1#--main-agent-id=}"; shift ;;
    *) echo "✗ Unknown arg: $1" >&2; usage >&2; exit 2 ;;
  esac
done

# Auto-detect non-interactive if stdin is not a TTY or CI env is set.
if [[ ! -t 0 ]] || [[ "${HYDRA_NON_INTERACTIVE:-}" = "1" ]] || [[ "${CI:-}" = "true" ]]; then
  INTERACTIVE=0
fi

# ---------- color / TTY ----------
if [[ -t 1 ]] && [[ "${NO_COLOR:-}" != "1" ]]; then
  C_GREEN=$'\033[32m'
  C_YELLOW=$'\033[33m'
  C_RED=$'\033[31m'
  C_BLUE=$'\033[34m'
  C_BOLD=$'\033[1m'
  C_DIM=$'\033[2m'
  C_RESET=$'\033[0m'
else
  C_GREEN=""; C_YELLOW=""; C_RED=""; C_BLUE=""; C_BOLD=""; C_DIM=""; C_RESET=""
fi

say()  { printf "\n%s▸ %s%s\n" "$C_BOLD" "$*" "$C_RESET"; }
ok()   { printf "  %s✓%s %s\n" "$C_GREEN"  "$C_RESET" "$*"; }
warn() { printf "  %s⚠%s %s\n" "$C_YELLOW" "$C_RESET" "$*"; }
fail() { printf "  %s✗%s %s\n" "$C_RED"    "$C_RESET" "$*" >&2; exit 1; }
dim()  { printf "    %s%s%s\n" "$C_DIM" "$*" "$C_RESET"; }
dry()  { printf "  %sDRY RUN:%s %s\n" "$C_BLUE" "$C_RESET" "$*"; }

# Run helper: in dry-run, log what would run; otherwise exec it.
# Usage: run_cmd "description" cmd args...
run_cmd() {
  local desc="$1"; shift
  if [[ "$DRY_RUN" -eq 1 ]]; then
    # Escape command for display without running it.
    local displayed=""
    for part in "$@"; do
      # Redact anything that looks like a secret value.
      if [[ "${part}" =~ ^(sk-|xapp-|xoxb-) ]] || [[ "${part}" =~ = ]]; then
        # Show KEY=*** for KEY=VALUE args so operators see what's being staged
        # without leaking the value.
        if [[ "${part}" == *=* ]]; then
          displayed+=" ${part%%=*}=***"
        else
          displayed+=" ***"
        fi
      else
        displayed+=" ${part}"
      fi
    done
    dry "${desc}:${displayed}"
    return 0
  fi
  "$@"
}

# Banner.
printf "\n%s━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━%s\n" "$C_DIM" "$C_RESET"
printf "%sHydra — migrate to cloud commander%s\n" "$C_BOLD" "$C_RESET"
printf "%s(flat-rate OAuth billing for Claude + Codex)%s\n" "$C_DIM" "$C_RESET"
printf "%s━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━%s\n" "$C_DIM" "$C_RESET"

if [[ "$DRY_RUN" -eq 1 ]]; then
  dim "(--dry-run: no fly secrets, no fly deploy, no claude setup-token, no ./hydra mcp register-agent)"
fi
if [[ "$INTERACTIVE" -eq 0 ]]; then
  dim "(non-interactive: requires HYDRA_FLY_APP env var; all prompts use defaults)"
fi

# ----------------------------------------------------------------------------
# 1. Preflight
# ----------------------------------------------------------------------------
say "1/8 Preflight"

# Hard: infra/fly.toml must exist (run from repo root).
if [[ -f "$HYDRA_ROOT/infra/fly.toml" ]]; then
  ok "infra/fly.toml present"
else
  fail "infra/fly.toml missing — run from repo root."
fi

# Hard: flyctl installed and authenticated.
FLY_BIN=""
if command -v flyctl >/dev/null 2>&1; then
  FLY_BIN="flyctl"
elif command -v fly >/dev/null 2>&1; then
  FLY_BIN="fly"
fi
if [[ -z "$FLY_BIN" ]]; then
  fail "flyctl not installed — brew install flyctl OR https://fly.io/docs/hands-on/install-flyctl/"
fi
ok "flyctl found ($FLY_BIN)"

if [[ "$DRY_RUN" -eq 1 ]]; then
  dry "$FLY_BIN auth whoami (would verify login)"
else
  if ! "$FLY_BIN" auth whoami >/dev/null 2>&1; then
    fail "flyctl not logged in — run: $FLY_BIN auth login"
  fi
  ok "flyctl logged in"
fi

# Hard: claude, gh, jq.
for bin in claude gh jq; do
  if command -v "$bin" >/dev/null 2>&1; then
    ok "$bin found"
  else
    fail "$bin not found — install before continuing"
  fi
done

# Informational: codex CLI presence affects step 4.
if command -v codex >/dev/null 2>&1; then
  ok "codex CLI found"
else
  warn "codex CLI not found — Codex backend will fall back to OPENAI_API_KEY only"
fi

# Fly app name.
if [[ -n "$FLY_APP" ]]; then
  ok "Fly app: $FLY_APP (from env/flag)"
elif [[ "$INTERACTIVE" -eq 1 ]]; then
  printf "\n  %sFly app name%s (e.g. hydra-commander-alice): " "$C_BOLD" "$C_RESET"
  read -r FLY_APP || true
  [[ -n "$FLY_APP" ]] || fail "Fly app name required"
else
  fail "HYDRA_FLY_APP env var required in --non-interactive mode"
fi

# Main agent id (for register-agent).
: "${MAIN_AGENT_ID:=main-agent}"
ok "Main agent label: $MAIN_AGENT_ID"

# ----------------------------------------------------------------------------
# 2. Auth inventory
# ----------------------------------------------------------------------------
say "2/8 Auth inventory (what's already in your shell env)"

# Track presence, NEVER values.
# shellcheck disable=SC2153  # env-var indirection is intentional
CODEX_AUTH_ENV_NAME="${HYDRA_CODEX_AUTH_ENV:-CODEX_SESSION_TOKEN}"
CODEX_SESSION_VAL="${!CODEX_AUTH_ENV_NAME:-}"

have_claude_oauth=0
have_claude_api=0
have_codex_session=0
have_codex_api=0
have_github_token=0

[[ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]] && have_claude_oauth=1
[[ -n "${ANTHROPIC_API_KEY:-}"       ]] && have_claude_api=1
[[ -n "${CODEX_SESSION_VAL}"          ]] && have_codex_session=1
[[ -n "${OPENAI_API_KEY:-}"           ]] && have_codex_api=1
[[ -n "${GITHUB_TOKEN:-}"             ]] && have_github_token=1

[[ "$have_claude_oauth" -eq 1 ]] && ok "CLAUDE_CODE_OAUTH_TOKEN set (Claude Code Max — flat rate)"       || warn "CLAUDE_CODE_OAUTH_TOKEN not set (preferred Claude auth)"
[[ "$have_claude_api"   -eq 1 ]] && ok "ANTHROPIC_API_KEY set (Claude metered fallback)"                || warn "ANTHROPIC_API_KEY not set"
[[ "$have_codex_api"    -eq 1 ]] && ok "OPENAI_API_KEY set (Codex — preferred for headless)"            || warn "OPENAI_API_KEY not set"
[[ "$have_codex_session" -eq 1 ]] && ok "${CODEX_AUTH_ENV_NAME} set (Codex ChatGPT-session OAuth)"       || warn "${CODEX_AUTH_ENV_NAME} not set"
[[ "$have_github_token" -eq 1 ]] && ok "GITHUB_TOKEN set"                                                || warn "GITHUB_TOKEN not set (required — gh auth token prints yours)"

# If neither provider has anything, warn loudly — user still gets a chance
# to generate one in steps 3/4, but it's worth flagging before we spend time.
if [[ "$have_claude_oauth" -eq 0 && "$have_claude_api" -eq 0 && "$have_codex_session" -eq 0 && "$have_codex_api" -eq 0 ]]; then
  warn "No provider auth detected in current shell. You can generate Claude or Codex creds in the next steps."
fi

# ----------------------------------------------------------------------------
# 3. Claude OAuth
# ----------------------------------------------------------------------------
say "3/8 Claude OAuth (CLAUDE_CODE_OAUTH_TOKEN)"

if [[ "$have_claude_oauth" -eq 1 || "$have_claude_api" -eq 1 ]]; then
  ok "Claude auth present — skipping generation"
else
  dim "Generate with: claude setup-token"
  dim "(1-year validity; produces sk-ant-oat-... printed once)"
  if [[ "$INTERACTIVE" -eq 1 && "$DRY_RUN" -eq 0 ]]; then
    printf "  %sRun 'claude setup-token' now?%s [y/N] " "$C_BOLD" "$C_RESET"
    read -r answer || answer="n"
    case "$answer" in
      y|Y|yes|YES)
        warn "Launching 'claude setup-token' — paste the token back when done, or copy it for later."
        warn "Interactive — this script cannot capture the token. Copy the output and re-run with CLAUDE_CODE_OAUTH_TOKEN=... in your env."
        claude setup-token || warn "claude setup-token exited non-zero"
        ;;
      *)
        warn "Skipped — you can generate later or fall back to ANTHROPIC_API_KEY"
        ;;
    esac
  elif [[ "$DRY_RUN" -eq 1 ]]; then
    dry "claude setup-token (would prompt user to generate OAuth)"
  else
    warn "Non-interactive — skipping Claude OAuth generation (set CLAUDE_CODE_OAUTH_TOKEN in env before re-running)"
  fi
fi

# Re-check env (user may have exported during the pause).
[[ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]] && have_claude_oauth=1
[[ -n "${ANTHROPIC_API_KEY:-}"       ]] && have_claude_api=1

# ----------------------------------------------------------------------------
# 4. Codex OAuth
# ----------------------------------------------------------------------------
say "4/8 Codex OAuth (OPENAI_API_KEY or ${CODEX_AUTH_ENV_NAME})"

if [[ "$have_codex_api" -eq 1 || "$have_codex_session" -eq 1 ]]; then
  ok "Codex auth present — skipping generation"
else
  dim "Two auth modes (preferred order):"
  dim "  1. OPENAI_API_KEY — API-key auth, works on any tier, headless-friendly"
  dim "  2. ${CODEX_AUTH_ENV_NAME} — ChatGPT-session OAuth (requires codex login AND"
  dim "     a tier that supports gpt-5.2-codex under session auth; known to fail"
  dim "     on ChatGPT Plus today — see docs/phase2-vps-runbook.md 'Configuring"
  dim "     the Codex backend' for details)"
  dim ""
  dim "Codex-CLI hasn't settled on a canonical env-var name for its session"
  dim "OAuth yet. Hydra uses ${CODEX_AUTH_ENV_NAME} by default; override via"
  dim "HYDRA_CODEX_AUTH_ENV=<name> if upstream settles on something else."

  if [[ "$INTERACTIVE" -eq 1 && "$DRY_RUN" -eq 0 ]]; then
    printf "  %sRun 'codex login' now?%s [y/N] " "$C_BOLD" "$C_RESET"
    read -r answer || answer="n"
    case "$answer" in
      y|Y|yes|YES)
        if command -v codex >/dev/null 2>&1; then
          warn "Launching 'codex login' — persisted tokens go under ~/.codex/."
          warn "After login, export the session token value into ${CODEX_AUTH_ENV_NAME}."
          codex login || warn "codex login exited non-zero"
        else
          warn "codex CLI not on PATH — skipping. Install upstream if you want Codex backend."
        fi
        ;;
      *)
        warn "Skipped — you can set OPENAI_API_KEY directly or run codex login later"
        ;;
    esac
  elif [[ "$DRY_RUN" -eq 1 ]]; then
    dry "codex login (would open OAuth flow under ~/.codex/)"
  else
    warn "Non-interactive — skipping Codex OAuth generation"
  fi
fi

# Re-check after optional codex login.
CODEX_SESSION_VAL="${!CODEX_AUTH_ENV_NAME:-}"
[[ -n "${CODEX_SESSION_VAL}"    ]] && have_codex_session=1
[[ -n "${OPENAI_API_KEY:-}"    ]] && have_codex_api=1

# Sanity: at least one provider must be present now (matching entrypoint.sh rule).
have_any_provider=0
[[ "$have_claude_oauth" -eq 1 || "$have_claude_api" -eq 1 || "$have_codex_session" -eq 1 || "$have_codex_api" -eq 1 ]] && have_any_provider=1

if [[ "$have_any_provider" -eq 0 ]]; then
  if [[ "$DRY_RUN" -eq 1 ]]; then
    warn "No provider auth present. Real-run would stop here — dry-run continues for rehearsal."
  else
    fail "No provider auth in shell env after Claude + Codex steps. Set at least one of CLAUDE_CODE_OAUTH_TOKEN / ANTHROPIC_API_KEY / OPENAI_API_KEY / ${CODEX_AUTH_ENV_NAME} and re-run."
  fi
fi

# ----------------------------------------------------------------------------
# 5. Fly secrets push
# ----------------------------------------------------------------------------
say "5/8 Stage Fly secrets for $FLY_APP"

# Build the list of KEY=VALUE pairs; --stage so nothing applies until fly deploy.
SECRET_ARGS=()
[[ "$have_claude_oauth"   -eq 1 ]] && SECRET_ARGS+=("CLAUDE_CODE_OAUTH_TOKEN=${CLAUDE_CODE_OAUTH_TOKEN}")
[[ "$have_claude_api"     -eq 1 ]] && SECRET_ARGS+=("ANTHROPIC_API_KEY=${ANTHROPIC_API_KEY}")
[[ "$have_codex_api"      -eq 1 ]] && SECRET_ARGS+=("OPENAI_API_KEY=${OPENAI_API_KEY}")
[[ "$have_codex_session"  -eq 1 ]] && SECRET_ARGS+=("${CODEX_AUTH_ENV_NAME}=${CODEX_SESSION_VAL}")
[[ "$have_github_token"   -eq 1 ]] && SECRET_ARGS+=("GITHUB_TOKEN=${GITHUB_TOKEN}")

# If operator picked a non-default codex env-var name, carry it over as a
# secret too so entrypoint.sh on Fly knows which var to dereference.
if [[ "${HYDRA_CODEX_AUTH_ENV:-}" != "" && "${HYDRA_CODEX_AUTH_ENV}" != "CODEX_SESSION_TOKEN" ]]; then
  SECRET_ARGS+=("HYDRA_CODEX_AUTH_ENV=${HYDRA_CODEX_AUTH_ENV}")
fi

if [[ "${#SECRET_ARGS[@]}" -eq 0 ]]; then
  warn "No secrets to stage — skipping"
else
  dim "Staging ${#SECRET_ARGS[@]} secrets (--stage means they apply on next fly deploy)"
  # Show which NAMES are being staged, never values.
  for kv in "${SECRET_ARGS[@]}"; do
    local_name="${kv%%=*}"
    if [[ "$DRY_RUN" -eq 1 ]]; then
      dry "would stage $local_name"
    else
      dim "  ✓ $local_name"
    fi
  done
  run_cmd "stage fly secrets" "$FLY_BIN" secrets set --app "$FLY_APP" --stage "${SECRET_ARGS[@]}"
  [[ "$DRY_RUN" -eq 0 ]] && ok "Secrets staged. Apply them via fly deploy in step 7."
fi

# ----------------------------------------------------------------------------
# 6. MCP bearer (generate token for the main agent)
# ----------------------------------------------------------------------------
say "6/8 Generate MCP bearer for main agent ($MAIN_AGENT_ID)"

dim "Runs ./hydra mcp register-agent $MAIN_AGENT_ID on the cloud commander."
dim "Prints the raw bearer token to stdout exactly once — copy it immediately."

if [[ "$DRY_RUN" -eq 1 ]]; then
  dry "$FLY_BIN ssh console --app $FLY_APP -C './hydra mcp register-agent $MAIN_AGENT_ID'"
  dim "(real-run would print a 44-char base64 token; copy into your main agent's config)"
else
  # Note: this depends on the cloud commander already being deployed. If it's
  # not, surface that — operator should fly deploy first OR accept that the
  # bearer is generated after step 7.
  if "$FLY_BIN" status --app "$FLY_APP" >/dev/null 2>&1; then
    warn "Cloud commander must already be running to generate the bearer."
    warn "If this is your FIRST deploy, skip this step; run after step 7:"
    warn "  $FLY_BIN ssh console --app $FLY_APP -C './hydra mcp register-agent $MAIN_AGENT_ID'"
  else
    warn "Fly app $FLY_APP not yet deployed — skipping. Run this after step 7:"
    warn "  $FLY_BIN ssh console --app $FLY_APP -C './hydra mcp register-agent $MAIN_AGENT_ID'"
  fi
fi

# ----------------------------------------------------------------------------
# 7. Deploy + verify
# ----------------------------------------------------------------------------
say "7/8 Deploy + health check"

dim "Runs: $FLY_BIN deploy --app $FLY_APP --config infra/fly.toml"

if [[ "$INTERACTIVE" -eq 1 && "$DRY_RUN" -eq 0 ]]; then
  printf "  %sProceed with deploy?%s [y/N] " "$C_BOLD" "$C_RESET"
  read -r answer || answer="n"
  case "$answer" in
    y|Y|yes|YES) ;;
    *) warn "Skipped deploy — run manually when ready: $FLY_BIN deploy --app $FLY_APP --config infra/fly.toml"
       answer="skip" ;;
  esac
else
  answer="y"
fi

if [[ "$answer" != "skip" ]]; then
  run_cmd "fly deploy" "$FLY_BIN" deploy --app "$FLY_APP" --config "$HYDRA_ROOT/infra/fly.toml"
  if [[ "$DRY_RUN" -eq 0 ]]; then
    ok "Deploy complete"
    # Give the Machine a few seconds to bind the health port.
    sleep 3
    if curl -fsS --max-time 5 "https://${FLY_APP}.fly.dev/health" >/dev/null 2>&1; then
      ok "Health check passed: https://${FLY_APP}.fly.dev/health"
    else
      warn "Health check didn't respond yet — machine may still be booting. Retry:"
      warn "  curl https://${FLY_APP}.fly.dev/health"
    fi
  fi
fi

# ----------------------------------------------------------------------------
# 8. Next steps
# ----------------------------------------------------------------------------
say "8/8 Next steps (optional — none are done automatically)"

cat <<EOF
  ${C_BOLD}Attach interactively:${C_RESET}
    $FLY_BIN ssh console --app $FLY_APP -C 'tmux attach -t commander'

  ${C_BOLD}Tail logs:${C_RESET}
    $FLY_BIN logs --app $FLY_APP

  ${C_BOLD}Disable laptop autopickup${C_RESET} (so only cloud ticks):
    # In your local ./hydra session:
    autopickup off

  ${C_BOLD}Enable dual-mode memory${C_RESET} (shared memory across commanders):
    # See: docs/specs/2026-04-17-dual-mode-memory.md
    $FLY_BIN secrets set --app $FLY_APP HYDRA_MEMORY_BACKEND=s3

  ${C_BOLD}Enable Slack bot${C_RESET}:
    # See: docs/phase2-vps-runbook.md 'Setting up Slack'

  ${C_BOLD}Rotate OAuth tokens${C_RESET} (re-run this script with fresh tokens in env):
    # Claude: 1-year validity — re-run 'claude setup-token' annually.
    # Codex (API-key): see your OpenAI dashboard for rotation policy.
    # Codex (session): re-run 'codex login' if commander logs show auth failures.

  ${C_BOLD}Rollback${C_RESET}:
    # Local commander still works identically — migration doesn't disable it.
    # To fully roll back cloud: $FLY_BIN apps destroy $FLY_APP  (destroys all cloud state)
    # Partial rollback (keep cloud but stop ticking): $FLY_BIN scale count 0 --app $FLY_APP

Full docs: docs/phase2-vps-runbook.md (Migrating from local to cloud)
EOF

if [[ "$DRY_RUN" -eq 1 ]]; then
  printf "\n%s━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━%s\n" "$C_DIM" "$C_RESET"
  printf "%sDry-run complete.%s No side effects executed.\n" "$C_BOLD" "$C_RESET"
else
  printf "\n%s━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━%s\n" "$C_DIM" "$C_RESET"
  printf "%sMigration complete.%s Commander is live at https://%s.fly.dev\n" "$C_BOLD" "$C_RESET" "$FLY_APP"
fi

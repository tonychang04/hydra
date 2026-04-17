#!/usr/bin/env bash
#
# deploy-vps.sh — operator-facing one-command Fly.io deploy for Hydra Phase 2.
#
# What it does:
#   1. Prompts for fly app name, region, and auth (CLAUDE_CODE_OAUTH_TOKEN
#      preferred, ANTHROPIC_API_KEY fallback), plus GITHUB_TOKEN.
#   2. Runs `fly launch --copy-config --no-deploy` pointed at infra/fly.toml.
#   3. Sets those values via `fly secrets set`.
#   4. Creates the persistent volume `hydra_data` (1GB).
#   5. Runs `fly deploy`.
#   6. Prints the attach / health / logs commands.
#
# This is a first-run script. After initial deploy, `fly deploy` from the repo
# root picks up framework updates. See docs/phase2-vps-runbook.md.
#
# NOTE: Webhook receiver (#40/#41) and Slack bot (#42) are separate tickets.
# This script does not configure them. After those ship, a `fly secrets set`
# step for HYDRA_WEBHOOK_SECRET / SLACK_BOT_TOKEN will land here.

set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/deploy-vps.sh [--non-interactive] [--help]

One-command Fly.io deploy for Hydra commander Phase 2.

Options:
  --non-interactive   Read all inputs from env vars. Fail if any are missing.
  -h, --help          Show this help.

Environment (for --non-interactive, or to pre-answer prompts):
  HYDRA_FLY_APP                 Fly.io app name (e.g. hydra-commander-you).
  HYDRA_FLY_REGION              Fly region (e.g. iad, sjc, fra, nrt).
  HYDRA_FLY_VOLUME_SIZE_GB      Volume size in GB. Default: 1.
  CLAUDE_CODE_OAUTH_TOKEN       Preferred auth (uses your Max subscription).
  ANTHROPIC_API_KEY             Fallback auth (metered API).
  GITHUB_TOKEN                  Required. gh token with repo + workflow scope.

Prereqs:
  flyctl installed + `fly auth login` done.
  Repo-root invocation (this script expects ./infra/fly.toml).

Examples:
  # Interactive (recommended):
  scripts/deploy-vps.sh

  # Non-interactive (CI / scripted):
  HYDRA_FLY_APP=hydra-alice HYDRA_FLY_REGION=iad \
    CLAUDE_CODE_OAUTH_TOKEN=... GITHUB_TOKEN=... \
    scripts/deploy-vps.sh --non-interactive
EOF
}

INTERACTIVE=1
for arg in "$@"; do
  case "$arg" in
    -h|--help) usage; exit 0 ;;
    --non-interactive) INTERACTIVE=0 ;;
    *) printf 'Unknown arg: %s\n\n' "$arg" >&2; usage; exit 2 ;;
  esac
done

say()  { printf "\n\033[1m▸ %s\033[0m\n" "$*"; }
ok()   { printf "\033[32m✓ %s\033[0m\n" "$*"; }
warn() { printf "\033[33m⚠ %s\033[0m\n" "$*"; }
fail() { printf "\033[31m✗ %s\033[0m\n" "$*" >&2; exit 1; }

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FLY_TOML="${REPO_ROOT}/infra/fly.toml"
DOCKERFILE="${REPO_ROOT}/infra/Dockerfile"

[[ -f "${FLY_TOML}" ]]    || fail "infra/fly.toml not found — run from the hydra repo root."
[[ -f "${DOCKERFILE}" ]]  || fail "infra/Dockerfile not found — run from the hydra repo root."
command -v fly >/dev/null || fail "flyctl not installed. https://fly.io/docs/hands-on/install-flyctl/"
fly auth whoami >/dev/null 2>&1 || fail "Not logged in to Fly. Run: fly auth login"

prompt() {
  local var_name="$1" description="$2" default_value="${3:-}" current
  current="${!var_name:-}"
  if [[ -n "${current}" ]]; then
    ok "${var_name}=${current:0:4}*** (from env)"
    return 0
  fi
  if [[ "${INTERACTIVE}" -eq 0 ]]; then
    fail "${var_name} is required in --non-interactive mode (${description})"
  fi
  local reply
  if [[ -n "${default_value}" ]]; then
    printf "  %s [%s]: " "${description}" "${default_value}"
  else
    printf "  %s: " "${description}"
  fi
  IFS= read -r reply || true
  if [[ -z "${reply}" && -n "${default_value}" ]]; then
    reply="${default_value}"
  fi
  [[ -n "${reply}" ]] || fail "${var_name} is required"
  printf -v "${var_name}" '%s' "${reply}"
  export "${var_name?}"
}

prompt_secret() {
  local var_name="$1" description="$2" current
  current="${!var_name:-}"
  if [[ -n "${current}" ]]; then
    ok "${var_name}=*** (from env)"
    return 0
  fi
  if [[ "${INTERACTIVE}" -eq 0 ]]; then
    return 1   # Caller handles the optional-secret case.
  fi
  local reply
  printf "  %s (hidden): " "${description}"
  IFS= read -rs reply || true
  printf "\n"
  if [[ -z "${reply}" ]]; then
    return 1
  fi
  printf -v "${var_name}" '%s' "${reply}"
  export "${var_name?}"
  return 0
}

# ---------- 1. Prompt for inputs ----------
say "Hydra Phase 2 — Fly.io deploy"

prompt HYDRA_FLY_APP         "Fly.io app name"  "hydra-commander"
prompt HYDRA_FLY_REGION      "Fly.io region (iad, sjc, fra, nrt, ...)" "iad"
prompt HYDRA_FLY_VOLUME_SIZE_GB "Volume size GB" "1"

say "Auth — Claude Code OAuth token is preferred (uses your Max subscription)."
say "Generate one on a host where you're already logged in to Claude Code: \`claude setup-token\`"

HAVE_OAUTH=0
HAVE_API=0
if prompt_secret CLAUDE_CODE_OAUTH_TOKEN "CLAUDE_CODE_OAUTH_TOKEN (leave blank to use ANTHROPIC_API_KEY)"; then
  HAVE_OAUTH=1
else
  warn "No OAuth token provided — falling back to ANTHROPIC_API_KEY (metered)."
  if prompt_secret ANTHROPIC_API_KEY "ANTHROPIC_API_KEY"; then
    HAVE_API=1
  fi
fi

[[ "${HAVE_OAUTH}" -eq 1 || "${HAVE_API}" -eq 1 ]] \
  || fail "Need either CLAUDE_CODE_OAUTH_TOKEN or ANTHROPIC_API_KEY."

prompt_secret GITHUB_TOKEN "GITHUB_TOKEN (gh token with repo + workflow scope)" \
  || fail "GITHUB_TOKEN is required."

# ---------- 2. fly launch --copy-config ----------
say "Launching Fly app: ${HYDRA_FLY_APP} (region: ${HYDRA_FLY_REGION})"

# --copy-config: use the existing fly.toml verbatim.
# --no-deploy:   we want to set secrets + create the volume BEFORE first deploy,
#                so the first machine boots with auth already in env.
# --name:        override the placeholder `hydra-commander` in fly.toml.
fly launch \
  --config "${FLY_TOML}" \
  --dockerfile "${DOCKERFILE}" \
  --copy-config \
  --no-deploy \
  --name "${HYDRA_FLY_APP}" \
  --region "${HYDRA_FLY_REGION}" \
  --yes

ok "Fly app created."

# ---------- 3. fly secrets set ----------
say "Setting secrets (never written to disk by this script)"

SECRETS=()
if [[ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]]; then
  SECRETS+=("CLAUDE_CODE_OAUTH_TOKEN=${CLAUDE_CODE_OAUTH_TOKEN}")
fi
if [[ -n "${ANTHROPIC_API_KEY:-}" ]]; then
  SECRETS+=("ANTHROPIC_API_KEY=${ANTHROPIC_API_KEY}")
fi
SECRETS+=("GITHUB_TOKEN=${GITHUB_TOKEN}")

fly secrets set --app "${HYDRA_FLY_APP}" --stage "${SECRETS[@]}"
ok "Secrets staged. They'll apply on the next deploy."

# ---------- 4. fly volumes create ----------
say "Creating persistent volume hydra_data (${HYDRA_FLY_VOLUME_SIZE_GB}GB) in ${HYDRA_FLY_REGION}"

# If the volume already exists (re-run of this script), don't double-create.
if fly volumes list --app "${HYDRA_FLY_APP}" 2>/dev/null | grep -q 'hydra_data'; then
  warn "Volume hydra_data already exists — skipping create."
else
  fly volumes create hydra_data \
    --app "${HYDRA_FLY_APP}" \
    --region "${HYDRA_FLY_REGION}" \
    --size "${HYDRA_FLY_VOLUME_SIZE_GB}" \
    --yes
  ok "Volume created."
fi

# ---------- 5. fly deploy ----------
say "Deploying…"
fly deploy --app "${HYDRA_FLY_APP}" --config "${FLY_TOML}"
ok "Deploy complete."

# ---------- 6. Next steps ----------
APP_URL="https://${HYDRA_FLY_APP}.fly.dev"

cat <<EOF

$(printf "\033[1m✅ Hydra commander is live on Fly.io\033[0m")

  Health check:
    curl ${APP_URL}/health

  Attach to the commander tmux session:
    fly ssh console --app ${HYDRA_FLY_APP} -C 'tmux attach -t commander'

  Tail logs:
    fly logs --app ${HYDRA_FLY_APP}

  Roll back to the previous release:
    fly releases --app ${HYDRA_FLY_APP}
    fly deploy --app ${HYDRA_FLY_APP} --image-label <previous-label>

Next (follow-up tickets — not part of this deploy):
  - Webhook receiver: #40 (GitHub) / #41 (Linear). When it lands:
      fly secrets set --app ${HYDRA_FLY_APP} HYDRA_WEBHOOK_SECRET=...
  - Slack bot:        #42. Will add SLACK_BOT_TOKEN + SLACK_SIGNING_SECRET.

Security: all secrets live in \`fly secrets\`. Nothing sensitive is committed
to the repo. The OAuth token (if used) is 1-year-valid — rotate by re-running
this script with a fresh token.
EOF

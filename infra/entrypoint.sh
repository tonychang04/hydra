#!/usr/bin/env bash
#
# entrypoint.sh — container PID 1 for Hydra commander on a VPS (Fly.io or
# bare Debian). Runs as the `hydra` user (UID 1000), cwd /hydra.
#
# Responsibilities:
#   1. Verify required env (auth token, GITHUB_TOKEN).
#   2. Rewire /hydra/{state,memory,logs} so they live on the mounted volume
#      at /hydra/data/... — lets us redeploy the image without losing state.
#   3. Bootstrap state/repos.json via ./setup.sh in non-interactive mode if the
#      volume is fresh. The operator customizes by re-running setup via
#      `fly ssh console`, or by `fly secrets set` for HYDRA_* env vars.
#   4. Start a tiny python3 http.server on :8080 serving /health (for Fly's
#      [[http_service]] probe).
#   5. Start the Hydra MCP server on :8765 serving the agent-only interface
#      (spec: docs/specs/2026-04-17-mcp-server-binary.md, ticket #72). Gated
#      by HYDRA_MCP_ENABLED (default "1") and state/connectors/mcp.json being
#      present with an authorized_agents[] entry. If either check fails, the
#      MCP server is NOT launched and the container proceeds — the MCP surface
#      is additive, not required.
#   6. Launch `claude` under `tmux` so the operator can `tmux attach` later.
#   7. Tail the commander log so this process stays PID 1 and `fly logs` sees
#      everything on stdout.
#
# This script is deliberately simple — webhook handler, Slack bot, and
# end-to-end test live in their own follow-up tickets (#40/#41/#42).

set -euo pipefail

usage() {
  cat <<'EOF'
Usage: entrypoint.sh

Container entrypoint for the Hydra commander on a VPS. Not intended to be run
interactively — Docker / systemd / Fly.io invokes it as PID 1.

Required env (at least ONE provider — Claude OR Codex):
  Claude provider (pick one):
    CLAUDE_CODE_OAUTH_TOKEN 1-year OAuth token (preferred — uses your Max
                            subscription, flat-rate billing). Generate on a
                            host where you're already logged into Claude
                            Code Max:
                                claude setup-token
                            Then:
                                fly secrets set CLAUDE_CODE_OAUTH_TOKEN=...
    ANTHROPIC_API_KEY       Metered API key (fallback; does NOT use your Max
                            subscription, so this path costs per-token).

  Codex provider (pick one):
    OPENAI_API_KEY          Preferred for Codex on headless deploys. Works
                            with any account tier that has API access.
    $HYDRA_CODEX_AUTH_ENV   ChatGPT-session OAuth token (default env-var name
                            CODEX_SESSION_TOKEN; override via HYDRA_CODEX_AUTH_ENV).

  Commander boots as long as at least one provider is set. Workers that need
  a specific backend (per state/repos.json:preferred_backend) will fail at
  spawn time if that backend's auth is missing — the entrypoint's job is to
  let commander itself come up.

  GITHUB_TOKEN              gh token with repo + workflow scope. Workers use
                            this to open PRs. Required regardless of provider.

Optional env:
  HYDRA_DATA_DIR            Persistent volume mountpoint. Default: /hydra/data
  HYDRA_HEALTH_PORT         /health port. Default: 8080
  HYDRA_TMUX_SESSION        tmux session name. Default: commander
  HYDRA_SKIP_SETUP          If set to "1", skip the automatic ./setup.sh
                            bootstrap even when state/repos.json is missing.
  HYDRA_CODEX_AUTH_ENV      Name of the env var that carries Codex's ChatGPT-
                            session OAuth. Default: CODEX_SESSION_TOKEN.
                            Configurable because upstream Codex-CLI hasn't
                            settled on a canonical env-var name yet.
EOF
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac

log()  { printf '[entrypoint %s] %s\n' "$(date -u +%FT%TZ)" "$*"; }
fail() { printf '[entrypoint %s] ERROR: %s\n' "$(date -u +%FT%TZ)" "$*" >&2; exit 1; }

HYDRA_ROOT="${HYDRA_ROOT:-/hydra}"
HYDRA_DATA_DIR="${HYDRA_DATA_DIR:-/hydra/data}"
HYDRA_HEALTH_PORT="${HYDRA_HEALTH_PORT:-8080}"
HYDRA_TMUX_SESSION="${HYDRA_TMUX_SESSION:-commander}"
HYDRA_MCP_PORT="${HYDRA_MCP_PORT:-8765}"
HYDRA_MCP_BIND="${HYDRA_MCP_BIND:-0.0.0.0}"
HYDRA_MCP_ENABLED="${HYDRA_MCP_ENABLED:-1}"

log "Hydra commander entrypoint starting (root=${HYDRA_ROOT}, data=${HYDRA_DATA_DIR})"

# ---------- 1. Env verification ----------
# Dual-provider acceptance: commander boots as long as at least ONE of
# {Claude, Codex} has usable auth. Workers route to their preferred backend
# per state/repos.json:preferred_backend (spec: docs/specs/2026-04-17-
# codex-worker-backend.md). A Codex-only deploy is valid; a Claude-only deploy
# is today's default. Spec: docs/specs/2026-04-17-cloud-default-oauth.md (#106).
#
# Detection rules:
#   - Claude provider present if CLAUDE_CODE_OAUTH_TOKEN or ANTHROPIC_API_KEY is set.
#   - Codex provider present if OPENAI_API_KEY or ${!HYDRA_CODEX_AUTH_ENV} is set.
#     (HYDRA_CODEX_AUTH_ENV defaults to CODEX_SESSION_TOKEN — the env-var name
#     upstream Codex-CLI will likely settle on, but configurable so operators
#     can track upstream without a Hydra release.)
CODEX_AUTH_ENV_NAME="${HYDRA_CODEX_AUTH_ENV:-CODEX_SESSION_TOKEN}"
# Bash ${!VAR} indirection: dereference the env var whose name is in
# CODEX_AUTH_ENV_NAME. Quote-safe because we only read the value, never log it.
CODEX_SESSION_VAL="${!CODEX_AUTH_ENV_NAME:-}"

have_claude=0
have_codex=0
[[ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" || -n "${ANTHROPIC_API_KEY:-}" ]] && have_claude=1
[[ -n "${OPENAI_API_KEY:-}" || -n "${CODEX_SESSION_VAL}" ]] && have_codex=1

if [[ "${have_claude}" -eq 0 && "${have_codex}" -eq 0 ]]; then
  fail "No provider auth set. Set at least one of: CLAUDE_CODE_OAUTH_TOKEN / ANTHROPIC_API_KEY (Claude) or OPENAI_API_KEY / ${CODEX_AUTH_ENV_NAME} (Codex). Use 'fly secrets set' on Fly, or export in your shell for local runs."
fi

# Report what's present — never log the actual values.
if [[ "${have_claude}" -eq 1 && "${have_codex}" -eq 1 ]]; then
  log "Auth: Claude + Codex providers both present — per-repo routing honored (spec: docs/specs/2026-04-17-codex-worker-backend.md)"
elif [[ "${have_claude}" -eq 1 ]]; then
  if [[ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]]; then
    log "Auth: CLAUDE_CODE_OAUTH_TOKEN (Claude Code Max subscription — flat rate)"
  else
    log "Auth: ANTHROPIC_API_KEY (metered API — no Max subscription savings)"
  fi
else
  # Codex-only deploy: every ticket will route to worker-codex-implementation.
  # Workers on repos without preferred_backend=codex will fail at spawn time
  # with a Claude-auth-missing error; commander itself still boots cleanly.
  log "Auth: Codex provider only (no Claude auth) — tickets on repos without preferred_backend=codex will fail at spawn time"
fi

if [[ -z "${GITHUB_TOKEN:-}" ]]; then
  fail "GITHUB_TOKEN is not set. Workers need it to read issues and open PRs."
fi
log "GITHUB_TOKEN present"

# ---------- 2. Persistent volume rewiring ----------
# We want state/memory/logs to live on the Fly volume (mounted at
# /hydra/data) so redeploys don't wipe them. Strategy: if /hydra/<dir> is a
# regular directory on first boot, seed its contents into the volume, then
# replace it with a symlink into the volume.
mkdir -p "${HYDRA_DATA_DIR}"

rewire_to_volume() {
  local name="$1"
  local src="${HYDRA_ROOT}/${name}"
  local dst="${HYDRA_DATA_DIR}/${name}"

  mkdir -p "${dst}"

  # If the in-image path is already a symlink, assume prior boot handled it.
  if [[ -L "${src}" ]]; then
    log "rewire: ${name} already symlinked -> $(readlink "${src}")"
    return 0
  fi

  # If it's a populated directory in the image and the volume is empty, seed.
  if [[ -d "${src}" ]]; then
    # Copy only if volume target is empty — never stomp operator state.
    if [[ -z "$(ls -A "${dst}" 2>/dev/null || true)" ]]; then
      log "rewire: seeding ${name} into volume from image defaults"
      cp -a "${src}/." "${dst}/" 2>/dev/null || true
    fi
    rm -rf "${src}"
  fi

  ln -sfn "${dst}" "${src}"
  log "rewire: ${name} -> ${dst}"
}

rewire_to_volume state
rewire_to_volume memory
rewire_to_volume logs

# ---------- 2b. Dual-mode memory: pull from S3 at boot ----------
# If the operator has HYDRA_MEMORY_BACKEND=s3 or s3-strict, pull the memory
# dir from S3 onto the (just-rewired) volume so this commander boots with
# whatever the laptop commander most recently pushed. This is the "shared
# memory across commanders" half of dual-mode memory.
#
# - s3          → warn on failure, continue (fail-soft; volume copy is
#                 still authoritative for this session)
# - s3-strict   → fail the boot (cloud commander must never run on stale
#                 memory; orchestrator will restart + alert)
#
# Spec: docs/specs/2026-04-17-dual-mode-memory.md (ticket #103)
case "${HYDRA_MEMORY_BACKEND:-local}" in
  s3|s3-strict)
    if [[ "${HYDRA_DRY_RUN:-0}" == "1" ]]; then
      log "DRY RUN: would pull memory from S3 (backend=${HYDRA_MEMORY_BACKEND})"
    elif [[ -x "${HYDRA_ROOT}/scripts/hydra-memory-sync.sh" ]]; then
      log "dual-mode memory: pulling memory from S3 (backend=${HYDRA_MEMORY_BACKEND})"
      if ! (cd "${HYDRA_ROOT}" && ./scripts/hydra-memory-sync.sh --pull) \
              >>"${HYDRA_ROOT}/logs/memory-sync-boot.log" 2>&1; then
        if [[ "${HYDRA_MEMORY_BACKEND}" == "s3-strict" ]]; then
          fail "memory pull failed and backend=s3-strict; refusing to boot (see logs/memory-sync-boot.log)"
        fi
        log "memory pull FAILED — continuing with volume copy (backend=s3, fail-soft)"
      else
        log "memory pull OK"
      fi
    else
      log "dual-mode memory: scripts/hydra-memory-sync.sh missing or not executable; skipping pull"
    fi
    ;;
  local|"")
    : # default — no dual-mode action
    ;;
  *)
    log "dual-mode memory: unknown HYDRA_MEMORY_BACKEND='${HYDRA_MEMORY_BACKEND}' (expected: local|s3|s3-strict) — skipping"
    ;;
esac

# ---------- 3. Optional non-interactive setup ----------
if [[ "${HYDRA_SKIP_SETUP:-0}" != "1" ]]; then
  if [[ ! -f "${HYDRA_ROOT}/state/repos.json" ]]; then
    log "state/repos.json missing — seeding from example (operator: edit via 'fly ssh console' to enable repos)"
    if [[ -f "${HYDRA_ROOT}/state/repos.example.json" ]]; then
      cp "${HYDRA_ROOT}/state/repos.example.json" "${HYDRA_ROOT}/state/repos.json"
    else
      # Safety net: empty but valid repos.json so commander boots.
      printf '{"repos": []}\n' > "${HYDRA_ROOT}/state/repos.json"
    fi
  else
    log "state/repos.json present — skipping bootstrap"
  fi
else
  log "HYDRA_SKIP_SETUP=1 — skipping setup bootstrap"
fi

# ---------- 4. /health server ----------
HEALTH_LOG="${HYDRA_ROOT}/logs/health.log"
: > "${HEALTH_LOG}" || true

log "Starting /health server on :${HYDRA_HEALTH_PORT}"

# Tiny inline http.server — returns 200 + small JSON on /health, 404 elsewhere.
# Kept inline to avoid shipping a separate .py file; this process is supervised
# via wait() below so if it dies the container exits and the platform restarts.
python3 -c "
import sys, json, time, http.server, socketserver
port = int(sys.argv[1])
start = time.time()

class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == '/health':
            body = json.dumps({'status':'ok','uptime_s':int(time.time()-start)}).encode()
            self.send_response(200)
            self.send_header('Content-Type','application/json')
            self.send_header('Content-Length',str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        else:
            self.send_response(404); self.end_headers()
    def log_message(self, fmt, *args):
        sys.stderr.write('[health %s] %s\n' % (self.log_date_time_string(), fmt % args))

with socketserver.TCPServer(('0.0.0.0', port), H) as srv:
    srv.serve_forever()
" "${HYDRA_HEALTH_PORT}" >"${HEALTH_LOG}" 2>&1 &
HEALTH_PID=$!
log "/health server pid=${HEALTH_PID}"

# ---------- 5. Launch MCP server (agent-only interface) ----------
# Gated: only start if HYDRA_MCP_ENABLED != 0 AND state/connectors/mcp.json
# exists with at least one authorized_agents[] entry. Missing config is
# explicitly NOT fatal — the MCP surface is additive, and the operator may
# intentionally run without it (legacy direct-drive mode). The server's own
# startup path refuses to bind without authorized agents, so this script
# only probes the config file shape before invoking it (to avoid spamming
# logs with "refusing to serve" messages on every restart of a commander
# that never wanted an MCP surface in the first place).
MCP_LOG="${HYDRA_ROOT}/logs/mcp.log"
MCP_PID=""
if [[ "${HYDRA_MCP_ENABLED}" == "1" ]]; then
  MCP_CFG="${HYDRA_ROOT}/state/connectors/mcp.json"
  if [[ -f "${MCP_CFG}" ]] && grep -q '"authorized_agents"' "${MCP_CFG}" 2>/dev/null; then
    : > "${MCP_LOG}" || true
    log "Starting MCP server on ${HYDRA_MCP_BIND}:${HYDRA_MCP_PORT} (spec: docs/specs/2026-04-17-mcp-server-binary.md)"
    (cd "${HYDRA_ROOT}" && \
      HYDRA_ROOT="${HYDRA_ROOT}" \
      python3 scripts/hydra-mcp-server.py \
        --transport http \
        --bind "${HYDRA_MCP_BIND}" \
        --port "${HYDRA_MCP_PORT}" \
      ) >"${MCP_LOG}" 2>&1 &
    MCP_PID=$!
    log "MCP server pid=${MCP_PID}"
  else
    log "MCP: state/connectors/mcp.json missing or no authorized_agents — skipping MCP surface"
  fi
else
  log "HYDRA_MCP_ENABLED=0 — skipping MCP server launch (operator opt-out)"
fi

# ---------- 5b. Clone all enabled repos on boot ----------
# Cloud commander needs every enabled repo cloned to its cloud_local_path
# BEFORE the first worker-implementation spawns, otherwise `git worktree add`
# fails and the ticket bounces. scripts/ensure-repo-cloned.sh is idempotent:
# first boot clones, subsequent boots re-fetch + reset. Failures for a single
# repo are logged and skipped — we never let one broken repo brick the whole
# commander (other repos may still be pickable).
#
# Spec: docs/specs/2026-04-17-entrypoint-integration.md (#80)
REPOS_JSON_PATH="${HYDRA_ROOT}/state/repos.json"
if [[ -f "${REPOS_JSON_PATH}" ]]; then
  log "Cloning enabled repos from state/repos.json"
  enabled_slugs="$(jq -r '.repos[]? | select(.enabled == true) | "\(.owner)/\(.name)"' "${REPOS_JSON_PATH}" 2>/dev/null || true)"
  if [[ -z "${enabled_slugs}" ]]; then
    log "No enabled repos — skipping clone loop"
  else
    while IFS= read -r slug; do
      [[ -z "${slug}" ]] && continue
      if [[ "${HYDRA_DRY_RUN:-0}" == "1" ]]; then
        log "DRY RUN: would clone ${slug}"
      else
        log "ensure-repo-cloned: ${slug}"
        if ! "${HYDRA_ROOT}/scripts/ensure-repo-cloned.sh" "${slug}" >>"${HYDRA_ROOT}/logs/ensure-repo-cloned.log" 2>&1; then
          log "ensure-repo-cloned: ${slug} FAILED — continuing (worker will retry on spawn)"
        fi
      fi
    done <<<"${enabled_slugs}"
  fi
else
  log "state/repos.json absent — skipping repo-clone loop"
fi

# ---------- 5c. Launch Slack bot if configured ----------
# bin/hydra-slack-bot speaks to Slack via socket mode (outbound WebSocket)
# so no new port / ingress / secret exposure is required. The bot has its
# own refuse-to-start gate: missing config exits 1, enabled=false exits 0,
# missing token env-vars exit 1. So a misconfigured slack.json at worst
# spawns a short-lived process; commander keeps running either way.
#
# Spec: docs/specs/2026-04-17-entrypoint-integration.md (#80)
SLACK_CFG="${HYDRA_ROOT}/state/connectors/slack.json"
SLACK_PID=""
if [[ -f "${SLACK_CFG}" ]] && [[ "$(jq -r .enabled "${SLACK_CFG}" 2>/dev/null)" == "true" ]]; then
  if [[ "${HYDRA_DRY_RUN:-0}" == "1" ]]; then
    log "DRY RUN: would launch hydra-slack-bot"
  else
    log "Starting hydra-slack-bot (socket mode, outbound only)"
    ( cd "${HYDRA_ROOT}" && ./bin/hydra-slack-bot >>"${HYDRA_ROOT}/logs/slack-bot.log" 2>&1 ) &
    SLACK_PID=$!
    log "hydra-slack-bot pid=${SLACK_PID}"
  fi
else
  log "Slack bot: state/connectors/slack.json missing or enabled=false — skipping"
fi

# ---------- 5d. Dry-run short-circuit ----------
# HYDRA_DRY_RUN=1 is for self-tests and operator pre-deploy sanity. We've
# already logged the repo-clone and slack-bot decisions above; tmux +
# claude launch are side-effectful enough that running them in a test
# context isn't useful. Exit 0 tears down the health-server process group.
if [[ "${HYDRA_DRY_RUN:-0}" == "1" ]]; then
  log "HYDRA_DRY_RUN=1 — exiting after stanza 5c (pre-tmux) for self-test"
  exit 0
fi

# ---------- 6. Launch claude under tmux ----------
COMMANDER_LOG="${HYDRA_ROOT}/logs/commander.log"
: > "${COMMANDER_LOG}" || true

# Pick the invocation. Claude Code reads CLAUDE_CODE_OAUTH_TOKEN /
# ANTHROPIC_API_KEY from env automatically.
CLAUDE_BIN="$(command -v claude || true)"
if [[ -z "${CLAUDE_BIN}" ]]; then
  fail "claude CLI not found on PATH (expected installed in the image)"
fi

log "Starting claude under tmux session '${HYDRA_TMUX_SESSION}' (log: ${COMMANDER_LOG})"
tmux new-session -d -s "${HYDRA_TMUX_SESSION}" \
  "cd ${HYDRA_ROOT} && ${CLAUDE_BIN} 2>&1 | tee -a ${COMMANDER_LOG}"

# Give tmux a beat to actually start the pane before we tail.
sleep 1

if ! tmux has-session -t "${HYDRA_TMUX_SESSION}" 2>/dev/null; then
  fail "tmux session '${HYDRA_TMUX_SESSION}' failed to start — check ${COMMANDER_LOG}"
fi
log "tmux session '${HYDRA_TMUX_SESSION}' live. Attach via: fly ssh console -C 'tmux attach -t ${HYDRA_TMUX_SESSION}'"

# ---------- 7. Keep PID 1 alive + ship logs to stdout ----------
# tail -F tolerates the log being rotated/truncated. The `wait` on the health
# server ensures we exit (and Fly restarts us) if health dies. The MCP server
# is NOT gating — if it crashes, the container keeps running (it's additive,
# not core to Commander's loop). Its pid is tracked so the shutdown trap can
# clean it up politely.
trap '
  log "shutdown signal received"
  tmux kill-session -t '"${HYDRA_TMUX_SESSION}"' 2>/dev/null || true
  [[ -n "${MCP_PID}" ]] && kill "${MCP_PID}" 2>/dev/null || true
  [[ -n "${SLACK_PID}" ]] && kill "${SLACK_PID}" 2>/dev/null || true
  kill '"${HEALTH_PID}"' 2>/dev/null || true
  exit 0
' TERM INT

# Tail commander, health, and (if running) the MCP server log so `fly logs`
# surfaces every subsystem on the same stdout stream.
if [[ -n "${MCP_PID}" && -f "${MCP_LOG}" ]]; then
  tail -n +1 -F "${COMMANDER_LOG}" "${HEALTH_LOG}" "${MCP_LOG}" &
else
  tail -n +1 -F "${COMMANDER_LOG}" "${HEALTH_LOG}" &
fi
TAIL_PID=$!

# If the health server exits, bail so the platform restarts us. (The MCP
# server is intentionally NOT in this wait set — we don't want a crash in
# the sidecar to kill the core commander loop.)
wait "${HEALTH_PID}" || true
log "health server exited — killing tail + tmux + mcp + slack and shutting down"
kill "${TAIL_PID}" 2>/dev/null || true
[[ -n "${MCP_PID}" ]] && kill "${MCP_PID}" 2>/dev/null || true
[[ -n "${SLACK_PID}" ]] && kill "${SLACK_PID}" 2>/dev/null || true
tmux kill-session -t "${HYDRA_TMUX_SESSION}" 2>/dev/null || true
exit 1

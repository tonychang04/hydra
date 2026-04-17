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
#   5. Launch `claude` under `tmux` so the operator can `tmux attach` later.
#   6. Tail the commander log so this process stays PID 1 and `fly logs` sees
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

Required env:
  CLAUDE_CODE_OAUTH_TOKEN   1-year OAuth token (preferred). Generate on a host
                            where you're already logged into Claude Code Max:
                                claude setup-token
                            Then:
                                fly secrets set CLAUDE_CODE_OAUTH_TOKEN=...
  --- OR ---
  ANTHROPIC_API_KEY         Metered API key (fallback; does NOT use your Max
                            subscription, so this path costs per-token).

  GITHUB_TOKEN              gh token with repo + workflow scope. Workers use
                            this to open PRs.

Optional env:
  HYDRA_DATA_DIR            Persistent volume mountpoint. Default: /hydra/data
  HYDRA_HEALTH_PORT         /health port. Default: 8080
  HYDRA_TMUX_SESSION        tmux session name. Default: commander
  HYDRA_SKIP_SETUP          If set to "1", skip the automatic ./setup.sh
                            bootstrap even when state/repos.json is missing.
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

log "Hydra commander entrypoint starting (root=${HYDRA_ROOT}, data=${HYDRA_DATA_DIR})"

# ---------- 1. Env verification ----------
if [[ -z "${CLAUDE_CODE_OAUTH_TOKEN:-}" && -z "${ANTHROPIC_API_KEY:-}" ]]; then
  fail "Neither CLAUDE_CODE_OAUTH_TOKEN nor ANTHROPIC_API_KEY is set. Set one via 'fly secrets set'."
fi
if [[ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]]; then
  log "Auth: using CLAUDE_CODE_OAUTH_TOKEN (Claude Code Max subscription — flat rate)"
else
  log "Auth: using ANTHROPIC_API_KEY (metered API — no Max subscription savings)"
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

# ---------- 5. Launch claude under tmux ----------
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

# ---------- 6. Keep PID 1 alive + ship logs to stdout ----------
# tail -F tolerates the log being rotated/truncated. The `wait` on the health
# server ensures we exit (and Fly restarts us) if health dies.
trap 'log "shutdown signal received"; tmux kill-session -t '"${HYDRA_TMUX_SESSION}"' 2>/dev/null || true; kill '"${HEALTH_PID}"' 2>/dev/null || true; exit 0' TERM INT

tail -n +1 -F "${COMMANDER_LOG}" "${HEALTH_LOG}" &
TAIL_PID=$!

# If the health server exits, bail so the platform restarts us.
wait "${HEALTH_PID}" || true
log "health server exited — killing tail + tmux and shutting down"
kill "${TAIL_PID}" 2>/dev/null || true
tmux kill-session -t "${HYDRA_TMUX_SESSION}" 2>/dev/null || true
exit 1

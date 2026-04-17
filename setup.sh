#!/usr/bin/env bash
# Hydra setup — run once after cloning. Idempotent; safe to re-run.
set -euo pipefail

HYDRA_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HYDRA_ROOT"

say() { printf "\n\033[1m▸ %s\033[0m\n" "$*"; }
warn() { printf "\033[33m⚠ %s\033[0m\n" "$*"; }
fail() { printf "\033[31m✗ %s\033[0m\n" "$*"; exit 1; }
ok()   { printf "\033[32m✓ %s\033[0m\n" "$*"; }

say "Hydra setup at $HYDRA_ROOT"

# ---------- Prerequisites ----------
say "Checking prerequisites"
command -v claude >/dev/null || fail "Claude Code CLI not found. Install from https://claude.com/claude-code"
ok "claude CLI found"

command -v gh >/dev/null || fail "GitHub CLI not found. brew install gh"
gh auth status >/dev/null 2>&1 || fail "gh not authenticated. Run: gh auth login"
GH_USER=$(gh api user --jq .login)
ok "gh authenticated as $GH_USER"

command -v jq >/dev/null || warn "jq not found — needed for some helper scripts. brew install jq"

# ---------- External memory directory ----------
DEFAULT_EXT_MEM="${HOME}/.hydra/memory"
say "External memory directory (where per-target-repo learnings live; gitignored + outside this repo)"
printf "  Default: %s\n  [Enter to accept, or type a different absolute path]: " "$DEFAULT_EXT_MEM"
read -r EXT_MEM_INPUT
EXT_MEM_DIR="${EXT_MEM_INPUT:-$DEFAULT_EXT_MEM}"
mkdir -p "$EXT_MEM_DIR"
ok "External memory: $EXT_MEM_DIR"

# ---------- Permission profile ----------
if [[ -f .claude/settings.local.json ]]; then
  warn ".claude/settings.local.json already exists — leaving as-is"
else
  say "Creating .claude/settings.local.json from template"
  HOME_DIR_ESC=$(printf '%s' "$HOME" | sed 's:/:\\/:g')
  HYDRA_ROOT_ESC=$(printf '%s' "$HYDRA_ROOT" | sed 's:/:\\/:g')
  sed -e "s/\$COMMANDER_ROOT/$HYDRA_ROOT_ESC/g" \
      -e "s/\$HOME_DIR/$HOME_DIR_ESC/g" \
      .claude/settings.local.json.example > .claude/settings.local.json
  ok "Wrote .claude/settings.local.json (edit to tune allow/deny if needed)"
fi

# ---------- Repos config ----------
if [[ -f state/repos.json ]]; then
  warn "state/repos.json already exists — leaving as-is"
else
  say "Creating state/repos.json from template"
  cp state/repos.example.json state/repos.json
  ok "Wrote state/repos.json — edit this to list your repos (owner, name, local_path, ticket_trigger)"
fi

# ---------- Runtime state files ----------
say "Initializing runtime state files"
for f in state/active.json state/budget-used.json state/memory-citations.json state/autopickup.json; do
  if [[ -f "$f" ]]; then
    ok "$f exists"
  else
    case "$f" in
      */active.json)          echo '{"workers": [], "last_updated": null}' > "$f" ;;
      */budget-used.json)     echo '{"date": null, "tickets_completed_today": 0, "tickets_failed_today": 0, "total_worker_wall_clock_minutes_today": 0, "rate_limit_hits_today": 0, "phase2_spend_usd_today": 0}' > "$f" ;;
      */memory-citations.json) echo '{"_schema": "key = learnings-<repo>.md#<quote>, value = {count, last_cited, tickets, promotion_threshold_reached}", "citations": {}}' > "$f" ;;
      */autopickup.json)      echo '{"enabled": false, "interval_min": 30, "auto_enable_on_session_start": true, "last_run": null, "last_picked_count": 0, "consecutive_rate_limit_hits": 0}' > "$f" ;;
    esac
    ok "Created $f"
  fi
done

# ---------- .env for the launcher ----------
if [[ -f .hydra.env ]]; then
  warn ".hydra.env exists — leaving as-is"
else
  cat > .hydra.env <<EOF
# Hydra environment — sourced by ./hydra launcher.
# Do NOT commit this file (gitignored).
export HYDRA_ROOT="$HYDRA_ROOT"
export HYDRA_EXTERNAL_MEMORY_DIR="$EXT_MEM_DIR"
export COMMANDER_ROOT="$HYDRA_ROOT"
EOF
  ok "Wrote .hydra.env"
fi

# ---------- Launcher ----------
if [[ -f hydra ]]; then
  warn "./hydra launcher exists — leaving as-is"
else
  cat > hydra <<'EOF'
#!/usr/bin/env bash
# Launch the Hydra Commander session. Sources env, sanity-checks, then exec claude.
#
# Usage:
#   ./hydra                  Launch commander. By default, commander's session-start
#                            logic flips autopickup ON (opt-out model) if
#                            state/autopickup.json:auto_enable_on_session_start is true.
#   ./hydra --no-autopickup  Launch with HYDRA_NO_AUTOPICKUP=1 exported so commander
#                            stays idle at session start (no auto-enable). Useful for
#                            debugging, read-only sessions, or "just status please".
#   ./hydra --version        Print the contents of the repo-root VERSION file and exit.
#                            Intended for bug reports ("what version of Hydra are you
#                            running?"). Does NOT exec claude.
#   ./hydra doctor [args]    Run the install sanity-check (scripts/hydra-doctor.sh).
#                            Diagnostic only; does not launch commander.
#
# Non-chat CLI subcommands (spec: docs/specs/2026-04-16-hydra-cli.md, ticket #25).
# These dispatch to scripts/hydra-*.sh helpers WITHOUT launching a Claude session.
# Safe for scripts / cron / SSH / daily-ops muscle memory.
#
#   ./hydra add-repo <owner>/<name> [args]   Interactive wizard: add a repo.
#   ./hydra remove-repo <owner>/<name>       Remove a repo entry.
#   ./hydra list-repos                       Table view of state/repos.json.
#   ./hydra status [--with-tickets] [--json] Read-only Hydra state snapshot.
#   ./hydra ps [--json]                      Per-worker detail from state/active.json.
#   ./hydra pause [--reason <text>]          Toggle PAUSE on.
#   ./hydra resume                           Toggle PAUSE off.
#   ./hydra issue <url-or-owner/repo/num>    Queue a specific issue for next tick.
#   ./hydra activity [--json]                Text-based observability: last 24h
#                                            of log activity + live worker
#                                            snapshot + top memory citations
#                                            (spec: docs/specs/2026-04-17-hydra-activity.md,
#                                            ticket #19).
#
# MCP server subcommand (spec: docs/specs/2026-04-17-mcp-server-binary.md, ticket #72).
# Launches Hydra's agent-only interface. Not a chat session.
#
#   ./hydra mcp serve [--transport http|stdio] [--port N] [--bind ADDR]
#                                              Start the MCP server (blocking).
#   ./hydra mcp register-agent <agent-id> [--rotate]
#                                              Generate a bearer token for an
#                                              MCP client agent, store the
#                                              SHA-256 hash in mcp.json, and
#                                              print the raw token once.
#                                              Spec: docs/specs/2026-04-17-mcp-register-agent.md
#                                              (ticket #84)
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# ---------------------------------------------------------------------------
# Subcommand dispatch — these never launch the Commander Claude session.
# Each helper sources .hydra.env itself; we still source it here so the
# helpers pick up HYDRA_ROOT even if they're invoked without the launcher.
# ---------------------------------------------------------------------------
hydra_exec_helper() {
  local script="$1"; shift
  [[ -x "$script" ]] || {
    echo "✗ $script missing or not executable." >&2
    exit 1
  }
  # shellcheck disable=SC1091
  [[ -f .hydra.env ]] && source .hydra.env
  exec "$script" "$@"
}

case "${1:-}" in
  doctor)       shift; hydra_exec_helper scripts/hydra-doctor.sh "$@" ;;
  add-repo)     shift; hydra_exec_helper scripts/hydra-add-repo.sh "$@" ;;
  remove-repo)  shift; hydra_exec_helper scripts/hydra-remove-repo.sh "$@" ;;
  list-repos)   shift; hydra_exec_helper scripts/hydra-list-repos.sh "$@" ;;
  status)       shift; hydra_exec_helper scripts/hydra-status.sh "$@" ;;
  ps)           shift; hydra_exec_helper scripts/hydra-ps.sh "$@" ;;
  pause)        shift; hydra_exec_helper scripts/hydra-pause.sh "$@" ;;
  resume)       shift; hydra_exec_helper scripts/hydra-resume.sh "$@" ;;
  issue)        shift; hydra_exec_helper scripts/hydra-issue.sh "$@" ;;
  activity)     shift; hydra_exec_helper scripts/hydra-activity.sh "$@" ;;
  mcp)
    shift
    case "${1:-}" in
      serve) shift; hydra_exec_helper scripts/hydra-mcp-serve.sh "$@" ;;
      register-agent) shift; hydra_exec_helper scripts/hydra-mcp-register-agent.sh "$@" ;;
      ""|-h|--help)
        cat <<'MCPUSAGE'
Usage: ./hydra mcp <subcommand> [options]

Subcommands:
  serve            Start the MCP server (agent-only interface).
                   Run `./hydra mcp serve --help` for options.
  register-agent   Generate a bearer token for an MCP client agent,
                   store its SHA-256 hash in state/connectors/mcp.json,
                   and print the raw token once.
                   Run `./hydra mcp register-agent --help` for options.
MCPUSAGE
        exit 0
        ;;
      *)
        echo "✗ Unknown mcp subcommand: $1" >&2
        echo "  Try: ./hydra mcp --help" >&2
        exit 2
        ;;
    esac
    ;;
esac

# --version short-circuits before any env/auth sanity checks so it works on a
# broken / partially-installed tree. Read the VERSION file verbatim (strip
# trailing whitespace); if it's missing, say so explicitly rather than silently
# printing nothing.
for arg in "$@"; do
  case "$arg" in
    --version)
      if [[ -f VERSION ]]; then
        tr -d '[:space:]' <VERSION
        echo
        exit 0
      else
        echo "✗ VERSION file missing at $SCRIPT_DIR/VERSION" >&2
        exit 1
      fi
      ;;
  esac
done

# Parse launcher flags (only --no-autopickup so far). Unknown flags pass through to claude.
# Using ${arr[@]+"${arr[@]}"} idiom for bash 3.2 (macOS default) compatibility with set -u.
HYDRA_NO_AUTOPICKUP_FLAG=""
PASSTHROUGH_ARGS=()
for arg in "$@"; do
  case "$arg" in
    --no-autopickup) HYDRA_NO_AUTOPICKUP_FLAG=1 ;;
    *) PASSTHROUGH_ARGS+=("$arg") ;;
  esac
done

[[ -f .hydra.env ]] || { echo "✗ .hydra.env missing. Run ./setup.sh first." >&2; exit 1; }
# shellcheck disable=SC1091
source .hydra.env
[[ -f .claude/settings.local.json ]] || { echo "✗ .claude/settings.local.json missing. Run ./setup.sh." >&2; exit 1; }
[[ -f state/repos.json ]] || { echo "✗ state/repos.json missing. Run ./setup.sh." >&2; exit 1; }
gh auth status >/dev/null 2>&1 || { echo "✗ gh not authenticated. Run: gh auth login" >&2; exit 1; }

if [[ -n "$HYDRA_NO_AUTOPICKUP_FLAG" ]]; then
  export HYDRA_NO_AUTOPICKUP=1
fi

# --- Dual-mode memory: S3 pull at session start ----------------------------
# If the operator has flipped HYDRA_MEMORY_BACKEND to s3 or s3-strict
# (via .hydra.env or their shell), pull the memory dir from S3 BEFORE
# launching Claude so this session starts with the freshest shared state.
# - s3          → warn on failure, continue (fail-soft)
# - s3-strict   → exit 1 on failure (cloud commander must not boot stale)
# Spec: docs/specs/2026-04-17-dual-mode-memory.md
case "${HYDRA_MEMORY_BACKEND:-local}" in
  s3|s3-strict)
    if [[ -x scripts/hydra-memory-sync.sh ]]; then
      echo "▸ Dual-mode memory: pulling ${HYDRA_MEMORY_BACKEND} memory from S3..."
      if ! scripts/hydra-memory-sync.sh --pull; then
        if [[ "$HYDRA_MEMORY_BACKEND" == "s3-strict" ]]; then
          echo "✗ s3-strict: memory pull failed; refusing to launch" >&2
          exit 1
        fi
        echo "⚠ memory pull failed; continuing with local copy (backend=s3)" >&2
      fi
    fi
    ;;
esac

exec claude ${PASSTHROUGH_ARGS[@]+"${PASSTHROUGH_ARGS[@]}"}
EOF
  chmod +x hydra
  ok "Wrote ./hydra launcher (chmod +x)"
fi

# ---------- Summary ----------
say "Setup complete"
cat <<EOF

Next steps:
  1. Edit state/repos.json — add the repos you want Hydra to poll.
  2. Review .claude/settings.local.json — tune allow/deny if your workflow needs it.
  3. (Optional) claude mcp add linear — if using Linear as a ticket source.
  4. Launch:  ./hydra

File issues in those repos (assign to yourself or label commander-ready),
then in the Hydra chat: pick up N.

External operational memory (per-target-repo learnings): $EXT_MEM_DIR
  → This is deliberately outside the hydra repo. Framework memory stays in ./memory/.

Docs:  README.md (what) · USAGE.md (how) · docs/specs/ (why)
EOF

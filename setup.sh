#!/usr/bin/env bash
# Hydra setup — interactive bootstrap. Idempotent; safe to re-run.
#
# Default mode is interactive: the script auto-detects what's installed,
# prints a color-coded ✓ / ⚠ / ✗ summary, and asks at most one plain-English
# question (memory directory) with a sensible default.
#
# Non-interactive mode (all prompts skipped, all defaults accepted) triggers
# automatically when ANY of:
#   - --non-interactive / --ci flag
#   - stdin is not a TTY (piped, redirected, closed)
#   - HYDRA_NON_INTERACTIVE=1 env var
#   - CI=true env var (GitHub Actions, GitLab, etc.)
#
# The .hydra.env output format is unchanged from previous versions — existing
# installs re-running this script see "already exists — leaving as-is" for
# every artifact, identical to the pre-#102 behavior.
#
# Spec: docs/specs/2026-04-17-interactive-setup.md (ticket #102)

set -euo pipefail

HYDRA_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HYDRA_ROOT"

# ----------------------------------------------------------------------------
# flag parsing
# ----------------------------------------------------------------------------
INTERACTIVE=1

for arg in "$@"; do
  case "$arg" in
    --non-interactive|--ci) INTERACTIVE=0 ;;
    -h|--help)
      cat <<'HELP'
Usage: ./setup.sh [options]

Bootstrap a fresh Hydra install. Idempotent — safe to re-run.

Options:
  --non-interactive   Skip all prompts, use all defaults (alias: --ci).
                      Also auto-enabled when stdin is not a TTY, when
                      HYDRA_NON_INTERACTIVE=1, or when CI=true.
  -h, --help          Show this help.

Environment variables:
  HYDRA_EXTERNAL_MEMORY_DIR  If set, used as the memory directory and the
                             prompt is skipped (interactive or not).
  NO_COLOR=1                 Disable ANSI color output.
  HYDRA_NON_INTERACTIVE=1    Force non-interactive mode.
HELP
      exit 0
      ;;
    *)
      printf '✗ Unknown argument: %s\n  Run ./setup.sh --help for options.\n' "$arg" >&2
      exit 2
      ;;
  esac
done

# Auto-detect non-interactive mode.
if [[ ! -t 0 ]] || [[ "${HYDRA_NON_INTERACTIVE:-}" = "1" ]] || [[ "${CI:-}" = "true" ]]; then
  INTERACTIVE=0
fi

# ----------------------------------------------------------------------------
# color / TTY
# ----------------------------------------------------------------------------
if [[ -t 1 ]] && [[ "${NO_COLOR:-}" != "1" ]]; then
  C_GREEN=$'\033[32m'
  C_YELLOW=$'\033[33m'
  C_RED=$'\033[31m'
  C_BOLD=$'\033[1m'
  C_DIM=$'\033[2m'
  C_RESET=$'\033[0m'
else
  C_GREEN=""
  C_YELLOW=""
  C_RED=""
  C_BOLD=""
  C_DIM=""
  C_RESET=""
fi

say()  { printf "\n%s▸ %s%s\n" "$C_BOLD" "$*" "$C_RESET"; }
ok()   { printf "  %s✓%s %s\n" "$C_GREEN"  "$C_RESET" "$*"; }
warn() { printf "  %s⚠%s %s\n" "$C_YELLOW" "$C_RESET" "$*"; }
fail() { printf "  %s✗%s %s\n" "$C_RED"    "$C_RESET" "$*" >&2; exit 1; }
dim()  { printf "    %s%s%s\n" "$C_DIM" "$*" "$C_RESET"; }

# Run a command with a short timeout so hung daemons never freeze setup.
# Falls back to the plain command if `timeout` isn't on PATH.
timed() {
  local secs="$1"; shift
  if command -v timeout >/dev/null 2>&1; then
    timeout "${secs}s" "$@"
  else
    "$@"
  fi
}

# ----------------------------------------------------------------------------
# banner
# ----------------------------------------------------------------------------
say "Hydra setup at $HYDRA_ROOT"
if [[ "$INTERACTIVE" -eq 0 ]]; then
  dim "(non-interactive mode — all prompts skipped, defaults accepted)"
fi

# ----------------------------------------------------------------------------
# Prereq detection
#   Hard requirements: claude, gh. Missing → red ✗ + exit.
#   Informational: docker, aws, flyctl, jq. Missing → yellow ⚠, setup continues.
# ----------------------------------------------------------------------------
say "Checking what's already installed"

# -- Claude Code CLI (hard) --
if command -v claude >/dev/null 2>&1; then
  CLAUDE_VER="$(timed 3 claude --version 2>/dev/null | head -n1 | tr -d '[:cntrl:]' || true)"
  CLAUDE_VER="${CLAUDE_VER:-installed}"
  ok "Claude Code — $CLAUDE_VER"
else
  fail "Claude Code not installed — install from https://claude.com/claude-code"
fi

# -- GitHub CLI (hard) --
if ! command -v gh >/dev/null 2>&1; then
  fail "GitHub CLI not found — brew install gh (or https://cli.github.com/)"
fi
if ! timed 5 gh auth status >/dev/null 2>&1; then
  fail "GitHub CLI installed but not authenticated — run: gh auth login"
fi
GH_USER="$(timed 5 gh api user --jq .login 2>/dev/null || echo 'unknown')"
ok "GitHub CLI — signed in as $GH_USER"

# -- Docker (informational) --
if command -v docker >/dev/null 2>&1; then
  if timed 3 docker info >/dev/null 2>&1; then
    ok "Docker reachable"
  else
    warn "Docker installed but daemon unreachable — start Docker Desktop to enable cloud-mode worker isolation"
  fi
else
  warn "Docker not found — cloud-mode worker isolation disabled (you can enable later)"
fi

# -- AWS CLI + credentials (informational) --
if command -v aws >/dev/null 2>&1; then
  if timed 5 aws sts get-caller-identity >/dev/null 2>&1; then
    AWS_ACCT="$(timed 5 aws sts get-caller-identity --query Account --output text 2>/dev/null || echo 'unknown')"
    ok "AWS credentials — account $AWS_ACCT"
  else
    warn "AWS CLI found but credentials not set — S3-backed memory disabled (you can enable later)"
  fi
else
  warn "AWS CLI not found — S3-backed memory disabled (you can enable later)"
fi

# -- Fly CLI (informational) --
FLY_VER=""
if command -v flyctl >/dev/null 2>&1; then
  FLY_VER="$(timed 3 flyctl version 2>/dev/null | head -n1 | tr -d '[:cntrl:]' || true)"
elif command -v fly >/dev/null 2>&1; then
  FLY_VER="$(timed 3 fly version 2>/dev/null | head -n1 | tr -d '[:cntrl:]' || true)"
fi
if [[ -n "$FLY_VER" ]]; then
  ok "Fly CLI — $FLY_VER"
else
  warn "Fly CLI not found — cloud deploy disabled (you can enable later)"
fi

# -- jq (informational — some helper scripts need it) --
if command -v jq >/dev/null 2>&1; then
  JQ_VER="$(timed 3 jq --version 2>/dev/null || echo 'installed')"
  ok "jq — $JQ_VER"
else
  warn "jq not found — some helper scripts will fail (brew install jq)"
fi

# ----------------------------------------------------------------------------
# Prompt helper
#   ask_path <question> <default> <varname>
#     - interactive + stdin TTY → read -r with prompt
#     - non-interactive OR env-var set → use default (or env-var value)
#     - empty input → default
#     - tilde and relative paths are normalized to absolute
# ----------------------------------------------------------------------------
ask_path() {
  local question="$1"
  local default="$2"
  local varname="$3"
  local answer=""

  if [[ "$INTERACTIVE" -eq 1 ]]; then
    printf "\n%s%s%s\n" "$C_BOLD" "$question" "$C_RESET"
    printf "  %sDefault:%s %s\n" "$C_DIM" "$C_RESET" "$default"
    # shellcheck disable=SC2162   # -r is set
    # read may return non-zero on EOF — we already guarded via INTERACTIVE but
    # be defensive: `|| true` prevents set -e tripping on a closed FD.
    read -r -p "  [Press Enter to accept, or type a different path]: " answer || answer=""
  fi

  # Empty answer → use default. Tilde-expand + normalize to absolute.
  answer="${answer:-$default}"
  # Tilde expansion (bash `read` doesn't do this).
  answer="${answer/#\~/$HOME}"
  # Normalize to absolute. If the path doesn't yet exist, resolve the parent.
  if [[ "$answer" != /* ]]; then
    warn "That's a relative path — normalizing to absolute."
    answer="$PWD/$answer"
  fi

  printf -v "$varname" '%s' "$answer"
}

# ----------------------------------------------------------------------------
# Memory directory
# ----------------------------------------------------------------------------
DEFAULT_EXT_MEM="${HOME}/.hydra/memory"

if [[ -n "${HYDRA_EXTERNAL_MEMORY_DIR:-}" ]]; then
  EXT_MEM_DIR="$HYDRA_EXTERNAL_MEMORY_DIR"
  say "Memory folder"
  ok "Using HYDRA_EXTERNAL_MEMORY_DIR from env: $EXT_MEM_DIR"
else
  say "Memory folder"
  dim "Hydra learns what works for each of your repos and stores those notes here."
  dim "This lives outside the hydra repo so it persists across upgrades."
  ask_path "Where should Hydra store its memory?" "$DEFAULT_EXT_MEM" EXT_MEM_DIR
fi

# Create the dir; surface a friendly error if the user pointed at a file.
if [[ -e "$EXT_MEM_DIR" ]] && [[ ! -d "$EXT_MEM_DIR" ]]; then
  fail "$EXT_MEM_DIR exists and is a file, not a directory. Pick a different path or move the file."
fi
if ! mkdir -p "$EXT_MEM_DIR" 2>/dev/null; then
  fail "Cannot create $EXT_MEM_DIR — check permissions or pick a different path."
fi
ok "Memory folder: $EXT_MEM_DIR"

# ----------------------------------------------------------------------------
# Config file generation (idempotent — "already exists" = yellow ⚠, no prompt)
# ----------------------------------------------------------------------------
say "Writing config files"

# -- Permission profile --
if [[ -f .claude/settings.local.json ]]; then
  warn ".claude/settings.local.json already exists — leaving as-is"
else
  HOME_DIR_ESC=$(printf '%s' "$HOME" | sed 's:/:\\/:g')
  HYDRA_ROOT_ESC=$(printf '%s' "$HYDRA_ROOT" | sed 's:/:\\/:g')
  sed -e "s/\$COMMANDER_ROOT/$HYDRA_ROOT_ESC/g" \
      -e "s/\$HOME_DIR/$HOME_DIR_ESC/g" \
      .claude/settings.local.json.example > .claude/settings.local.json
  ok ".claude/settings.local.json"
fi

# -- Repos config --
if [[ -f state/repos.json ]]; then
  warn "state/repos.json already exists — leaving as-is"
else
  cp state/repos.example.json state/repos.json
  ok "state/repos.json (edit to list your repos)"
fi

# -- Runtime state files --
for f in state/active.json state/budget-used.json state/memory-citations.json state/autopickup.json; do
  if [[ -f "$f" ]]; then
    ok "$f (exists)"
  else
    case "$f" in
      */active.json)           echo '{"workers": [], "last_updated": null}' > "$f" ;;
      */budget-used.json)      echo '{"date": null, "tickets_completed_today": 0, "tickets_failed_today": 0, "total_worker_wall_clock_minutes_today": 0, "rate_limit_hits_today": 0, "phase2_spend_usd_today": 0}' > "$f" ;;
      */memory-citations.json) echo '{"_schema": "key = learnings-<repo>.md#<quote>, value = {count, last_cited, tickets, promotion_threshold_reached}", "citations": {}}' > "$f" ;;
      */autopickup.json)       echo '{"enabled": false, "interval_min": 30, "auto_enable_on_session_start": true, "last_run": null, "last_picked_count": 0, "consecutive_rate_limit_hits": 0}' > "$f" ;;
    esac
    ok "$f"
  fi
done

# -- .env for the launcher --
#   FORMAT CONTRACT: these three exports must stay in this order with this
#   exact quoting. scripts/test-local-config.sh greps for them by name.
if [[ -f .hydra.env ]]; then
  warn ".hydra.env already exists — leaving as-is"
else
  cat > .hydra.env <<EOF
# Hydra environment — sourced by ./hydra launcher.
# Do NOT commit this file (gitignored).
export HYDRA_ROOT="$HYDRA_ROOT"
export HYDRA_EXTERNAL_MEMORY_DIR="$EXT_MEM_DIR"
export COMMANDER_ROOT="$HYDRA_ROOT"
EOF
  ok ".hydra.env"
fi

# ----------------------------------------------------------------------------
# Launcher — DO NOT MODIFY the heredoc below. Contract per
# memory/learnings-hydra.md 2026-04-17 #84: ./hydra is NOT committed, it's
# generated here. Editing this block is how you add new ./hydra subcommands,
# but reflowing or restructuring breaks the launcher contract.
# ----------------------------------------------------------------------------
if [[ -f hydra ]]; then
  warn "./hydra launcher already exists — leaving as-is"
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
  -h|--help|help)
    cat <<'HYDRAHELP'
Usage: ./hydra [<subcommand>] [options]

Hydra — persistent AI agent orchestrator. Run with no arguments to
launch the Commander Claude session. Subcommands below dispatch to
helper scripts without launching a chat session (safe for cron / SSH
/ scripts / daily-ops muscle memory).

Subcommands:
  add-repo <owner>/<name>      Interactive wizard: add a repo to state/repos.json.
  remove-repo <owner>/<name>   Remove a repo entry.
  list-repos                   Table view of state/repos.json.
  status [--with-tickets] [--json]
                               Read-only Hydra state snapshot.
  ps [--json]                  Per-worker detail from state/active.json.
  pause [--reason <text>]      Toggle PAUSE on (blocks new worker spawns).
  resume                       Toggle PAUSE off.
  issue <url-or-owner/repo/num>
                               Queue a specific issue for next tick.
  activity [--json]            Text-based observability: last 24h of log
                               activity + live workers + top memory citations.
  doctor [--fix|--fix-safe]    Install sanity check. --fix walks the operator
                               through each fixable issue interactively.
  mcp <serve|register-agent>   MCP server subcommands (agent-only interface).
                               Run `./hydra mcp --help` for details.

Top-level flags:
  --version                    Print the contents of VERSION and exit.
  --no-autopickup              Launch commander with autopickup idle at
                               session start (opt-out of the default-on
                               behavior).
  -h, --help                   Show this help and exit.

Any other arguments (e.g. `-c`, `--continue`, prompt text) pass through
to `claude` when no subcommand is matched.

Docs: README.md (what) · USING.md (how) · docs/specs/ (why)
HYDRAHELP
    exit 0
    ;;
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
  ok "./hydra launcher (chmod +x)"
fi

# ----------------------------------------------------------------------------
# Summary
# ----------------------------------------------------------------------------
printf "\n%s━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━%s\n" "$C_DIM" "$C_RESET"
printf "%sSetup complete.%s\n\n" "$C_BOLD" "$C_RESET"
cat <<EOF
Next steps:
  1. Tell Hydra about a repo:  ./hydra add-repo <owner>/<repo>
  2. Launch the commander:     ./hydra

Memory folder: $EXT_MEM_DIR
  Outside the hydra repo on purpose — learnings persist across upgrades.

Docs: README.md (what) · USING.md (how) · docs/specs/ (why)
EOF

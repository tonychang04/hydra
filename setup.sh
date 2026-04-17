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
for f in state/active.json state/budget-used.json state/memory-citations.json; do
  if [[ -f "$f" ]]; then
    ok "$f exists"
  else
    case "$f" in
      */active.json)          echo '{"workers": [], "last_updated": null}' > "$f" ;;
      */budget-used.json)     echo '{"date": null, "tickets_completed_today": 0, "tickets_failed_today": 0, "total_worker_wall_clock_minutes_today": 0, "rate_limit_hits_today": 0, "phase2_spend_usd_today": 0}' > "$f" ;;
      */memory-citations.json) echo '{"_schema": "key = learnings-<repo>.md#<quote>, value = {count, last_cited, tickets, promotion_threshold_reached}", "citations": {}}' > "$f" ;;
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
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"
[[ -f .hydra.env ]] || { echo "✗ .hydra.env missing. Run ./setup.sh first." >&2; exit 1; }
# shellcheck disable=SC1091
source .hydra.env
[[ -f .claude/settings.local.json ]] || { echo "✗ .claude/settings.local.json missing. Run ./setup.sh." >&2; exit 1; }
[[ -f state/repos.json ]] || { echo "✗ state/repos.json missing. Run ./setup.sh." >&2; exit 1; }
gh auth status >/dev/null 2>&1 || { echo "✗ gh not authenticated. Run: gh auth login" >&2; exit 1; }
exec claude
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

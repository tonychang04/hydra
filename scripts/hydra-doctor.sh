#!/usr/bin/env bash
#
# hydra-doctor.sh — single-command post-install diagnostic for Hydra.
#
# Runs a battery of non-destructive checks and prints per-check pass/fail.
# Exits 0 if all pass or only warnings. Exits 1 if any FAIL.
#
# Categories: environment, config, runtime, memory, scripts, integrations, self-test.
#
# Flags:
#   --category <name>   Run only one category
#   --verbose           Print raw command output per check
#   --fix-safe          Attempt safe auto-remediations (chmod +x, mkdir -p)
#   --fix               Interactive walkthrough: prompt y/n/s for each fixable
#                       failure (implies --fix-safe for mkdir/chmod class)
#   -h, --help          Show this help
#
# Specs:
#   docs/specs/2026-04-16-hydra-doctor.md  (base doctor, ticket #36)
#   docs/specs/2026-04-17-doctor-fix-mode.md  (actionable hints + --fix, #104)
#
# Hard rules:
#   - set -euo pipefail
#   - Bash + jq only (no Python/Node)
#   - Non-destructive by default; --fix-safe / --fix are the only write paths
#   - Never edits CLAUDE.md, policy.md, budget.json, settings.local.json, worker subagents
#   - --fix auto_fix commands are rejected if they contain sudo/curl/wget/brew/
#     apt/rm/mv/redirects — those print as manual hints and never auto-run

set -euo pipefail

# -----------------------------------------------------------------------------
# resolve worktree root (script lives at <root>/scripts/hydra-doctor.sh)
#
# Allow HYDRA_ROOT to override. Needed by the `doctor-fix-smoke` self-test
# fixture (see docs/specs/2026-04-17-doctor-fix-mode.md). Falls back to the
# script's containing worktree so normal invocations keep working unchanged.
# -----------------------------------------------------------------------------
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
if [[ -n "${HYDRA_ROOT:-}" ]] && [[ -d "$HYDRA_ROOT" ]]; then
  ROOT_DIR="$(cd -- "$HYDRA_ROOT" && pwd)"
else
  ROOT_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"
fi

# -----------------------------------------------------------------------------
# color / TTY
# -----------------------------------------------------------------------------
if [[ -t 1 ]] && [[ "${NO_COLOR:-}" != "1" ]]; then
  C_GREEN=$'\033[32m'
  C_RED=$'\033[31m'
  C_YELLOW=$'\033[33m'
  C_DIM=$'\033[2m'
  C_BOLD=$'\033[1m'
  C_RESET=$'\033[0m'
else
  C_GREEN=""
  C_RED=""
  C_YELLOW=""
  C_DIM=""
  C_BOLD=""
  C_RESET=""
fi

usage() {
  cat <<'EOF'
Usage: scripts/hydra-doctor.sh [options]

Runs a battery of diagnostic checks on a Hydra install and prints per-check
pass/fail. Exits 0 if all checks pass or only warnings; exits 1 on any failure.

Options:
  --category <name>    Run only one category. Valid categories:
                         environment | config | runtime | memory |
                         scripts | integrations | self-test | all
                       (default: all)
  --verbose            Print raw command output per check
  --fix-safe           Attempt safe auto-remediations (chmod +x scripts,
                       mkdir -p missing dirs). Non-destructive. No prompts.
  --fix                Interactive: walk through each fixable failure and
                       prompt [y]es apply / [n]o skip / [s]how command /
                       [q]uit. Implies --fix-safe for the auto-remediations.
                       Requires an interactive terminal.
  -h, --help           Show this help

Environment:
  HYDRA_ROOT           Override worktree root (defaults to the script's
                       containing worktree). Used by the self-test fixture.
  NO_COLOR=1           Disable ANSI color output even on a TTY.

Exit codes:
  0   all checks pass or only warnings
  1   one or more checks FAIL
  2   usage error

Categories checked (in order):
  environment   — claude/gh/jq/git present; env vars; memory dir
  config        — settings.local.json / repos.json / budget.json
  runtime       — state files parse; PAUSE file; logs writable
  memory        — MEMORY.md; learnings entries; citations
  scripts       — bash -n; executable bits; state validators
  integrations  — Linear MCP (if enabled); mount-s3 / AWS (if DynamoDB)
  self-test     — ./self-test/run.sh --kind=script
EOF
}

# -----------------------------------------------------------------------------
# arg parsing
# -----------------------------------------------------------------------------
category_filter="all"
verbose=0
fix_safe=0
fix_interactive=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --category)
      [[ $# -ge 2 ]] || { echo "hydra-doctor: --category needs a value" >&2; usage >&2; exit 2; }
      category_filter="$2"; shift 2
      ;;
    --category=*)
      category_filter="${1#--category=}"; shift
      ;;
    --verbose)
      verbose=1; shift
      ;;
    --fix-safe)
      fix_safe=1; shift
      ;;
    --fix)
      fix_interactive=1; fix_safe=1; shift
      ;;
    -h|--help)
      usage; exit 0
      ;;
    *)
      echo "hydra-doctor: unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

# --fix needs an interactive terminal. Scripted callers should use --fix-safe,
# which bypasses prompts for the narrow chmod/mkdir class.
if [[ "$fix_interactive" -eq 1 ]] && [[ ! -t 0 ]] && [[ ! -r /dev/tty ]]; then
  echo "hydra-doctor: --fix requires an interactive terminal; use --fix-safe instead" >&2
  exit 2
fi

case "$category_filter" in
  all|environment|config|runtime|memory|scripts|integrations|self-test) ;;
  *)
    echo "hydra-doctor: invalid --category: $category_filter" >&2
    usage >&2
    exit 2
    ;;
esac

# -----------------------------------------------------------------------------
# counters + tracking
# -----------------------------------------------------------------------------
passed=0
warnings=0
failures=0

# Fix queue — parallel arrays (bash 3.2 compatible; no associative arrays).
# Every check_warn / check_fail with a non-empty hint appends one entry.
# After categories finish, --fix walks this list interactively.
#   fix_labels[i]   — short check label (for the "[k/N] <label>" header)
#   fix_hints[i]    — actionable text: "fix: ...", "run: ...", or "manual: ..."
#   fix_auto[i]     — optional bash command string; empty = manual-only
#   fix_severity[i] — "warn" or "fail" (display color)
fix_labels=()
fix_hints=()
fix_auto=()
fix_severity=()

# AUTO_FIX_DENY — reject auto-runnable fixes that touch anything beyond the
# narrow chmod/mkdir class. `--fix` downgrades these to manual hints.
# Intentionally conservative; widening is a separate spec'd change.
AUTO_FIX_DENY_PATTERN='(^|[^[:alnum:]])(sudo|curl|wget|brew|apt|apt-get|yum|dnf|pip|pipx|npm|pnpm|yarn|rm|mv|cp|dd|kill|pkill|killall)([^[:alnum:]]|$)|[|&;]|>[^&]|<[^<]'

# Per-check reporting primitives.
# Signatures (backward-compatible — extra args optional):
#   check_pass  label [detail]
#   check_warn  label reason [fix_hint] [auto_fix]
#   check_fail  label reason [fix_hint] [auto_fix]
#
# fix_hint  — one-line actionable suggestion, printed in yellow below the
#             warn/fail line. Conventionally prefixed with "fix:" (for an
#             auto-runnable command), "run:" (for a command to run elsewhere),
#             or "manual:" (for instructions to edit a file).
# auto_fix  — bash command string that --fix can offer to run after y/n/s
#             confirmation. Vetoed silently (printed as manual hint instead)
#             if it matches AUTO_FIX_DENY_PATTERN.

check_pass() {
  # $1 = label, $2 = optional detail
  local label="$1" detail="${2:-}"
  if [[ -n "$detail" ]]; then
    printf "  %s✓%s %s %s(%s)%s\n" "$C_GREEN" "$C_RESET" "$label" "$C_DIM" "$detail" "$C_RESET"
  else
    printf "  %s✓%s %s\n" "$C_GREEN" "$C_RESET" "$label"
  fi
  passed=$((passed + 1))
}

check_warn() {
  # $1 = label, $2 = reason, $3 = fix_hint, $4 = auto_fix
  local label="$1" reason="${2:-}" hint="${3:-}" auto="${4:-}"
  if [[ -n "$reason" ]]; then
    printf "  %s⚠%s %s %s— %s%s\n" "$C_YELLOW" "$C_RESET" "$label" "$C_YELLOW" "$reason" "$C_RESET"
  else
    printf "  %s⚠%s %s\n" "$C_YELLOW" "$C_RESET" "$label"
  fi
  if [[ -n "$hint" ]]; then
    printf "      %s%s%s\n" "$C_YELLOW" "$hint" "$C_RESET"
    _queue_fix "$label" "$hint" "$auto" "warn"
  fi
  warnings=$((warnings + 1))
}

check_fail() {
  # $1 = label, $2 = reason, $3 = fix_hint, $4 = auto_fix
  local label="$1" reason="${2:-}" hint="${3:-}" auto="${4:-}"
  if [[ -n "$reason" ]]; then
    printf "  %s✗%s %s %s— %s%s\n" "$C_RED" "$C_RESET" "$label" "$C_RED" "$reason" "$C_RESET"
  else
    printf "  %s✗%s %s\n" "$C_RED" "$C_RESET" "$label"
  fi
  if [[ -n "$hint" ]]; then
    printf "      %s%s%s\n" "$C_YELLOW" "$hint" "$C_RESET"
    _queue_fix "$label" "$hint" "$auto" "fail"
  fi
  failures=$((failures + 1))
}

_queue_fix() {
  # $1=label $2=hint $3=auto $4=severity
  local auto="$3"
  # Veto auto_fix commands that touch anything beyond the chmod/mkdir class.
  if [[ -n "$auto" ]] && [[ "$auto" =~ $AUTO_FIX_DENY_PATTERN ]]; then
    auto=""
  fi
  fix_labels+=("$1")
  fix_hints+=("$2")
  fix_auto+=("$auto")
  fix_severity+=("$4")
}

verbose_log() {
  [[ "$verbose" -eq 1 ]] || return 0
  printf "    %s%s%s\n" "$C_DIM" "$*" "$C_RESET"
}

section_header() {
  printf "\n%s%s%s\n" "$C_BOLD" "$1" "$C_RESET"
}

# Should this category run?
should_run() {
  [[ "$category_filter" == "all" || "$category_filter" == "$1" ]]
}

# -----------------------------------------------------------------------------
# Environment category
# -----------------------------------------------------------------------------
check_environment() {
  section_header "Environment"

  # claude CLI
  if command -v claude >/dev/null 2>&1; then
    local v
    v="$(claude --version 2>/dev/null | head -1 || true)"
    check_pass "claude CLI on PATH" "${v:-version unknown}"
  else
    check_fail "claude CLI on PATH" "not found" \
      "run: install Claude Code from https://claude.com/claude-code, then re-run doctor"
  fi

  # gh CLI + auth
  if command -v gh >/dev/null 2>&1; then
    local gh_v
    gh_v="$(gh --version 2>/dev/null | head -1 || true)"
    if gh auth status >/dev/null 2>&1; then
      local gh_user
      gh_user="$(gh api user --jq .login 2>/dev/null || echo '?')"
      check_pass "gh CLI authenticated" "${gh_v:-}; user=$gh_user"
    else
      check_fail "gh CLI authenticated" "gh auth status failed" \
        "run: gh auth login    # then re-run doctor"
    fi
  else
    check_fail "gh CLI on PATH" "not found" \
      "run: brew install gh    # or see https://cli.github.com for your OS"
  fi

  # jq
  if command -v jq >/dev/null 2>&1; then
    local jq_v
    jq_v="$(jq --version 2>/dev/null || true)"
    check_pass "jq on PATH" "${jq_v:-}"
  else
    check_fail "jq on PATH" "not found" \
      "run: brew install jq    # or apt-get install jq on Linux"
  fi

  # git version ≥ 2.25 (worktree support)
  if command -v git >/dev/null 2>&1; then
    local git_v major minor
    git_v="$(git --version 2>/dev/null | awk '{print $3}' || true)"
    major="$(echo "$git_v" | awk -F. '{print $1}')"
    minor="$(echo "$git_v" | awk -F. '{print $2}')"
    if [[ "$major" =~ ^[0-9]+$ ]] && [[ "$minor" =~ ^[0-9]+$ ]] && \
       { [[ "$major" -gt 2 ]] || { [[ "$major" -eq 2 ]] && [[ "$minor" -ge 25 ]]; }; }; then
      check_pass "git ≥ 2.25 (worktree support)" "git $git_v"
    else
      check_fail "git ≥ 2.25 (worktree support)" "found git $git_v" \
        "run: brew install git    # or upgrade your distro's git package"
    fi
  else
    check_fail "git on PATH" "not found" \
      "run: brew install git    # git is a hard dep — worker worktrees need it"
  fi

  # HYDRA_ROOT / HYDRA_EXTERNAL_MEMORY_DIR env vars
  if [[ -n "${HYDRA_ROOT:-}" ]]; then
    check_pass "\$HYDRA_ROOT set" "$HYDRA_ROOT"
  else
    check_warn "\$HYDRA_ROOT set" "unset; setup.sh writes it to .hydra.env — launcher sources it" \
      "manual: launch hydra via ./hydra (not scripts/ directly) so .hydra.env is sourced"
  fi

  if [[ -n "${HYDRA_EXTERNAL_MEMORY_DIR:-}" ]]; then
    check_pass "\$HYDRA_EXTERNAL_MEMORY_DIR set" "$HYDRA_EXTERNAL_MEMORY_DIR"
  else
    check_warn "\$HYDRA_EXTERNAL_MEMORY_DIR set" "unset; will fall back to ./memory/ (OK for Phase 1)" \
      "manual: export HYDRA_EXTERNAL_MEMORY_DIR=\$HOME/.hydra/memory in .hydra.env to split memory from the repo"
  fi

  # External memory dir exists + writable
  local ext_mem="${HYDRA_EXTERNAL_MEMORY_DIR:-}"
  if [[ -n "$ext_mem" ]]; then
    if [[ -d "$ext_mem" ]]; then
      if [[ -w "$ext_mem" ]]; then
        check_pass "external memory dir exists + writable" "$ext_mem"
      else
        check_fail "external memory dir writable" "$ext_mem is not writable" \
          "run: chmod u+w '$ext_mem'    # or chown to your user"
      fi
    else
      if [[ "$fix_safe" -eq 1 ]] && [[ "$fix_interactive" -eq 0 ]]; then
        if mkdir -p "$ext_mem" 2>/dev/null; then
          check_pass "external memory dir created" "$ext_mem (--fix-safe)"
        else
          check_fail "external memory dir exists" "$ext_mem does not exist and mkdir failed" \
            "run: mkdir -p '$ext_mem'    # check parent dir permissions"
        fi
      else
        check_fail "external memory dir exists" "$ext_mem does not exist" \
          "fix: mkdir -p '$ext_mem'" \
          "mkdir -p '$ext_mem'"
      fi
    fi
  else
    verbose_log "skipping external memory dir check (env var unset)"
  fi
}

# -----------------------------------------------------------------------------
# Config category
# -----------------------------------------------------------------------------
check_config() {
  section_header "Config"

  # .claude/settings.local.json
  local settings="$ROOT_DIR/.claude/settings.local.json"
  if [[ -f "$settings" ]]; then
    if jq empty "$settings" 2>/dev/null; then
      check_pass ".claude/settings.local.json valid JSON"
    else
      check_fail ".claude/settings.local.json valid JSON" "parse error" \
        "manual: jq . $settings to see the parse error; fix the JSON or restore from .claude/settings.local.json.example"
    fi
  else
    check_fail ".claude/settings.local.json exists" "missing" \
      "run: ./setup.sh    # creates it from .claude/settings.local.json.example"
  fi

  # Self-modification denylist spot-check (look for Edit($COMMANDER_ROOT/CLAUDE.md))
  if [[ -f "$settings" ]]; then
    if grep -Fq "Edit(\$COMMANDER_ROOT/CLAUDE.md)" "$settings" 2>/dev/null || \
       grep -Fq "Edit(${HYDRA_ROOT:-}/CLAUDE.md)" "$settings" 2>/dev/null; then
      check_pass "self-modification denylist intact" "Edit(...CLAUDE.md) present in deny"
    else
      # Try a looser check — any Edit(...CLAUDE.md) pattern in the deny block.
      if jq -e '.permissions.deny // [] | map(select(test("CLAUDE.md"))) | length > 0' \
         "$settings" >/dev/null 2>&1; then
        check_pass "self-modification denylist intact" "CLAUDE.md denied via permissions.deny"
      else
        check_fail "self-modification denylist intact" \
          "no Edit(...CLAUDE.md) entry found in .claude/settings.local.json deny list" \
          "manual: add \"Edit(\$COMMANDER_ROOT/CLAUDE.md)\" to permissions.deny in .claude/settings.local.json — this protects Commander from editing its own system prompt"
      fi
    fi
  fi

  # state/repos.json
  local repos="$ROOT_DIR/state/repos.json"
  if [[ -f "$repos" ]]; then
    if jq empty "$repos" 2>/dev/null; then
      local enabled_count
      enabled_count="$(jq '[.repos // [] | .[] | select(.enabled == true)] | length' "$repos" 2>/dev/null || echo 0)"
      if [[ "$enabled_count" -ge 1 ]]; then
        check_pass "state/repos.json valid" "$enabled_count enabled repo(s)"
      else
        check_warn "state/repos.json has ≥1 enabled repo" "0 enabled" \
          "manual: edit state/repos.json and set .enabled = true for at least one repo, or run ./hydra add-repo"
      fi

      # Each enabled repo: local_path + .git/
      local paths
      paths="$(jq -r '.repos // [] | .[] | select(.enabled == true) | .local_path // empty' "$repos" 2>/dev/null || true)"
      if [[ -n "$paths" ]]; then
        while IFS= read -r p; do
          [[ -z "$p" ]] && continue
          if [[ -d "$p" ]]; then
            if [[ -d "$p/.git" ]] || [[ -f "$p/.git" ]]; then
              check_pass "repo local_path + .git/" "$p"
            else
              check_fail "repo local_path has .git/" "$p exists but is not a git repo" \
                "manual: cd '$p' && git init    # or update state/repos.json:local_path to the correct clone"
            fi
          else
            check_fail "repo local_path exists" "$p does not exist" \
              "run: git clone <remote-url> '$p'    # or update state/repos.json:local_path"
          fi
        done <<< "$paths"
      fi
    else
      check_fail "state/repos.json valid JSON" "parse error" \
        "manual: jq . '$repos' to see the parse error; restore from state/repos.example.json if needed"
    fi
  else
    check_fail "state/repos.json exists" "missing" \
      "run: ./setup.sh    # then edit state/repos.json to list your repos"
  fi

  # budget.json
  local budget="$ROOT_DIR/budget.json"
  if [[ -f "$budget" ]]; then
    if jq empty "$budget" 2>/dev/null; then
      local mcw
      mcw="$(jq -r '.phase1_subscription_caps.max_concurrent_workers // empty' "$budget" 2>/dev/null || true)"
      if [[ "$mcw" =~ ^[0-9]+$ ]] && [[ "$mcw" -ge 1 ]] && [[ "$mcw" -le 20 ]]; then
        check_pass "budget.json sane" "max_concurrent_workers=$mcw"
      else
        check_fail "budget.json sane" "max_concurrent_workers out of [1,20]: got '$mcw'" \
          "manual: edit budget.json and set .phase1_subscription_caps.max_concurrent_workers to a value between 1 and 20"
      fi
    else
      check_fail "budget.json valid JSON" "parse error" \
        "manual: jq . '$budget' to see the parse error; restore from the default in git history"
    fi
  else
    check_fail "budget.json exists" "missing" \
      "run: git checkout budget.json    # restore from the repo's committed default"
  fi

  # Commander runtime mode — parse infra/fly.toml's primary [http_service]
  # block and report always-on vs suspend vs mixed vs unknown. Ticket #126,
  # spec docs/specs/2026-04-17-managed-agents-migration.md.
  # Never FAILS — either explicit mode is valid. Only warns on mixed/unknown
  # (operator almost certainly didn't intend either).
  local fly_toml="$ROOT_DIR/infra/fly.toml"
  if [[ -f "$fly_toml" ]]; then
    # Extract the primary [http_service] block with an awk FSM. Stops at the
    # next unindented ^[ line so the secondary [[services]] blocks don't
    # bleed in. Indented [[http_service.checks]] is allowed to stay inside
    # the block — it's the sub-table of the primary.
    local http_block min_mr auto_stop
    http_block="$(awk '
      /^\[http_service\]/ {flag=1; print; next}
      flag && /^\[/ {flag=0}
      flag
    ' "$fly_toml" 2>/dev/null || true)"

    if [[ -z "$http_block" ]]; then
      check_warn "Commander runtime mode" "no [http_service] block found in infra/fly.toml" \
        "manual: restore infra/fly.toml from git — the primary [http_service] block drives the Machine's run state (ticket #126 / docs/specs/2026-04-17-managed-agents-migration.md)"
    else
      # Extract the live values — first match wins if the operator duplicated
      # the key (malformed but not our problem to fix). Strip trailing `#
      # comment` before parsing so a line like `min_machines_running = 1  #
      # blah` extracts cleanly. Uses POSIX char classes ([[:space:]]) for
      # BSD sed (macOS) compatibility.
      min_mr="$(grep -E '^[[:space:]]*min_machines_running[[:space:]]*=' <<<"$http_block" \
        | head -1 | sed -E 's/#.*$//' | sed -E 's/.*=[[:space:]]*([0-9]+).*/\1/' || true)"
      auto_stop="$(grep -E '^[[:space:]]*auto_stop_machines[[:space:]]*=' <<<"$http_block" \
        | head -1 | sed -E 's/#.*$//' | sed -E "s/.*=[[:space:]]*['\"]([^'\"]+)['\"].*/\\1/" || true)"
      # Trim any whitespace on the results.
      min_mr="$(echo "$min_mr" | tr -d '[:space:]')"
      auto_stop="$(echo "$auto_stop" | tr -d '[:space:]')"

      case "${min_mr}/${auto_stop}" in
        "1/off")
          check_pass "Commander runtime mode: always-on" "infra/fly.toml"
          ;;
        "0/suspend")
          check_warn "Commander runtime mode: suspend" \
            "autopickup won't tick while idle; needs webhook or manual wake" \
            "manual: flip to always-on by setting min_machines_running=1 + auto_stop_machines=\"off\" in infra/fly.toml's [http_service] block — see docs/phase2-vps-runbook.md \"Always-on vs suspend-on-idle\""
          ;;
        "1/suspend"|"0/off")
          check_warn "Commander runtime mode: mixed" \
            "min_machines_running=$min_mr + auto_stop_machines=$auto_stop is inconsistent (expected 1/off or 0/suspend)" \
            "manual: pick a mode in infra/fly.toml's [http_service] block — docs/phase2-vps-runbook.md \"Always-on vs suspend-on-idle\" walks through the trade-off"
          ;;
        *)
          check_warn "Commander runtime mode: unknown" \
            "couldn't parse min_machines_running / auto_stop_machines from [http_service] (got '${min_mr}' / '${auto_stop}')" \
            "manual: inspect infra/fly.toml's [http_service] block — it should contain 'min_machines_running = <int>' and 'auto_stop_machines = \"off\"|\"suspend\"' on single-value lines"
          ;;
      esac
    fi
  else
    # fly.toml is a Phase 2 file; not shipping it is fine (local-only
    # operators never deploy to Fly). Silent skip via verbose_log — no
    # warning noise on clean local installs.
    verbose_log "skipping Commander runtime mode check (infra/fly.toml not present)"
  fi
}

# -----------------------------------------------------------------------------
# Runtime state category
# -----------------------------------------------------------------------------
check_runtime() {
  section_header "Runtime state"

  local f
  for f in state/active.json state/budget-used.json state/memory-citations.json; do
    local p="$ROOT_DIR/$f"
    if [[ -f "$p" ]]; then
      if jq empty "$p" 2>/dev/null; then
        check_pass "$f exists + parses"
      else
        check_fail "$f valid JSON" "parse error" \
          "manual: jq . '$p' to see the parse error; restore from state/*.example.json if needed"
      fi
    else
      check_fail "$f exists" "missing" \
        "run: ./setup.sh    # creates state/*.json from their .example templates"
    fi
  done

  # PAUSE file
  if [[ -f "$ROOT_DIR/PAUSE" ]] || [[ -f "$ROOT_DIR/commander/PAUSE" ]]; then
    check_warn "no unexpected PAUSE file" "PAUSE present — commander will refuse to spawn" \
      "manual: rm PAUSE (or commander/PAUSE) when you're ready to resume, or tell commander 'resume'"
  else
    check_pass "no PAUSE file"
  fi

  # logs/ writable
  local logs="$ROOT_DIR/logs"
  if [[ -d "$logs" ]]; then
    if [[ -w "$logs" ]]; then
      check_pass "logs/ writable"
    else
      check_fail "logs/ writable" "not writable" \
        "run: chmod u+w '$logs'    # or chown to your user"
    fi
  else
    if [[ "$fix_safe" -eq 1 ]] && [[ "$fix_interactive" -eq 0 ]]; then
      if mkdir -p "$logs" 2>/dev/null; then
        check_pass "logs/ created" "$logs (--fix-safe)"
      else
        check_fail "logs/ exists" "mkdir failed" \
          "run: mkdir -p '$logs'    # check parent dir permissions"
      fi
    else
      check_warn "logs/ exists" "missing" \
        "fix: mkdir -p '$logs'" \
        "mkdir -p '$logs'"
    fi
  fi
}

# -----------------------------------------------------------------------------
# Memory category
# -----------------------------------------------------------------------------
check_memory() {
  section_header "Memory"

  # memory/MEMORY.md
  if [[ -f "$ROOT_DIR/memory/MEMORY.md" ]]; then
    check_pass "memory/MEMORY.md exists"
  else
    check_fail "memory/MEMORY.md exists" "missing" \
      "run: git checkout memory/MEMORY.md    # framework file; restore from the repo"
  fi

  # validate-learning-entry.sh against every learnings-*.md
  local validator="$ROOT_DIR/scripts/validate-learning-entry.sh"
  if [[ -x "$validator" ]]; then
    shopt -s nullglob
    local learning_files=("$ROOT_DIR/memory/"learnings-*.md)
    local ext_mem="${HYDRA_EXTERNAL_MEMORY_DIR:-}"
    if [[ -n "$ext_mem" ]] && [[ -d "$ext_mem" ]]; then
      # bash 3.2 note: `foo=("$glob"*)` under `set -u` with zero matches leaves
      # foo unset, which then blows up `"${foo[@]}"`. shopt nullglob above
      # gives us an empty array on zero-matches; still default-guard the
      # expansion so a bare `set -u` + empty dir doesn't abort doctor even
      # if a future refactor drops `nullglob`.
      local ext_learnings=("$ext_mem/"learnings-*.md)
      if [[ ${#ext_learnings[@]:-0} -gt 0 ]]; then
        learning_files+=("${ext_learnings[@]:-}")
      fi
    fi
    shopt -u nullglob

    if [[ ${#learning_files[@]} -eq 0 ]]; then
      check_pass "validate-learning-entry.sh" "no learnings-*.md files yet (clean install)"
    else
      local f bad=0
      for f in "${learning_files[@]}"; do
        if "$validator" "$f" >/dev/null 2>&1; then
          verbose_log "learnings valid: $f"
        else
          check_fail "validate-learning-entry.sh on $(basename "$f")" "failed" \
            "run: scripts/validate-learning-entry.sh '$f'    # shows which frontmatter/field failed"
          bad=1
        fi
      done
      if [[ "$bad" -eq 0 ]]; then
        check_pass "validate-learning-entry.sh" "${#learning_files[@]} file(s) valid"
      fi
    fi
  else
    check_warn "scripts/validate-learning-entry.sh executable" "missing or not executable" \
      "fix: chmod +x '$validator'" \
      "chmod +x '$validator'"
  fi

  # validate-citations.sh against memory-citations.json
  local cite_validator="$ROOT_DIR/scripts/validate-citations.sh"
  local cite_file="$ROOT_DIR/state/memory-citations.json"
  if [[ -x "$cite_validator" ]] && [[ -f "$cite_file" ]]; then
    if "$cite_validator" --citations "$cite_file" >/dev/null 2>&1; then
      check_pass "validate-citations.sh on memory-citations.json"
    else
      # Empty citations may be fine — only fail if stale quotes found.
      local citation_count
      citation_count="$(jq '.citations // {} | length' "$cite_file" 2>/dev/null || echo 0)"
      if [[ "$citation_count" -eq 0 ]]; then
        check_pass "validate-citations.sh" "empty citations (clean install)"
      else
        check_fail "validate-citations.sh on memory-citations.json" "stale or invalid entries" \
          "run: scripts/validate-citations.sh --citations '$cite_file'    # shows which citation's quote no longer matches"
      fi
    fi
  elif [[ ! -x "$cite_validator" ]]; then
    check_warn "scripts/validate-citations.sh executable" "missing or not executable" \
      "fix: chmod +x '$cite_validator'" \
      "chmod +x '$cite_validator'"
  fi
}

# -----------------------------------------------------------------------------
# Scripts category (deterministic — doesn't depend on external state)
# -----------------------------------------------------------------------------
check_scripts() {
  section_header "Scripts"

  # bash -n on all shell scripts
  local bad_syntax=0
  local f
  shopt -s nullglob
  local all_sh=(
    "$ROOT_DIR/scripts/"*.sh
    "$ROOT_DIR/setup.sh"
    "$ROOT_DIR/install.sh"
    "$ROOT_DIR/self-test/run.sh"
  )
  shopt -u nullglob

  for f in "${all_sh[@]}"; do
    [[ -f "$f" ]] || continue
    if bash -n "$f" 2>/dev/null; then
      verbose_log "bash -n OK: $f"
    else
      check_fail "bash -n $(basename "$f")" "syntax error" \
        "run: bash -n '$f'    # shows the line number of the syntax error"
      bad_syntax=1
    fi
  done
  [[ "$bad_syntax" -eq 0 ]] && check_pass "bash -n all shell scripts" "${#all_sh[@]} file(s)"

  # Executable bits
  local not_exec=()
  for f in "${all_sh[@]}"; do
    [[ -f "$f" ]] || continue
    if [[ ! -x "$f" ]]; then
      not_exec+=("$f")
    fi
  done

  if [[ ${#not_exec[@]} -eq 0 ]]; then
    check_pass "scripts executable (+x)"
  else
    if [[ "$fix_safe" -eq 1 ]] && [[ "$fix_interactive" -eq 0 ]]; then
      local nf
      for nf in "${not_exec[@]}"; do
        chmod +x "$nf" 2>/dev/null || true
      done
      check_pass "scripts executable (+x)" "chmod +x applied to ${#not_exec[@]} file(s) (--fix-safe)"
    else
      # Build a chmod +x command that covers every affected file.
      local nf_list=""
      for nf in "${not_exec[@]}"; do
        nf_list+=" '$nf'"
      done
      check_warn "scripts executable (+x)" "${#not_exec[@]} not executable" \
        "fix: chmod +x$nf_list" \
        "chmod +x$nf_list"
    fi
  fi

  # validate-state.sh against each state/*.json with a schema
  local vs="$ROOT_DIR/scripts/validate-state.sh"
  if [[ -x "$vs" ]]; then
    shopt -s nullglob
    local state_files=("$ROOT_DIR/state/"*.json)
    shopt -u nullglob
    local any_fail=0
    local checked=0
    for f in "${state_files[@]}"; do
      # Skip example/template files
      case "$(basename "$f")" in
        *.example.json) continue ;;
      esac
      local base schema
      base="$(basename "$f" .json)"
      schema="$ROOT_DIR/state/schemas/${base}.schema.json"
      [[ -f "$schema" ]] || continue  # no schema → skip silently
      if "$vs" "$f" >/dev/null 2>&1; then
        verbose_log "validate-state: $f OK"
        checked=$((checked + 1))
      else
        check_fail "validate-state.sh on $base.json" "failed" \
          "run: scripts/validate-state.sh '$f'    # shows which field failed against $schema"
        any_fail=1
      fi
    done
    if [[ "$any_fail" -eq 0 ]]; then
      check_pass "validate-state.sh" "$checked state file(s) pass schema check"
    fi
  else
    check_warn "scripts/validate-state.sh executable" "missing" \
      "fix: chmod +x '$vs'" \
      "chmod +x '$vs'"
  fi

  # Launcher version marker — match against the heredoc body in setup.sh.
  # Spec: docs/specs/2026-04-17-launcher-auto-regen.md (ticket #123).
  # Silently skip if the launcher doesn't exist (fresh clone, setup.sh never ran);
  # other checks in the Config category would already have flagged that.
  local launcher="$ROOT_DIR/hydra"
  local lmh="$ROOT_DIR/scripts/launcher-marker.sh"
  local setup="$ROOT_DIR/setup.sh"
  if [[ -f "$launcher" ]] && [[ -x "$lmh" ]] && [[ -f "$setup" ]]; then
    # Extract the launcher body from setup.sh (between the line
    # `cat > "$LAUNCHER_TMP" <<'EOF'` and the next `^EOF$`), write to a
    # tmpfile with the placeholder substituted to a fixed token, then ask
    # launcher-marker.sh to compute the marker. The extraction script lives
    # inline here so the check has no new external dependencies.
    local tmp_body tmp_marker
    tmp_body="$(mktemp)"
    # awk FSM: start emitting after we see `<<'EOF'` on the LAUNCHER_TMP
    # heredoc opener; stop at the next bare `EOF` line.
    awk '
      /cat > "\$LAUNCHER_TMP" <<'"'"'EOF'"'"'/ { inhere=1; next }
      inhere && /^EOF$/ { inhere=0; exit }
      inhere { print }
    ' "$setup" > "$tmp_body"
    if [[ ! -s "$tmp_body" ]]; then
      check_warn "launcher version check" "could not extract heredoc from setup.sh" \
        "manual: verify setup.sh still contains the <<'EOF' launcher heredoc block"
      rm -f "$tmp_body"
    else
      # Compute the expected marker from the fresh body.
      set +e
      tmp_marker="$("$lmh" compute "$tmp_body" 2>/dev/null)"
      local compute_rc=$?
      set -e
      rm -f "$tmp_body"
      if [[ "$compute_rc" -ne 0 ]] || [[ -z "$tmp_marker" ]]; then
        check_warn "launcher version check" "could not compute expected marker (sha256 unavailable?)" \
          "manual: install coreutils (sha256sum) and re-run doctor"
      else
        # Extract the on-disk marker; compare.
        set +e
        local on_disk_marker
        on_disk_marker="$("$lmh" extract "$launcher" 2>/dev/null)"
        local extract_rc=$?
        set -e
        case "$extract_rc" in
          0)
            if [[ "$on_disk_marker" == "$tmp_marker" ]]; then
              check_pass "launcher version matches setup.sh" "version $tmp_marker"
            else
              check_warn "launcher version matches setup.sh" \
                "had $on_disk_marker, expected $tmp_marker — launcher is stale" \
                "run: ./setup.sh --non-interactive    # regenerates ./hydra; old saved as ./hydra.bak-<ts>"
            fi
            ;;
          4)
            check_warn "launcher version matches setup.sh" \
              "./hydra has no version marker (pre-#123 install)" \
              "run: ./setup.sh --non-interactive    # adds the marker; old saved as ./hydra.bak-<ts>"
            ;;
          5)
            check_warn "launcher version matches setup.sh" \
              "./hydra marker line present but malformed" \
              "run: ./setup.sh --non-interactive    # regenerates ./hydra; old saved as ./hydra.bak-<ts>"
            ;;
          *)
            check_warn "launcher version check" "marker extraction failed (exit $extract_rc)" \
              "run: scripts/launcher-marker.sh extract '$launcher'    # see the exact error"
            ;;
        esac
      fi
    fi
  else
    # Silent skip — lack of ./hydra is caught by the Config category; lack
    # of launcher-marker.sh is caught by the scripts-executable check above.
    verbose_log "launcher version check skipped (./hydra or launcher-marker.sh missing)"
  fi
}

# -----------------------------------------------------------------------------
# Integrations category (only checked if configured)
# -----------------------------------------------------------------------------
check_integrations() {
  section_header "Optional integrations"

  # Linear MCP if state/linear.json:enabled=true
  local linear="$ROOT_DIR/state/linear.json"
  if [[ -f "$linear" ]]; then
    local enabled
    enabled="$(jq -r '.enabled // false' "$linear" 2>/dev/null || echo false)"
    if [[ "$enabled" == "true" ]]; then
      if command -v claude >/dev/null 2>&1; then
        if claude mcp list 2>/dev/null | grep -iq linear; then
          check_pass "Linear MCP server installed" "state/linear.json:enabled=true"
        else
          check_fail "Linear MCP server installed" \
            "state/linear.json:enabled=true but 'claude mcp list' shows no linear entry" \
            "run: claude mcp add linear    # or flip state/linear.json:enabled to false if you don't use Linear"
        fi
      else
        check_warn "Linear MCP check" "claude CLI missing, cannot verify" \
          "run: install Claude Code from https://claude.com/claude-code so 'claude mcp list' is available"
      fi
    else
      verbose_log "Linear integration disabled (state/linear.json:enabled=false) — skipping"
      check_pass "Linear integration" "not enabled (skipped)"
    fi
  else
    verbose_log "state/linear.json not present — skipping Linear check"
    check_pass "Linear integration" "not configured (skipped)"
  fi

  # AWS + mount-s3 if HYDRA_STATE_BACKEND=dynamodb
  if [[ "${HYDRA_STATE_BACKEND:-}" == "dynamodb" ]]; then
    if command -v mount-s3 >/dev/null 2>&1; then
      check_pass "mount-s3 installed" "HYDRA_STATE_BACKEND=dynamodb"
    else
      check_fail "mount-s3 installed" "HYDRA_STATE_BACKEND=dynamodb but mount-s3 not on PATH" \
        "run: install mount-s3 — see https://github.com/awslabs/mountpoint-s3/releases"
    fi

    if command -v aws >/dev/null 2>&1; then
      if aws sts get-caller-identity >/dev/null 2>&1; then
        check_pass "AWS credentials configured"
      else
        check_fail "AWS credentials configured" "aws sts get-caller-identity failed" \
          "run: aws configure    # or set AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY env vars"
      fi
    else
      check_fail "aws CLI on PATH" "HYDRA_STATE_BACKEND=dynamodb but aws CLI missing" \
        "run: brew install awscli    # or see https://aws.amazon.com/cli for your OS"
    fi
  else
    verbose_log "HYDRA_STATE_BACKEND != dynamodb — skipping AWS/mount-s3 checks"
    check_pass "DynamoDB backend" "not enabled (skipped)"
  fi
}

# -----------------------------------------------------------------------------
# Self-test category
# -----------------------------------------------------------------------------
check_self_test() {
  section_header "Self-test"

  local runner="$ROOT_DIR/self-test/run.sh"
  if [[ ! -x "$runner" ]]; then
    check_fail "./self-test/run.sh executable" "missing or not +x" \
      "fix: chmod +x '$runner'" \
      "chmod +x '$runner'"
    return
  fi

  local tmp
  tmp="$(mktemp)"
  if NO_COLOR=1 "$runner" --kind=script >"$tmp" 2>&1; then
    local line
    line="$(grep -E '[0-9]+ passed' "$tmp" | tail -1 || true)"
    check_pass "./self-test/run.sh --kind=script" "${line:-passed}"
    verbose_log "--- self-test output ---"
    [[ "$verbose" -eq 1 ]] && sed 's/^/    /' "$tmp"
  else
    check_fail "./self-test/run.sh --kind=script" "one or more script cases failed" \
      "run: ./self-test/run.sh --kind=script --verbose    # shows per-case stdout + which assertion failed"
    if [[ "$verbose" -eq 1 ]] || [[ -s "$tmp" ]]; then
      echo "    ${C_DIM}--- self-test output ---${C_RESET}"
      sed 's/^/    /' "$tmp"
    fi
  fi
  rm -f "$tmp"
}

# -----------------------------------------------------------------------------
# --fix interactive walkthrough
#
# Runs AFTER all categories emit their lines so the operator sees the full
# doctor report first, then gets a focused y/n/s loop over each queued fix.
#
# Per item:
#   y → execute fix_auto[i] via bash -c (if present + safely allowlisted);
#       report ran/failed; move on.
#   n → skip; move on.
#   s → print the exact command that would run; re-prompt same item.
#   q → quit the loop early; remaining items are untouched.
# Items with no auto_fix (manual hints) print and move on — nothing to run.
# -----------------------------------------------------------------------------
run_fix_walkthrough() {
  # Short-circuit if nothing queued
  if [[ ${#fix_labels[@]} -eq 0 ]]; then
    echo
    printf "%sNo fixable issues queued.%s\n" "$C_DIM" "$C_RESET"
    return 0
  fi

  echo
  printf "%s─── Fix walkthrough ───%s\n" "$C_BOLD" "$C_RESET"
  printf "%s%d item(s). [y]es apply · [n]o skip · [s]how · [q]uit%s\n" \
    "$C_DIM" "${#fix_labels[@]}" "$C_RESET"

  local n="${#fix_labels[@]}"
  local i
  for ((i=0; i<n; i++)); do
    local label="${fix_labels[$i]}"
    local hint="${fix_hints[$i]}"
    local auto="${fix_auto[$i]}"
    local sev="${fix_severity[$i]}"
    local marker="✗" mcol="$C_RED"
    if [[ "$sev" == "warn" ]]; then marker="⚠"; mcol="$C_YELLOW"; fi

    echo
    printf "  [%d/%d] %s%s%s %s\n" "$((i+1))" "$n" "$mcol" "$marker" "$C_RESET" "$label"
    printf "        %s%s%s\n" "$C_YELLOW" "$hint" "$C_RESET"

    if [[ -z "$auto" ]]; then
      printf "        %s(manual fix — nothing auto-runnable)%s\n" "$C_DIM" "$C_RESET"
      continue
    fi

    # Interactive prompt. Reads from /dev/tty so stdout pipes still work.
    while :; do
      local ans=""
      printf "        %s▸%s " "$C_BOLD" "$C_RESET"
      if ! read -r ans </dev/tty; then
        echo
        printf "        %s(stdin closed — ending walkthrough)%s\n" "$C_DIM" "$C_RESET"
        return 0
      fi
      case "$ans" in
        y|Y|yes)
          local fix_stdout fix_stderr fix_exit
          fix_stdout="$(mktemp)"; fix_stderr="$(mktemp)"
          set +e
          bash -c "$auto" >"$fix_stdout" 2>"$fix_stderr"
          fix_exit=$?
          set -e
          if [[ "$fix_exit" -eq 0 ]]; then
            printf "        %s→ ran. ✓%s\n" "$C_GREEN" "$C_RESET"
            if [[ "$verbose" -eq 1 ]] && [[ -s "$fix_stdout" ]]; then
              sed "s/^/        $C_DIM/; s/$/$C_RESET/" "$fix_stdout"
            fi
          else
            printf "        %s→ failed (exit %d):%s\n" "$C_RED" "$fix_exit" "$C_RESET"
            [[ -s "$fix_stderr" ]] && sed "s/^/        $C_RED/; s/$/$C_RESET/" "$fix_stderr"
          fi
          rm -f "$fix_stdout" "$fix_stderr"
          break
          ;;
        n|N|no|"")
          printf "        %s→ skipped.%s\n" "$C_DIM" "$C_RESET"
          break
          ;;
        s|S|show)
          printf "        %s→ would run: %s%s%s\n" "$C_DIM" "$C_BOLD" "$auto" "$C_RESET"
          # loop: re-prompt
          ;;
        q|Q|quit)
          printf "        %s→ quitting walkthrough (remaining items untouched).%s\n" "$C_DIM" "$C_RESET"
          return 0
          ;;
        *)
          printf "        %s(answer y/n/s/q)%s\n" "$C_DIM" "$C_RESET"
          ;;
      esac
    done
  done
}

# -----------------------------------------------------------------------------
# run
# -----------------------------------------------------------------------------
printf "%s▸ Hydra Doctor%s\n" "$C_BOLD" "$C_RESET"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

should_run environment  && check_environment
should_run config       && check_config
should_run runtime      && check_runtime
should_run memory       && check_memory
should_run scripts      && check_scripts
should_run integrations && check_integrations
should_run self-test    && check_self_test

# --fix interactive walkthrough (after categories, before summary).
if [[ "$fix_interactive" -eq 1 ]]; then
  run_fix_walkthrough
fi

echo
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Overall status
overall="OK"
overall_color="$C_GREEN"
if [[ "$failures" -gt 0 ]]; then
  overall="FAIL"
  overall_color="$C_RED"
elif [[ "$warnings" -gt 0 ]]; then
  overall="WARN"
  overall_color="$C_YELLOW"
fi

printf "Summary: %d passed · %d warnings · %d failures  (overall: %s%s%s)\n" \
  "$passed" "$warnings" "$failures" "$overall_color" "$overall" "$C_RESET"

[[ "$failures" -gt 0 ]] && exit 1
exit 0

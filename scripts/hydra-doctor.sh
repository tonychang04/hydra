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
#   -h, --help          Show this help
#
# Spec: docs/specs/2026-04-16-hydra-doctor.md
#
# Hard rules:
#   - set -euo pipefail
#   - Bash + jq only (no Python/Node)
#   - Non-destructive by default; --fix-safe is the only write path
#   - Never edits CLAUDE.md, policy.md, budget.json, settings.local.json, worker subagents

set -euo pipefail

# -----------------------------------------------------------------------------
# resolve worktree root (script lives at <root>/scripts/hydra-doctor.sh)
# -----------------------------------------------------------------------------
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"

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
                       mkdir -p missing dirs). Non-destructive.
  -h, --help           Show this help

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

# Per-check reporting primitives. Each returns 0 on pass, 1 on warn, 2 on fail.
# We track counters directly.

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
  # $1 = label, $2 = reason
  local label="$1" reason="${2:-}"
  if [[ -n "$reason" ]]; then
    printf "  %s⚠%s %s %s— %s%s\n" "$C_YELLOW" "$C_RESET" "$label" "$C_YELLOW" "$reason" "$C_RESET"
  else
    printf "  %s⚠%s %s\n" "$C_YELLOW" "$C_RESET" "$label"
  fi
  warnings=$((warnings + 1))
}

check_fail() {
  # $1 = label, $2 = reason
  local label="$1" reason="${2:-}"
  if [[ -n "$reason" ]]; then
    printf "  %s✗%s %s %s— %s%s\n" "$C_RED" "$C_RESET" "$label" "$C_RED" "$reason" "$C_RESET"
  else
    printf "  %s✗%s %s\n" "$C_RED" "$C_RESET" "$label"
  fi
  failures=$((failures + 1))
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
    check_fail "claude CLI on PATH" "not found; install https://claude.com/claude-code"
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
      check_fail "gh CLI authenticated" "gh auth status failed; run 'gh auth login'"
    fi
  else
    check_fail "gh CLI on PATH" "not found; brew install gh"
  fi

  # jq
  if command -v jq >/dev/null 2>&1; then
    local jq_v
    jq_v="$(jq --version 2>/dev/null || true)"
    check_pass "jq on PATH" "${jq_v:-}"
  else
    check_fail "jq on PATH" "not found; brew install jq"
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
      check_fail "git ≥ 2.25 (worktree support)" "found git $git_v"
    fi
  else
    check_fail "git on PATH" "not found"
  fi

  # HYDRA_ROOT / HYDRA_EXTERNAL_MEMORY_DIR env vars
  if [[ -n "${HYDRA_ROOT:-}" ]]; then
    check_pass "\$HYDRA_ROOT set" "$HYDRA_ROOT"
  else
    check_warn "\$HYDRA_ROOT set" "unset; setup.sh writes it to .hydra.env — launcher sources it"
  fi

  if [[ -n "${HYDRA_EXTERNAL_MEMORY_DIR:-}" ]]; then
    check_pass "\$HYDRA_EXTERNAL_MEMORY_DIR set" "$HYDRA_EXTERNAL_MEMORY_DIR"
  else
    check_warn "\$HYDRA_EXTERNAL_MEMORY_DIR set" "unset; will fall back to ./memory/ (OK for Phase 1)"
  fi

  # External memory dir exists + writable
  local ext_mem="${HYDRA_EXTERNAL_MEMORY_DIR:-}"
  if [[ -n "$ext_mem" ]]; then
    if [[ -d "$ext_mem" ]]; then
      if [[ -w "$ext_mem" ]]; then
        check_pass "external memory dir exists + writable" "$ext_mem"
      else
        check_fail "external memory dir writable" "$ext_mem is not writable"
      fi
    else
      if [[ "$fix_safe" -eq 1 ]]; then
        if mkdir -p "$ext_mem" 2>/dev/null; then
          check_pass "external memory dir created" "$ext_mem (--fix-safe)"
        else
          check_fail "external memory dir exists" "$ext_mem does not exist and mkdir failed"
        fi
      else
        check_fail "external memory dir exists" "$ext_mem does not exist (rerun with --fix-safe or mkdir manually)"
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
      check_fail ".claude/settings.local.json valid JSON" "parse error"
    fi
  else
    check_fail ".claude/settings.local.json exists" "run ./setup.sh to create it"
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
          "no Edit(...CLAUDE.md) entry found in .claude/settings.local.json deny list"
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
        check_warn "state/repos.json has ≥1 enabled repo" "0 enabled — edit state/repos.json"
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
              check_fail "repo local_path has .git/" "$p exists but is not a git repo"
            fi
          else
            check_fail "repo local_path exists" "$p does not exist"
          fi
        done <<< "$paths"
      fi
    else
      check_fail "state/repos.json valid JSON" "parse error"
    fi
  else
    check_fail "state/repos.json exists" "run ./setup.sh; edit to list your repos"
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
        check_fail "budget.json sane" "max_concurrent_workers out of [1,20]: got '$mcw'"
      fi
    else
      check_fail "budget.json valid JSON" "parse error"
    fi
  else
    check_fail "budget.json exists" "missing"
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
        check_fail "$f valid JSON" "parse error"
      fi
    else
      check_fail "$f exists" "run ./setup.sh"
    fi
  done

  # PAUSE file
  if [[ -f "$ROOT_DIR/PAUSE" ]] || [[ -f "$ROOT_DIR/commander/PAUSE" ]]; then
    check_warn "no unexpected PAUSE file" "PAUSE present — commander will refuse to spawn"
  else
    check_pass "no PAUSE file"
  fi

  # logs/ writable
  local logs="$ROOT_DIR/logs"
  if [[ -d "$logs" ]]; then
    if [[ -w "$logs" ]]; then
      check_pass "logs/ writable"
    else
      check_fail "logs/ writable" "not writable"
    fi
  else
    if [[ "$fix_safe" -eq 1 ]]; then
      if mkdir -p "$logs" 2>/dev/null; then
        check_pass "logs/ created" "$logs (--fix-safe)"
      else
        check_fail "logs/ exists" "mkdir failed"
      fi
    else
      check_warn "logs/ exists" "missing (rerun with --fix-safe or mkdir logs)"
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
    check_fail "memory/MEMORY.md exists" "missing (framework file — reinstall or git checkout)"
  fi

  # validate-learning-entry.sh against every learnings-*.md
  local validator="$ROOT_DIR/scripts/validate-learning-entry.sh"
  if [[ -x "$validator" ]]; then
    shopt -s nullglob
    local learning_files=("$ROOT_DIR/memory/"learnings-*.md)
    local ext_mem="${HYDRA_EXTERNAL_MEMORY_DIR:-}"
    if [[ -n "$ext_mem" ]] && [[ -d "$ext_mem" ]]; then
      local ext_learnings=("$ext_mem/"learnings-*.md)
      learning_files+=("${ext_learnings[@]}")
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
          check_fail "validate-learning-entry.sh on $(basename "$f")" "failed"
          bad=1
        fi
      done
      if [[ "$bad" -eq 0 ]]; then
        check_pass "validate-learning-entry.sh" "${#learning_files[@]} file(s) valid"
      fi
    fi
  else
    check_warn "scripts/validate-learning-entry.sh executable" "missing or not executable"
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
        check_fail "validate-citations.sh on memory-citations.json" "stale or invalid entries"
      fi
    fi
  elif [[ ! -x "$cite_validator" ]]; then
    check_warn "scripts/validate-citations.sh executable" "missing or not executable"
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
      check_fail "bash -n $(basename "$f")" "syntax error"
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
    if [[ "$fix_safe" -eq 1 ]]; then
      local nf
      for nf in "${not_exec[@]}"; do
        chmod +x "$nf" 2>/dev/null || true
      done
      check_pass "scripts executable (+x)" "chmod +x applied to ${#not_exec[@]} file(s) (--fix-safe)"
    else
      check_warn "scripts executable (+x)" "${#not_exec[@]} not executable (rerun with --fix-safe)"
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
        check_fail "validate-state.sh on $base.json" "failed"
        any_fail=1
      fi
    done
    if [[ "$any_fail" -eq 0 ]]; then
      check_pass "validate-state.sh" "$checked state file(s) pass schema check"
    fi
  else
    check_warn "scripts/validate-state.sh executable" "missing"
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
            "state/linear.json:enabled=true but 'claude mcp list' shows no linear entry; run 'claude mcp add linear'"
        fi
      else
        check_warn "Linear MCP check" "claude CLI missing, cannot verify"
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
      check_fail "mount-s3 installed" "HYDRA_STATE_BACKEND=dynamodb but mount-s3 not on PATH"
    fi

    if command -v aws >/dev/null 2>&1; then
      if aws sts get-caller-identity >/dev/null 2>&1; then
        check_pass "AWS credentials configured"
      else
        check_fail "AWS credentials configured" "aws sts get-caller-identity failed"
      fi
    else
      check_fail "aws CLI on PATH" "HYDRA_STATE_BACKEND=dynamodb but aws CLI missing"
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
    check_fail "./self-test/run.sh executable" "missing or not +x"
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
    check_fail "./self-test/run.sh --kind=script" "one or more script cases failed"
    if [[ "$verbose" -eq 1 ]] || [[ -s "$tmp" ]]; then
      echo "    ${C_DIM}--- self-test output ---${C_RESET}"
      sed 's/^/    /' "$tmp"
    fi
  fi
  rm -f "$tmp"
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

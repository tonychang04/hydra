#!/usr/bin/env bash
#
# test-local-config.sh — validate local-mode install artifacts work.
#
# What it does:
#   1. Creates a tmp HYDRA_ROOT (mktemp -d).
#   2. Copies the committed framework files into it.
#   3. Runs ./setup.sh non-interactively (empty stdin → accept default external
#      memory dir).
#   4. Verifies generated `.hydra.env` has HYDRA_ROOT, HYDRA_EXTERNAL_MEMORY_DIR,
#      and COMMANDER_ROOT.
#   5. Verifies state/repos.json is valid JSON after the template copy.
#   6. Verifies ./hydra launcher exists, is executable, and `bash -n` passes.
#   7. Tears the tmp down.
#
# Requires `claude` CLI on PATH — setup.sh hard-fails without it. Without
# `claude`, the script exits 0 with a clear SKIP message (consistent with the
# `requires_claude_cli` pattern used in self-test/run.sh).
#
# Intended for:
#   - operator pre-push sanity before touching setup.sh / install.sh
#   - CI gates (alongside self-test/run.sh --kind=script)
#   - any agent editing the local-mode install flow
#
# Does NOT touch the live worktree. Everything happens in the tmp dir.
#
# Spec: docs/specs/2026-04-16-dual-mode-workflow.md (ticket #51)

set -euo pipefail

# -----------------------------------------------------------------------------
# resolve worktree root (script lives at <root>/scripts/test-local-config.sh)
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
Usage: scripts/test-local-config.sh [options]

Validates that local-mode install artifacts (setup.sh, .hydra.env template,
state/repos.json seeding, ./hydra launcher) produce a usable tree when run
against a fresh tmp directory. Does NOT touch the live worktree.

Options:
  --verbose    Print raw command output on each check
  -h, --help   Show this help

Exit codes:
  0   all checks passed, or claude CLI unavailable (graceful skip)
  1   one or more checks failed
  2   usage error
EOF
}

verbose=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --verbose) verbose=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "test-local-config: unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

say()  { printf "\n${C_BOLD}▸ %s${C_RESET}\n" "$*"; }
ok()   { printf "${C_GREEN}✓${C_RESET} %s\n" "$*"; }
skip() { printf "${C_YELLOW}∅${C_RESET} %s ${C_DIM}(SKIP: %s)${C_RESET}\n" "$1" "$2"; }
fail() { printf "${C_RED}✗${C_RESET} %s\n" "$*"; }

passed=0
failed=0

note_pass() { ok "$1"; passed=$((passed + 1)); }
note_fail() { fail "$1"; failed=$((failed + 1)); }

# -----------------------------------------------------------------------------
# Prereq: claude CLI. Without it, setup.sh hard-fails — no point running.
# -----------------------------------------------------------------------------
say "Hydra local-config smoke test"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

if ! command -v claude >/dev/null 2>&1; then
  skip "entire suite" "claude CLI not on PATH (setup.sh hard-fails without it)"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  printf "${C_BOLD}0 passed · 0 failed · 1 skipped${C_RESET}\n"
  exit 0
fi

if ! command -v gh >/dev/null 2>&1 || ! gh auth status >/dev/null 2>&1; then
  skip "entire suite" "gh CLI not on PATH or not authenticated (setup.sh hard-fails)"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  printf "${C_BOLD}0 passed · 0 failed · 1 skipped${C_RESET}\n"
  exit 0
fi

# -----------------------------------------------------------------------------
# Stage a tmp HYDRA_ROOT with everything setup.sh needs.
# -----------------------------------------------------------------------------
TMP_ROOT="$(mktemp -d -t hydra-test-local-XXXXXX)"
TMP_MEM="$(mktemp -d -t hydra-test-mem-XXXXXX)"
trap 'rm -rf "$TMP_ROOT" "$TMP_MEM"' EXIT

say "Staging tmp HYDRA_ROOT at $TMP_ROOT"

# Copy the minimum set of files/dirs setup.sh reads.
# setup.sh needs: setup.sh itself, .claude/settings.local.json.example,
# state/repos.example.json, and the state/ dir structure.
cp "$ROOT_DIR/setup.sh" "$TMP_ROOT/"
mkdir -p "$TMP_ROOT/.claude" "$TMP_ROOT/state"
cp "$ROOT_DIR/.claude/settings.local.json.example" "$TMP_ROOT/.claude/"
cp "$ROOT_DIR/state/repos.example.json" "$TMP_ROOT/state/"

chmod +x "$TMP_ROOT/setup.sh"

say "Running setup.sh in the tmp root (non-interactive, external mem → $TMP_MEM)"

# Pipe the external-memory path, then an empty line to accept any further prompts.
# setup.sh only has ONE prompt today, but we pad to be safe.
if [[ "$verbose" -eq 1 ]]; then
  ( cd "$TMP_ROOT" && printf '%s\n\n' "$TMP_MEM" | bash setup.sh ) || {
    note_fail "setup.sh in tmp root"
  }
else
  ( cd "$TMP_ROOT" && printf '%s\n\n' "$TMP_MEM" | bash setup.sh >/dev/null 2>&1 ) || {
    note_fail "setup.sh in tmp root (re-run with --verbose for output)"
  }
fi

if [[ -f "$TMP_ROOT/.hydra.env" ]]; then
  note_pass "setup.sh produced .hydra.env"
else
  note_fail "setup.sh did NOT produce .hydra.env"
fi

# ---------- check .hydra.env has required vars ----------
check_env_var() {
  local var="$1"
  if grep -qE "^export ${var}=" "$TMP_ROOT/.hydra.env"; then
    note_pass ".hydra.env exports ${var}"
  else
    note_fail ".hydra.env missing export ${var}"
  fi
}

if [[ -f "$TMP_ROOT/.hydra.env" ]]; then
  check_env_var HYDRA_ROOT
  check_env_var HYDRA_EXTERNAL_MEMORY_DIR
  check_env_var COMMANDER_ROOT
fi

# ---------- state/repos.json valid JSON ----------
if [[ -f "$TMP_ROOT/state/repos.json" ]]; then
  if jq empty "$TMP_ROOT/state/repos.json" 2>/dev/null; then
    note_pass "state/repos.json is valid JSON after template copy"
  else
    note_fail "state/repos.json is NOT valid JSON"
  fi
else
  note_fail "state/repos.json was not seeded by setup.sh"
fi

# ---------- ./hydra launcher ----------
if [[ -f "$TMP_ROOT/hydra" ]]; then
  note_pass "./hydra launcher exists"
  if [[ -x "$TMP_ROOT/hydra" ]]; then
    note_pass "./hydra launcher is executable"
  else
    note_fail "./hydra launcher is NOT executable"
  fi
  if bash -n "$TMP_ROOT/hydra" 2>/dev/null; then
    note_pass "./hydra launcher passes bash -n"
  else
    note_fail "./hydra launcher has syntax errors"
  fi
else
  note_fail "./hydra launcher not generated by setup.sh"
fi

# ---------- autopickup state ----------
if [[ -f "$TMP_ROOT/state/autopickup.json" ]]; then
  if jq empty "$TMP_ROOT/state/autopickup.json" 2>/dev/null; then
    note_pass "state/autopickup.json is valid JSON"
  else
    note_fail "state/autopickup.json is NOT valid JSON"
  fi
fi

# ---------- summary ----------
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
printf "${C_BOLD}%d passed · %d failed${C_RESET}\n" "$passed" "$failed"

if [[ "$failed" -gt 0 ]]; then
  exit 1
fi
exit 0

#!/usr/bin/env bash
#
# test-cloud-config.sh — validate cloud-mode deployment artifacts without
# actually deploying.
#
# What it does:
#   1. `fly config validate --config infra/fly.toml`   (skipped if no flyctl)
#   2. `docker build infra/ -t hydra-test --no-cache`  (skipped if no docker
#      OR if HYDRA_CI_SKIP_DOCKER=1 is set)
#   3. `shellcheck` on scripts/deploy-vps.sh + infra/entrypoint.sh
#      (skipped if no shellcheck)
#   4. `jq empty` on state/connectors/mcp.json.example + mcp/hydra-tools.json
#   5. `bash -n` on every shell script under scripts/ and infra/
#
# Exit 0 only if every available check passes. Skipped checks do NOT fail.
#
# Intended for:
#   - operator pre-push sanity ("did I break the Fly.io artifacts?")
#   - CI gates (alongside self-test/run.sh --kind=script)
#   - any agent dispatching a PR touching infra/ or mcp/
#
# Spec: docs/specs/2026-04-16-dual-mode-workflow.md (ticket #51)

set -euo pipefail

# -----------------------------------------------------------------------------
# resolve worktree root (script lives at <root>/scripts/test-cloud-config.sh)
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
Usage: scripts/test-cloud-config.sh [options]

Validates cloud-mode deployment artifacts (Dockerfile, fly.toml, entrypoint,
deploy script, MCP config) without actually deploying.

Options:
  --verbose    Print raw command output on each check
  -h, --help   Show this help

Environment:
  HYDRA_CI_SKIP_DOCKER=1   Skip the `docker build` check (CI fast-path, also
                           respected by self-test/run.sh)
  NO_COLOR=1               Disable colored output

Exit codes:
  0   all checks passed or were skipped for missing prereqs
  1   one or more checks failed
  2   usage error
EOF
}

verbose=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --verbose) verbose=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "test-cloud-config: unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

say()  { printf "\n${C_BOLD}▸ %s${C_RESET}\n" "$*"; }
ok()   { printf "${C_GREEN}✓${C_RESET} %s\n" "$*"; }
skip() { printf "${C_YELLOW}∅${C_RESET} %s ${C_DIM}(SKIP: %s)${C_RESET}\n" "$1" "$2"; }
warn() { printf "${C_YELLOW}⚠${C_RESET} %s\n" "$*"; }
fail() { printf "${C_RED}✗${C_RESET} %s\n" "$*"; }

cd "$ROOT_DIR"

passed=0
failed=0
skipped=0

# Run a check. Caller passes: name, skip-if-missing-cmd (or empty), skip-reason, then the command.
# If skip-if-missing-cmd is non-empty and not found, the check skips.
run_check() {
  local name="$1"; shift
  local cmd
  local tmp_stdout tmp_stderr ec
  tmp_stdout="$(mktemp)"
  tmp_stderr="$(mktemp)"
  set +e
  ( "$@" ) >"$tmp_stdout" 2>"$tmp_stderr"
  ec=$?
  set -e

  if [[ "$ec" -eq 0 ]]; then
    ok "$name"
    if [[ "$verbose" -eq 1 ]] && [[ -s "$tmp_stdout" ]]; then
      sed 's/^/    /' "$tmp_stdout"
    fi
    passed=$((passed + 1))
  else
    fail "$name (exit $ec)"
    if [[ -s "$tmp_stdout" ]]; then
      printf "  ${C_DIM}--- stdout ---${C_RESET}\n"
      sed 's/^/  /' "$tmp_stdout"
    fi
    if [[ -s "$tmp_stderr" ]]; then
      printf "  ${C_DIM}--- stderr ---${C_RESET}\n"
      sed 's/^/  /' "$tmp_stderr"
    fi
    failed=$((failed + 1))
  fi

  rm -f "$tmp_stdout" "$tmp_stderr"
}

mark_skip() {
  skip "$1" "$2"
  skipped=$((skipped + 1))
}

say "Hydra cloud-config smoke test"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# ---------- 1. fly config validate ----------
if command -v fly >/dev/null 2>&1; then
  run_check "fly config validate --config infra/fly.toml" \
    fly config validate --config infra/fly.toml
else
  mark_skip "fly config validate" "flyctl (fly) not on PATH"
fi

# ---------- 2. docker build ----------
if [[ "${HYDRA_CI_SKIP_DOCKER:-0}" == "1" ]]; then
  mark_skip "docker build infra/" "HYDRA_CI_SKIP_DOCKER=1 (CI fast-path)"
elif ! command -v docker >/dev/null 2>&1; then
  mark_skip "docker build infra/" "docker not on PATH"
elif ! docker info >/dev/null 2>&1; then
  mark_skip "docker build infra/" "docker daemon not reachable"
else
  # Use the Dockerfile location explicitly so the build context is the repo root
  # (infra/Dockerfile references `COPY . /hydra/` which needs the full tree).
  run_check "docker build -f infra/Dockerfile . (no-cache)" \
    docker build -f infra/Dockerfile -t hydra-test --no-cache .
fi

# ---------- 3. shellcheck ----------
if command -v shellcheck >/dev/null 2>&1; then
  run_check "shellcheck scripts/deploy-vps.sh infra/entrypoint.sh" \
    shellcheck scripts/deploy-vps.sh infra/entrypoint.sh
else
  mark_skip "shellcheck" "shellcheck not on PATH"
fi

# ---------- 4. jq empty on JSON configs ----------
run_check "jq empty state/connectors/mcp.json.example" \
  jq empty state/connectors/mcp.json.example
run_check "jq empty mcp/hydra-tools.json" \
  jq empty mcp/hydra-tools.json

# ---------- 5. bash -n on every shell script ----------
# Collect all .sh files under scripts/ + infra/ and run bash -n on each.
bash_n_errors=0
bash_n_checked=0
while IFS= read -r script_path; do
  [[ -z "$script_path" ]] && continue
  bash_n_checked=$((bash_n_checked + 1))
  if ! bash -n "$script_path" 2>/dev/null; then
    fail "bash -n $script_path"
    bash_n_errors=$((bash_n_errors + 1))
  fi
done < <(
  {
    find scripts -maxdepth 2 -type f -name '*.sh' 2>/dev/null || true
    find infra   -maxdepth 2 -type f -name '*.sh' 2>/dev/null || true
  } | sort -u
)

if [[ "$bash_n_errors" -eq 0 ]]; then
  ok "bash -n on all shell scripts (${bash_n_checked} files)"
  passed=$((passed + 1))
else
  fail "bash -n found ${bash_n_errors} syntax errors across ${bash_n_checked} scripts"
  failed=$((failed + 1))
fi

# ---------- summary ----------
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
printf "${C_BOLD}%d passed · %d failed · %d skipped${C_RESET}\n" \
  "$passed" "$failed" "$skipped"

if [[ "$failed" -gt 0 ]]; then
  exit 1
fi
exit 0

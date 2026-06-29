#!/usr/bin/env bash
#
# e2e-cloud-acceptance.sh — the ONE acceptance test that proves Hydra's north
# star: "the machine runs while the operator sleeps." Scripts the full
# "assign a ticket, go offline, wake up to a merged PR" loop in cloud mode.
#
# Nine steps (each fails loudly with `step N: expected X, got Y`):
#   1. Fresh Fly deploy against the hello-hydra-demo fixture repo.
#   2. Register an MCP bearer (./hydra mcp register-agent).
#   3. Enable autopickup on the cloud commander.
#   4. Assign fixture issue #1 to the bot (honoring #26 assignee_override).
#   5. Disconnect — the operator simulator goes offline.
#   6. Wait for the autopickup tick to fire (clamped via HYDRA_FAKE_NOW).
#   7. Poll for PR creation (or the commander review-gate label).
#   8. Reconnect — verify PR exists, CI green, commander-review-clean applied.
#   9. Flip to T1 auto-merge and confirm the PR auto-merged.
#
# Exits 0 only if the full loop succeeds.
#
# --dry-run validates the whole script end-to-end against a MOCKED Fly API +
# mocked GitHub state machine, with ZERO real side effects (no real fly / gh /
# curl / ./hydra invocation, no lingering infra). The dry-run is what CI/self-test
# exercises; a real run depends on prereqs (#119 fly-deploy, #123 launcher
# regen, #115 memory-sync) that are out of scope for this build.
#
# Style mirrors scripts/hydra-migrate-to-cloud.sh (the closest analog): same
# say/ok/warn/fail/dim/dry helpers, same FLY_BIN dispatch, same "log-don't-exec
# in dry-run" discipline.
#
# Usage:
#   scripts/e2e-cloud-acceptance.sh --dry-run            # rehearse; no side effects
#   scripts/e2e-cloud-acceptance.sh --fly-app NAME       # real run (needs prereqs)
#   scripts/e2e-cloud-acceptance.sh --help
#
# Spec: docs/specs/2026-04-17-e2e-cloud-acceptance.md (ticket #127)

set -euo pipefail

HYDRA_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$HYDRA_ROOT"

# ---------- defaults / flags ----------
DRY_RUN=0
KEEP=0
FLY_APP="${HYDRA_FLY_APP:-}"
MAIN_AGENT_ID="${HYDRA_MAIN_AGENT_ID:-main-agent}"
TARGET_REPO="${HYDRA_E2E_REPO:-}"           # owner/name of the fixture repo
FIXTURE_ISSUE="${HYDRA_E2E_ISSUE:-1}"        # which fixture issue to assign
BOT_ASSIGNEE="${HYDRA_E2E_ASSIGNEE:-@me}"    # honors #26 assignee_override
TICK_INTERVAL="${HYDRA_E2E_TICK_INTERVAL:-5}"   # seconds; clamps the tick wait
POLL_TIMEOUT="${HYDRA_E2E_POLL_TIMEOUT:-300}"   # seconds; max poll for the PR
POLL_INTERVAL="${HYDRA_E2E_POLL_INTERVAL:-5}"   # seconds between polls

usage() {
  cat <<'EOF'
Usage: scripts/e2e-cloud-acceptance.sh [options]

The cloud acceptance test: scripts the full "assign ticket, go offline, wake up
to a merged PR" loop and exits 0 only if every one of the 9 steps succeeds.

Options:
  --dry-run             Rehearse the whole loop against a mocked Fly API + mocked
                        GitHub state machine. ZERO real side effects: no fly / gh
                        / curl / ./hydra invocation, no lingering infrastructure.
                        This is the mode CI and the self-test exercise.
  --fly-app NAME        Fly app name for a real run (or set HYDRA_FLY_APP).
  --repo OWNER/NAME     Target fixture repo (default: hello-hydra-demo wiring).
  --issue N             Fixture issue number to assign (default: 1).
  --assignee WHO        Assignee for step 4 (default: @me; honors #26 override).
  --tick-interval SEC   Clamp for the "wait for tick" step (default: 5).
  --poll-timeout SEC    Max seconds to poll for the PR (default: 300).
  --keep                Real mode: do NOT tear down the Fly app on exit.
  -h, --help            Show this help.

Environment:
  HYDRA_FAKE_NOW        Deterministic clock for the tick-wait step (epoch or
                        ISO-8601). Used by dry-run so no real multi-minute sleep
                        is needed; also clamps the real-mode poll window.
  HYDRA_FLY_APP         Same as --fly-app.
  NO_COLOR=1            Disable colored output.

Exit codes:
  0   the full 9-step loop succeeded (real) or the dry-run finished cleanly
  1   a step failed (message names the step + expected vs actual)
  2   usage error (unknown flag / bad value)
  3   real-run prerequisite missing (fly / gh / curl / infra/fly.toml; or the
      out-of-scope prereqs #119 / #123 / #115 are not in place)

Spec: docs/specs/2026-04-17-e2e-cloud-acceptance.md (ticket #127)
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)        usage; exit 0 ;;
    --dry-run)        DRY_RUN=1; shift ;;
    --keep)           KEEP=1; shift ;;
    --fly-app)        [[ $# -ge 2 ]] || { echo "✗ --fly-app needs a value" >&2; exit 2; }; FLY_APP="$2"; shift 2 ;;
    --fly-app=*)      FLY_APP="${1#--fly-app=}"; shift ;;
    --repo)           [[ $# -ge 2 ]] || { echo "✗ --repo needs a value" >&2; exit 2; }; TARGET_REPO="$2"; shift 2 ;;
    --repo=*)         TARGET_REPO="${1#--repo=}"; shift ;;
    --issue)          [[ $# -ge 2 ]] || { echo "✗ --issue needs a value" >&2; exit 2; }; FIXTURE_ISSUE="$2"; shift 2 ;;
    --issue=*)        FIXTURE_ISSUE="${1#--issue=}"; shift ;;
    --assignee)       [[ $# -ge 2 ]] || { echo "✗ --assignee needs a value" >&2; exit 2; }; BOT_ASSIGNEE="$2"; shift 2 ;;
    --assignee=*)     BOT_ASSIGNEE="${1#--assignee=}"; shift ;;
    --tick-interval)  [[ $# -ge 2 ]] || { echo "✗ --tick-interval needs a value" >&2; exit 2; }; TICK_INTERVAL="$2"; shift 2 ;;
    --tick-interval=*) TICK_INTERVAL="${1#--tick-interval=}"; shift ;;
    --poll-timeout)   [[ $# -ge 2 ]] || { echo "✗ --poll-timeout needs a value" >&2; exit 2; }; POLL_TIMEOUT="$2"; shift 2 ;;
    --poll-timeout=*) POLL_TIMEOUT="${1#--poll-timeout=}"; shift ;;
    *) echo "✗ Unknown arg: $1" >&2; usage >&2; exit 2 ;;
  esac
done

# ---------- color / TTY ----------
if [[ -t 1 ]] && [[ "${NO_COLOR:-}" != "1" ]]; then
  C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'; C_RED=$'\033[31m'
  C_BLUE=$'\033[34m';  C_BOLD=$'\033[1m';    C_DIM=$'\033[2m'; C_RESET=$'\033[0m'
else
  C_GREEN=""; C_YELLOW=""; C_RED=""; C_BLUE=""; C_BOLD=""; C_DIM=""; C_RESET=""
fi

say()  { printf "\n%s▸ %s%s\n" "$C_BOLD" "$*" "$C_RESET"; }
ok()   { printf "  %s✓%s %s\n" "$C_GREEN"  "$C_RESET" "$*"; }
warn() { printf "  %s⚠%s %s\n" "$C_YELLOW" "$C_RESET" "$*"; }
dim()  { printf "    %s%s%s\n" "$C_DIM" "$*" "$C_RESET"; }
dry()  { printf "  %sDRY RUN:%s %s\n" "$C_BLUE" "$C_RESET" "$*"; }

# Hard preflight failure (NOT a per-step assertion failure).
die() { printf "  %s✗%s %s\n" "$C_RED" "$C_RESET" "$*" >&2; exit "${2:-1}"; }

# ---------- placeholder: full step implementation lands in the next commit ----------
say "Hydra cloud acceptance test (skeleton)"
if [[ "$DRY_RUN" -eq 1 ]]; then
  dim "(--dry-run: mocked Fly API + GitHub state machine; zero side effects)"
  ok "skeleton dry-run reached — step orchestration lands in the next commit"
  exit 0
fi
die "real mode not wired in the skeleton commit — use --dry-run for now" 3

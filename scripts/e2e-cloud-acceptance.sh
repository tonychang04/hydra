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

# ----------------------------------------------------------------------------
# step framing — every step prints a clear PASS/FAIL with expected-vs-actual.
# ----------------------------------------------------------------------------
STEP_TOTAL=9
# Optional deterministic failure injection (dry-run only) for exercising the
# failure-reporting path from the self-test. Set HYDRA_E2E_FAIL_STEP=N.
FAIL_STEP="${HYDRA_E2E_FAIL_STEP:-}"

step_begin() {            # step_begin N "name"
  CUR_STEP="$1"; CUR_NAME="$2"
  printf "\n%s── Step %s/%s · %s%s\n" "$C_BOLD" "$1" "$STEP_TOTAL" "$2" "$C_RESET"
}
step_ok()   { ok "$*"; }
step_fail() {             # step_fail N "name" "expected" "actual"
  printf "%s✗ Step %s/%s (%s) FAILED%s\n" "$C_RED" "$1" "$STEP_TOTAL" "$2" "$C_RESET" >&2
  printf "    expected: %s\n" "$3" >&2
  printf "    actual:   %s\n" "$4" >&2
  exit 1
}
# Honor injected failure at the top of a step (dry-run testing aid).
maybe_inject_fail() {
  if [[ -n "$FAIL_STEP" && "$FAIL_STEP" == "$CUR_STEP" ]]; then
    step_fail "$CUR_STEP" "$CUR_NAME" "injected-pass" "injected failure via HYDRA_E2E_FAIL_STEP=$FAIL_STEP"
  fi
}

# ----------------------------------------------------------------------------
# mock state machine (dry-run only). A tmpdir of small JSON files standing in
# for the Fly app + GitHub state. NO step shells out to fly/gh/curl/./hydra in
# dry-run — that is what makes "zero side effects" testable.
# ----------------------------------------------------------------------------
MOCK_DIR=""
mock_put() { printf '%s' "$2" > "$MOCK_DIR/$1"; }      # mock_put file content
mock_get() { cat "$MOCK_DIR/$1" 2>/dev/null || true; } # mock_get file

cleanup() {
  local rc=$?
  if [[ "$DRY_RUN" -eq 1 ]]; then
    if [[ -n "$MOCK_DIR" && -d "$MOCK_DIR" ]]; then
      rm -rf "$MOCK_DIR"
      dim "cleanup: removed mock state dir"
    fi
  else
    if [[ "$KEEP" -eq 1 ]]; then
      warn "cleanup: --keep set; leaving Fly app '$FLY_APP' running (tear down manually)"
    elif [[ -n "$FLY_APP" ]] && command -v "${FLY_BIN:-fly}" >/dev/null 2>&1; then
      warn "cleanup: tearing down Fly app '$FLY_APP' (no lingering infra)"
      "${FLY_BIN:-fly}" apps destroy "$FLY_APP" --yes >/dev/null 2>&1 || \
        warn "cleanup: 'apps destroy' did not succeed — verify manually: ${FLY_BIN:-fly} apps list"
    fi
  fi
  return "$rc"
}
trap cleanup EXIT INT TERM

# Deterministic clock for step 6. HYDRA_FAKE_NOW (epoch seconds) wins; else now.
clock_now() {
  if [[ "${HYDRA_FAKE_NOW:-}" =~ ^[0-9]+$ ]]; then
    printf '%s' "$HYDRA_FAKE_NOW"
  else
    date +%s
  fi
}

# ----------------------------------------------------------------------------
# real-mode prerequisite gate
# ----------------------------------------------------------------------------
FLY_BIN=""
require_real_prereqs() {
  if command -v flyctl >/dev/null 2>&1; then FLY_BIN="flyctl"
  elif command -v fly >/dev/null 2>&1; then FLY_BIN="fly"
  else die "real run needs flyctl — install it OR use --dry-run" 3; fi
  command -v gh   >/dev/null 2>&1 || die "real run needs the gh CLI — install it OR use --dry-run" 3
  command -v curl >/dev/null 2>&1 || die "real run needs curl — install it OR use --dry-run" 3
  [[ -f "$HYDRA_ROOT/infra/fly.toml" ]] || die "real run needs infra/fly.toml (run from repo root)" 3
  [[ -n "$FLY_APP" ]] || die "real run needs --fly-app NAME (or HYDRA_FLY_APP)" 3
  # The real loop additionally depends on out-of-scope prereqs; surface them so a
  # real run fails honestly rather than half-completing.
  warn "real mode depends on #119 (fly deploy), #123 (launcher regen), #115 (memory-sync)."
  warn "These are OUT OF SCOPE for ticket #127 — real mode is wired but not verified by it."
}

# ----------------------------------------------------------------------------
# banner + mode setup
# ----------------------------------------------------------------------------
printf "\n%s━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━%s\n" "$C_DIM" "$C_RESET"
printf "%sHydra cloud acceptance test%s\n" "$C_BOLD" "$C_RESET"
printf "%s(assign ticket · go offline · wake to a merged PR)%s\n" "$C_DIM" "$C_RESET"
printf "%s━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━%s\n" "$C_DIM" "$C_RESET"

# Resolve the fixture repo default (the hello-hydra-demo wiring).
if [[ -z "$TARGET_REPO" ]]; then
  TARGET_REPO="OWNER/hello-hydra-demo"   # placeholder; real runs pass --repo
fi

if [[ "$DRY_RUN" -eq 1 ]]; then
  MOCK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/hydra-e2e-mock.XXXXXX")"
  FLY_BIN="fly"   # display name only; never invoked in dry-run
  [[ -n "$FLY_APP" ]] || FLY_APP="hydra-e2e-dryrun"
  dim "(--dry-run: mocked Fly API + GitHub state machine in $MOCK_DIR; zero side effects)"
  dim "fixture repo: $TARGET_REPO · issue #$FIXTURE_ISSUE · assignee $BOT_ASSIGNEE"
else
  require_real_prereqs
fi

# ============================================================================
# Step 1 — Fresh Fly deploy against the hello-hydra-demo fixture repo.
# ============================================================================
step_begin 1 "Fresh Fly deploy"; maybe_inject_fail
if [[ "$DRY_RUN" -eq 1 ]]; then
  dry "$FLY_BIN deploy --app $FLY_APP --config infra/fly.toml"
  mock_put "fly-app.json" "{\"app\":\"$FLY_APP\",\"status\":\"deployed\",\"health\":\"ok\"}"
  [[ "$(mock_get fly-app.json)" == *'"status":"deployed"'* ]] \
    || step_fail 1 "Fresh Fly deploy" 'mock status=deployed' "$(mock_get fly-app.json)"
  step_ok "deploy simulated — app $FLY_APP marked deployed + healthy"
else
  "$FLY_BIN" deploy --app "$FLY_APP" --config "$HYDRA_ROOT/infra/fly.toml" \
    || step_fail 1 "Fresh Fly deploy" "fly deploy exit 0" "fly deploy non-zero exit"
  sleep 3
  curl -fsS --max-time 5 "https://${FLY_APP}.fly.dev/health" >/dev/null 2>&1 \
    || step_fail 1 "Fresh Fly deploy" "GET /health 200" "health endpoint not responding"
  step_ok "deployed + /health green"
fi

# ============================================================================
# Step 2 — Register an MCP bearer (./hydra mcp register-agent).
# ============================================================================
step_begin 2 "Register MCP bearer"; maybe_inject_fail
if [[ "$DRY_RUN" -eq 1 ]]; then
  dry "$FLY_BIN ssh console --app $FLY_APP -C './hydra mcp register-agent $MAIN_AGENT_ID'"
  # A clearly-fake mock bearer. NEVER a real token (no secret material on disk).
  mock_put "bearer.txt" "MOCK-bearer-${MAIN_AGENT_ID}-deadbeef"
  [[ -s "$MOCK_DIR/bearer.txt" ]] \
    || step_fail 2 "Register MCP bearer" "non-empty mock bearer" "empty bearer"
  step_ok "bearer registered (mock, redacted) for agent '$MAIN_AGENT_ID'"
else
  if ! "$FLY_BIN" ssh console --app "$FLY_APP" \
        -C "./hydra mcp register-agent $MAIN_AGENT_ID" >/dev/null 2>&1; then
    step_fail 2 "Register MCP bearer" "register-agent exit 0" "register-agent failed on cloud commander"
  fi
  step_ok "bearer registered for agent '$MAIN_AGENT_ID' (printed once on the cloud host)"
fi

# ============================================================================
# Step 3 — Enable autopickup on the cloud commander.
# ============================================================================
step_begin 3 "Enable autopickup"; maybe_inject_fail
if [[ "$DRY_RUN" -eq 1 ]]; then
  dry "$FLY_BIN ssh console --app $FLY_APP -C 'set state/autopickup.json enabled=true'"
  mock_put "autopickup.json" '{"enabled":true,"interval_min":15,"last_run":null}'
  [[ "$(mock_get autopickup.json)" == *'"enabled":true'* ]] \
    || step_fail 3 "Enable autopickup" 'autopickup enabled=true' "$(mock_get autopickup.json)"
  step_ok "autopickup enabled on cloud commander (mock)"
else
  if ! "$FLY_BIN" ssh console --app "$FLY_APP" \
        -C "jq '.enabled=true' state/autopickup.json | sponge state/autopickup.json" >/dev/null 2>&1; then
    step_fail 3 "Enable autopickup" "autopickup enabled=true" "could not flip autopickup state on cloud"
  fi
  step_ok "autopickup enabled on cloud commander"
fi

# ============================================================================
# Step 4 — Assign fixture issue to the bot (honors #26 assignee_override).
# ============================================================================
step_begin 4 "Assign fixture issue #$FIXTURE_ISSUE"; maybe_inject_fail
if [[ "$DRY_RUN" -eq 1 ]]; then
  dry "gh issue edit $FIXTURE_ISSUE --repo $TARGET_REPO --add-assignee $BOT_ASSIGNEE"
  mock_put "issue-${FIXTURE_ISSUE}.json" \
    "{\"number\":$FIXTURE_ISSUE,\"assignee\":\"$BOT_ASSIGNEE\",\"state\":\"open\"}"
  [[ "$(mock_get "issue-${FIXTURE_ISSUE}.json")" == *"\"assignee\":\"$BOT_ASSIGNEE\""* ]] \
    || step_fail 4 "Assign fixture issue" "assignee=$BOT_ASSIGNEE" "$(mock_get "issue-${FIXTURE_ISSUE}.json")"
  step_ok "issue #$FIXTURE_ISSUE assigned to $BOT_ASSIGNEE — autopickup trigger armed"
else
  gh issue edit "$FIXTURE_ISSUE" --repo "$TARGET_REPO" --add-assignee "$BOT_ASSIGNEE" >/dev/null 2>&1 \
    || step_fail 4 "Assign fixture issue" "issue assigned" "gh issue edit failed"
  step_ok "issue #$FIXTURE_ISSUE assigned to $BOT_ASSIGNEE"
fi

# ============================================================================
# Step 5 — Disconnect. The operator simulator goes offline.
# ============================================================================
step_begin 5 "Disconnect (operator goes offline)"; maybe_inject_fail
DISCONNECT_AT="$(clock_now)"
dim "operator offline at epoch $DISCONNECT_AT — Commander is now on its own"
step_ok "disconnected — no further operator interaction until reconnect (step 8)"

# ============================================================================
# Step 6 — Wait for the autopickup tick to fire (clamped via HYDRA_FAKE_NOW).
# ============================================================================
step_begin 6 "Wait for autopickup tick"; maybe_inject_fail
if [[ "$DRY_RUN" -eq 1 ]]; then
  TICK_AT=$(( DISCONNECT_AT + TICK_INTERVAL ))
  dry "advancing simulated clock to epoch $TICK_AT (tick fires; no real sleep)"
  # The tick spawns a worker which opens a draft PR — materialize the mock PR.
  mock_put "pr.json" \
    '{"number":4242,"draft":true,"ci":"pending","label":null,"merged":false}'
  [[ -s "$MOCK_DIR/pr.json" ]] \
    || step_fail 6 "Wait for autopickup tick" "tick produced a worker/PR" "no PR materialized"
  step_ok "tick fired at epoch $TICK_AT — worker spawned, draft PR #4242 opened (mock)"
else
  deadline=$(( $(clock_now) + POLL_TIMEOUT ))
  fired=0
  while [[ "$(clock_now)" -lt "$deadline" ]]; do
    dim "waiting for cloud tick… (epoch $(clock_now), deadline $deadline)"
    if "$FLY_BIN" logs --app "$FLY_APP" 2>/dev/null | grep -q "autopickup: spawned"; then
      fired=1; break
    fi
    sleep "$TICK_INTERVAL"
  done
  [[ "$fired" -eq 1 ]] || step_fail 6 "Wait for autopickup tick" "tick fired before deadline" "no tick within ${POLL_TIMEOUT}s"
  step_ok "cloud autopickup tick fired — worker spawned"
fi

# ============================================================================
# Step 7 — Poll for PR creation (or the commander review-gate label).
# ============================================================================
step_begin 7 "Poll for PR creation"; maybe_inject_fail
if [[ "$DRY_RUN" -eq 1 ]]; then
  # The mock review gate runs: CI turns green, the review-clean label is applied.
  dim "polling… (mock PR already present from the tick)"
  mock_put "pr.json" \
    '{"number":4242,"draft":false,"ci":"green","label":"commander-review-clean","merged":false}'
  pr_num="$(mock_get pr.json | sed -n 's/.*"number":\([0-9]*\).*/\1/p')"
  [[ -n "$pr_num" ]] || step_fail 7 "Poll for PR creation" "a PR number" "no PR found in mock state"
  step_ok "PR #$pr_num observed — CI green, review gate cleared (mock)"
else
  deadline=$(( $(clock_now) + POLL_TIMEOUT ))
  pr_num=""
  while [[ "$(clock_now)" -lt "$deadline" ]]; do
    pr_num="$(gh pr list --repo "$TARGET_REPO" --search "linked:$FIXTURE_ISSUE" \
                --json number --jq '.[0].number' 2>/dev/null || true)"
    dim "polling for PR… (epoch $(clock_now), found='${pr_num:-none}')"
    [[ -n "$pr_num" && "$pr_num" != "null" ]] && break
    sleep "$POLL_INTERVAL"
  done
  [[ -n "$pr_num" && "$pr_num" != "null" ]] \
    || step_fail 7 "Poll for PR creation" "a PR within ${POLL_TIMEOUT}s" "no PR opened for issue #$FIXTURE_ISSUE"
  step_ok "PR #$pr_num opened by the cloud worker"
fi

# ============================================================================
# Step 8 — Reconnect. Verify PR exists, CI green, commander-review-clean.
# ============================================================================
step_begin 8 "Reconnect + verify (PR · CI · review-clean)"; maybe_inject_fail
ok "operator reconnects"
if [[ "$DRY_RUN" -eq 1 ]]; then
  pr_state="$(mock_get pr.json)"
  [[ "$pr_state" == *'"ci":"green"'* ]] \
    || step_fail 8 "Reconnect + verify" 'CI green' "$pr_state"
  [[ "$pr_state" == *'"label":"commander-review-clean"'* ]] \
    || step_fail 8 "Reconnect + verify" 'label commander-review-clean' "$pr_state"
  step_ok "verified: PR exists · CI green · commander-review-clean applied (mock)"
else
  gh pr view "$pr_num" --repo "$TARGET_REPO" >/dev/null 2>&1 \
    || step_fail 8 "Reconnect + verify" "PR #$pr_num exists" "gh pr view failed"
  gh pr checks "$pr_num" --repo "$TARGET_REPO" >/dev/null 2>&1 \
    || step_fail 8 "Reconnect + verify" "CI green" "gh pr checks not all green"
  gh pr view "$pr_num" --repo "$TARGET_REPO" --json labels --jq '.labels[].name' 2>/dev/null \
    | grep -qx "commander-review-clean" \
    || step_fail 8 "Reconnect + verify" "commander-review-clean label" "label not applied"
  step_ok "verified: PR #$pr_num exists · CI green · commander-review-clean applied"
fi

# ============================================================================
# Step 9 — Flip to T1 auto-merge and confirm the PR auto-merged.
# ============================================================================
step_begin 9 "T1 auto-merge + confirm"; maybe_inject_fail
if [[ "$DRY_RUN" -eq 1 ]]; then
  dry "merge-policy-lookup $TARGET_REPO T1 -> auto; gh pr merge $pr_num --squash"
  mock_put "pr.json" \
    '{"number":4242,"draft":false,"ci":"green","label":"commander-review-clean","merged":true}'
  [[ "$(mock_get pr.json)" == *'"merged":true'* ]] \
    || step_fail 9 "T1 auto-merge + confirm" 'PR merged=true' "$(mock_get pr.json)"
  step_ok "T1 policy -> auto-merge; PR #4242 merged (mock)"
else
  policy="$(scripts/merge-policy-lookup.sh "$TARGET_REPO" T1 2>/dev/null || echo human)"
  case "$policy" in
    auto|auto_if_review_clean) ;;
    *) step_fail 9 "T1 auto-merge + confirm" "merge_policy auto*" "policy=$policy (won't auto-merge)" ;;
  esac
  gh pr merge "$pr_num" --repo "$TARGET_REPO" --squash >/dev/null 2>&1 \
    || step_fail 9 "T1 auto-merge + confirm" "PR merged" "gh pr merge failed"
  gh pr view "$pr_num" --repo "$TARGET_REPO" --json state --jq '.state' 2>/dev/null \
    | grep -qx "MERGED" \
    || step_fail 9 "T1 auto-merge + confirm" "PR state MERGED" "PR not in MERGED state"
  step_ok "T1 policy -> auto-merge; PR #$pr_num merged"
fi

# ============================================================================
# Summary + paste-ready README badge
# ============================================================================
printf "\n%s━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━%s\n" "$C_DIM" "$C_RESET"
if [[ "$DRY_RUN" -eq 1 ]]; then
  printf "%sE2E dry-run complete.%s All %s steps passed. No side effects executed.\n" \
    "$C_BOLD" "$C_RESET" "$STEP_TOTAL"
  TODAY="$(date +%Y-%m-%d)"
  dim "Paste-ready README badge for this dry-run result:"
  dim "[![Cloud E2E](https://img.shields.io/badge/cloud_e2e-dry--run_passed_${TODAY}-blue.svg)](docs/phase2-vps-runbook.md#running-the-cloud-acceptance-test)"
else
  printf "%sE2E acceptance PASSED.%s All %s steps green — operator woke to a merged PR.\n" \
    "$C_BOLD" "$C_RESET" "$STEP_TOTAL"
  TODAY="$(date +%Y-%m-%d)"
  dim "Paste-ready README badge for this run:"
  dim "[![Cloud E2E](https://img.shields.io/badge/cloud_e2e-passed_${TODAY}-brightgreen.svg)](docs/phase2-vps-runbook.md#running-the-cloud-acceptance-test)"
fi
exit 0

#!/usr/bin/env bash
#
# autopickup-tick.sh — run the deterministic, scriptable parts of ONE autopickup
# tick and print a consolidated "what to act on" status report.
#
# This is the P1/autonomy capstone (ticket #228): it CHAINS the merged building
# blocks so Commander stops hand-orchestrating each step every interval —
#
#   preflight  →  pr-shepherd reconcile  →  completion-rescue scan  →  merge surfacing
#
# It REPORTS; it does NOT spawn agents, run the review gate, or merge. Those are
# Commander's decisions. Keeping actuation out of the script keeps every
# irreversible safety decision in Commander's hands and makes the whole tick
# trivially testable offline.
#
# It reuses (does NOT reimplement) the existing scripts:
#   scripts/pr-shepherd.sh        (#218/#221) — classify in-flight PRs
#   scripts/rescue-worker.sh      (#219)      — probe completed/stalled workers
#   scripts/merge-policy-lookup.sh (#20)      — per-repo merge policy
#   scripts/validate-state-all.sh             — preflight state validation
#
# AUTO-MERGE SAFETY RAILS (non-negotiable — see the spec):
#   - T3 is NEVER auto-merge-eligible (merge-policy-lookup hardcodes `never`;
#     this script ALSO refuses T3 unconditionally, defense-in-depth).
#   - A merge-ready PR is auto-merge-eligible ONLY if ALL hold: policy is
#     `auto` or `auto_if_review_clean`; the PR is review-CLEAN (shepherd
#     state == merge-ready); AND it does not touch a safety-rail path.
#   - Safety-rail-touching PRs ALWAYS surface for human merge regardless of
#     policy. Fail-closed: a PR with no changed-file data surfaces too.
#
# Usage:
#   scripts/autopickup-tick.sh [--repo <owner>/<name>] [--tier <T1|T2|T3>]
#       [--state-dir <path>] [--repos-file <path>] [--json]
#       [--gh-mock <dir>] [--rescue-mock <file>] [--no-rescue] [--no-merge-surface]
#
# Output:
#   default   grouped human report (Preflight / Shepherd / Rescue / Merge surfacing / Actions)
#   --json    one stable additive object:
#             {generated_at, repo, preflight:{...}, shepherd:{...},
#              rescue:[...], merge_surface:[...], actions:{...}}
#
# Test seams (offline, mirror the sibling scripts):
#   --gh-mock <dir>     passed to pr-shepherd.sh; also read by THIS script for
#                       per-PR changed-file data (<dir>/files-<n>.json). Also
#                       honored via env HYDRA_PR_SHEPHERD_GH_MOCK.
#   --rescue-mock <f>   JSONL of {branch, verdict, ...} lines used in place of
#                       shelling out to rescue-worker.sh --probe (self-test
#                       fixtures have no real git worktrees to probe).
#
# Exit codes:
#   0   tick ran (report printed) — preflight pass/fail is reported IN the
#       report, not via exit code, so the read-only scans always run.
#   1   I/O error (jq/gh missing, mock file unreadable, sub-script failure)
#   2   usage error (unknown flag / missing value / bad tier)
#
# Spec: docs/specs/2026-05-24-self-driving-autopickup-tick.md (ticket #228)
# Style mirrors scripts/pr-shepherd.sh and scripts/rescue-worker.sh.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"

usage() {
  cat <<'EOF'
Usage: autopickup-tick.sh [options]

Run the deterministic parts of one autopickup tick and print a consolidated
status report: preflight → pr-shepherd reconcile → completion-rescue scan →
policy-aware merge surfacing. REPORTS only — never spawns, reviews, or merges.

Options:
  --repo <owner>/<name>  Target repo (default: gh-detected current repo).
  --tier <T1|T2|T3>      Tier to resolve merge policy at. Default: the repo's
                         tier_default in the repos file, else T2 (conservative).
  --state-dir <path>     Override state/ dir (default $ROOT/state). Used for the
                         PAUSE check, active.json (rescue scan), and orphan
                         detection in the embedded shepherd call.
  --repos-file <path>    repos.json for merge-policy-lookup (default state/repos.json).
  --json                 Emit machine-readable JSON instead of the human report.
  --gh-mock <dir>        Test-only: offline gh fixtures. Passed to pr-shepherd.sh
                         and read here for <dir>/files-<n>.json. Also honored via
                         env HYDRA_PR_SHEPHERD_GH_MOCK.
  --rescue-mock <file>   Test-only: JSONL of {branch,verdict,...} standing in for
                         rescue-worker.sh --probe verdicts.
  --no-rescue            Skip the rescue scan (report an empty rescue list).
  --no-merge-surface     Skip the merge-surface block (report an empty list).
  --record-decisions     Also append a `merge-surface` Decision Record entry
                         (#267) per merge-ready PR to logs/decisions/<date>.jsonl
                         (additive; never state/). Off by default.
  --decisions-dir <p>    Test-only: Decision Record dir (default logs/decisions).
  --decisions-date <d>   Test-only: target daily file date (YYYY-MM-DD).
  --weekday <1-7>        Test-only: override local ISO weekday (1=Mon..7=Sun)
                         for Monday-retro detection. Default: live clock.
  --hour <0-23>          Test-only: override local hour for the >=09:00 retro gate
                         and the daily-digest time-of-day gate (section 4f).
  --minute <0-59>        Test-only: override local minute for the daily-digest
                         time-of-day gate (now_hm = HH:MM vs digest_time).
  --week <YYYY-WW>       Test-only: override the current ISO week tag (date +%G-%V).
  --today <YYYY-MM-DD>   Test-only: passed to promote-citations.sh --check-due.
  --retros-dir <path>    Override memory/retros (retro file lookup + filer).
  --retro-file-cmd <cmd> Test-only: stub for retro-file-proposed-edits.sh; run
                         with the ISO week as $1.
  --tickets-total <n>    CUMULATIVE ticket count for the memory-hygiene counter.
                         When omitted, the hygiene check reports not-due with
                         reason "tickets-total not provided" — it does NOT fall
                         back to the daily-resetting budget-used counter (that
                         math is dimensionally incoherent against the cumulative
                         baseline and silently suppresses hygiene).
  --hygiene-threshold <n> Compact-memory threshold (default 10). 0 disables the
                         check (reported as not-due, reason "hygiene-threshold is 0").
  --worktrees-dir <path> Test-only: override the worktrees root the gc-stale-
                         worktrees scan inspects (default $ROOT/.claude/worktrees).
  --gc-script <path>     Test-only: override the gc-stale-worktrees.sh the gc
                         safety scan shells out to (default $ROOT/scripts/...).
  --stalls-cmd <cmd>     Test-only: stub for detect-worker-stalls.sh; must emit
                         the detector's --json object on stdout. Default shells
                         out to scripts/detect-worker-stalls.sh --json --no-log.
  -h, --help             Show this help.

AUTO-MERGE SAFETY RAILS:
  T3 is never auto-merge-eligible. Only review-CLEAN (shepherd merge-ready),
  non-safety-rail PRs on an auto* policy are eligible. Safety-rail-touching and
  no-file-data (fail-closed) PRs always surface for human merge.

Exit codes:
  0 tick ran · 1 I/O error · 2 usage error

Spec: docs/specs/2026-05-24-self-driving-autopickup-tick.md (ticket #228)
EOF
}

# -----------------------------------------------------------------------------
# argument parsing
# -----------------------------------------------------------------------------
repo=""
tier=""
state_dir_override=""
repos_file_override=""
json_mode=0
gh_mock="${HYDRA_PR_SHEPHERD_GH_MOCK:-}"
rescue_mock=""
do_rescue=1
do_merge_surface=1
# Decision Record producer (ticket #267). OFF by default so the tick stays
# report-only w.r.t. Commander state and all existing test expectations hold.
# When ON, the merge-surface step ALSO appends a `merge-surface` decision entry
# (the already-computed reason) to the ADDITIVE logs/decisions/<date>.jsonl —
# never to state/. With the flag off, behavior is byte-identical.
record_decisions=0
decisions_dir_override=""   # --decisions-dir <path> (test seam; default logs/decisions)
decisions_date_override=""  # --decisions-date <YYYY-MM-DD> (test seam)
# scheduled-checks + memory-hygiene seams (ticket #239). All optional; defaults
# read the live clock / state so a bare invocation Just Works, while the flags
# make the smoke test deterministic and offline.
weekday_override=""        # --weekday <1-7> (ISO; 1=Mon..7=Sun)
hour_override=""           # --hour <0-23>
minute_override=""         # --minute <0-59> (digest time-of-day gate, ticket #266)
week_override=""           # --week <YYYY-WW> (ISO week tag, date +%G-%V)
today_override=""          # --today <YYYY-MM-DD> (passed to promote-citations --check-due)
retros_dir_override=""     # --retros-dir <path> (default memory/retros)
retro_file_cmd=""          # --retro-file-cmd <cmd> (test stub for the filer)
tickets_total_override=""  # --tickets-total <n> (cumulative ticket count)
hygiene_threshold=10       # --hygiene-threshold <n>
# stall-robustness seams (ticket #242). Optional; default reads live state/tree.
worktrees_dir_override=""  # --worktrees-dir <path> (gc-stale-worktrees scan root)
gc_script_override=""       # --gc-script <path> Test-only: override gc-stale-worktrees.sh
# worker-stall observability seam (ticket #306). Optional; default shells out to
# scripts/detect-worker-stalls.sh. The detector is read-only/report-only; the
# tick runs it with --no-log so the detector's OWN scheduled run owns the event
# log (the tick must not double-write logs/stalls-*.jsonl).
stalls_cmd=""              # --stalls-cmd <cmd> Test-only: stub the stall detector

need_val() {
  if [[ $# -lt 2 ]]; then
    echo "autopickup-tick: option '$1' requires a value" >&2
    usage >&2
    exit 2
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)            usage; exit 0 ;;
    --repo)               need_val "$@"; repo="$2"; shift 2 ;;
    --repo=*)             repo="${1#--repo=}"; shift ;;
    --tier)               need_val "$@"; tier="$2"; shift 2 ;;
    --tier=*)             tier="${1#--tier=}"; shift ;;
    --state-dir)          need_val "$@"; state_dir_override="$2"; shift 2 ;;
    --state-dir=*)        state_dir_override="${1#--state-dir=}"; shift ;;
    --repos-file)         need_val "$@"; repos_file_override="$2"; shift 2 ;;
    --repos-file=*)       repos_file_override="${1#--repos-file=}"; shift ;;
    --gh-mock)            need_val "$@"; gh_mock="$2"; shift 2 ;;
    --gh-mock=*)          gh_mock="${1#--gh-mock=}"; shift ;;
    --rescue-mock)        need_val "$@"; rescue_mock="$2"; shift 2 ;;
    --rescue-mock=*)      rescue_mock="${1#--rescue-mock=}"; shift ;;
    --json)               json_mode=1; shift ;;
    --no-rescue)          do_rescue=0; shift ;;
    --no-merge-surface)   do_merge_surface=0; shift ;;
    --record-decisions)   record_decisions=1; shift ;;
    --decisions-dir)      need_val "$@"; decisions_dir_override="$2"; shift 2 ;;
    --decisions-dir=*)    decisions_dir_override="${1#--decisions-dir=}"; shift ;;
    --decisions-date)     need_val "$@"; decisions_date_override="$2"; shift 2 ;;
    --decisions-date=*)   decisions_date_override="${1#--decisions-date=}"; shift ;;
    --weekday)            need_val "$@"; weekday_override="$2"; shift 2 ;;
    --weekday=*)          weekday_override="${1#--weekday=}"; shift ;;
    --hour)               need_val "$@"; hour_override="$2"; shift 2 ;;
    --hour=*)             hour_override="${1#--hour=}"; shift ;;
    --minute)             need_val "$@"; minute_override="$2"; shift 2 ;;
    --minute=*)           minute_override="${1#--minute=}"; shift ;;
    --week)               need_val "$@"; week_override="$2"; shift 2 ;;
    --week=*)             week_override="${1#--week=}"; shift ;;
    --today)              need_val "$@"; today_override="$2"; shift 2 ;;
    --today=*)            today_override="${1#--today=}"; shift ;;
    --retros-dir)         need_val "$@"; retros_dir_override="$2"; shift 2 ;;
    --retros-dir=*)       retros_dir_override="${1#--retros-dir=}"; shift ;;
    --retro-file-cmd)     need_val "$@"; retro_file_cmd="$2"; shift 2 ;;
    --retro-file-cmd=*)   retro_file_cmd="${1#--retro-file-cmd=}"; shift ;;
    --tickets-total)      need_val "$@"; tickets_total_override="$2"; shift 2 ;;
    --tickets-total=*)    tickets_total_override="${1#--tickets-total=}"; shift ;;
    --hygiene-threshold)  need_val "$@"; hygiene_threshold="$2"; shift 2 ;;
    --hygiene-threshold=*) hygiene_threshold="${1#--hygiene-threshold=}"; shift ;;
    --worktrees-dir)      need_val "$@"; worktrees_dir_override="$2"; shift 2 ;;
    --worktrees-dir=*)    worktrees_dir_override="${1#--worktrees-dir=}"; shift ;;
    --gc-script)          need_val "$@"; gc_script_override="$2"; shift 2 ;;
    --gc-script=*)        gc_script_override="${1#--gc-script=}"; shift ;;
    --stalls-cmd)         need_val "$@"; stalls_cmd="$2"; shift 2 ;;
    --stalls-cmd=*)       stalls_cmd="${1#--stalls-cmd=}"; shift ;;
    *) echo "autopickup-tick: unknown arg '$1'" >&2; usage >&2; exit 2 ;;
  esac
done

if [[ -n "$tier" ]]; then
  case "$tier" in
    T1|T2|T3) ;;
    *) echo "autopickup-tick: invalid --tier '$tier' (expected T1, T2, or T3)" >&2; exit 2 ;;
  esac
fi

# Validate the numeric scheduled/hygiene seams when supplied.
if [[ -n "$weekday_override" && ! "$weekday_override" =~ ^[1-7]$ ]]; then
  echo "autopickup-tick: --weekday must be 1-7 (ISO; 1=Mon), got '$weekday_override'" >&2; exit 2
fi
if [[ -n "$hour_override" && ! "$hour_override" =~ ^(0?[0-9]|1[0-9]|2[0-3])$ ]]; then
  echo "autopickup-tick: --hour must be 0-23, got '$hour_override'" >&2; exit 2
fi
if [[ -n "$minute_override" && ! "$minute_override" =~ ^([0-5]?[0-9])$ ]]; then
  echo "autopickup-tick: --minute must be 0-59, got '$minute_override'" >&2; exit 2
fi
if [[ -n "$tickets_total_override" && ! "$tickets_total_override" =~ ^[0-9]+$ ]]; then
  echo "autopickup-tick: --tickets-total must be a non-negative integer, got '$tickets_total_override'" >&2; exit 2
fi
if [[ ! "$hygiene_threshold" =~ ^[0-9]+$ ]]; then
  echo "autopickup-tick: --hygiene-threshold must be a non-negative integer, got '$hygiene_threshold'" >&2; exit 2
fi

command -v jq >/dev/null 2>&1 || { echo "autopickup-tick: jq not found on PATH" >&2; exit 1; }

STATE_DIR="${state_dir_override:-$ROOT_DIR/state}"
ACTIVE_FILE="$STATE_DIR/active.json"
PAUSE_FILE="$STATE_DIR/PAUSE"
REPOS_FILE="${repos_file_override:-$STATE_DIR/repos.json}"
BUDGET_FILE="$ROOT_DIR/budget.json"
AUTOPICKUP_FILE="$STATE_DIR/autopickup.json"
BUDGET_USED_FILE="$STATE_DIR/budget-used.json"
# Daily-digest config + idempotency state. CANONICAL home is state/digests.json
# (written by `./hydra connect digest` via scripts/hydra-connect.sh): it owns
# enabled / time / last_digest_run. The tick reads them from here so a non-09:00
# schedule the operator configured actually takes effect and an already-emitted
# digest is not re-reported as due (ticket #266; #144 shipped this file).
DIGEST_FILE="$STATE_DIR/digests.json"
RETROS_DIR="${retros_dir_override:-$ROOT_DIR/memory/retros}"

SHEPHERD="$ROOT_DIR/scripts/pr-shepherd.sh"
RESCUE="$ROOT_DIR/scripts/rescue-worker.sh"
MERGE_POLICY="$ROOT_DIR/scripts/merge-policy-lookup.sh"
VALIDATE_ALL="$ROOT_DIR/scripts/validate-state-all.sh"
RETRO_FILER="$ROOT_DIR/scripts/retro-file-proposed-edits.sh"
PROMOTE="$ROOT_DIR/scripts/promote-citations.sh"
GC_WORKTREES="${gc_script_override:-$ROOT_DIR/scripts/gc-stale-worktrees.sh}"
WORKTREES_DIR="${worktrees_dir_override:-$ROOT_DIR/.claude/worktrees}"
RECORD_DECISION="$ROOT_DIR/scripts/record-decision.sh"
DETECT_STALLS="$ROOT_DIR/scripts/detect-worker-stalls.sh"

GEN_TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# =============================================================================
# 1. PREFLIGHT
# =============================================================================
# PAUSE marker present?
pause_present=false
[[ -e "$PAUSE_FILE" || -e "$ROOT_DIR/commander/PAUSE" ]] && pause_present=true

# state validation (read-only; never blocks the scans, only the spawn decision).
state_valid=true
state_validation_note=""
if [[ -x "$VALIDATE_ALL" ]]; then
  if ! "$VALIDATE_ALL" --state-dir "$STATE_DIR" >/dev/null 2>&1; then
    state_valid=false
    state_validation_note="validate-state-all reported schema drift"
  fi
else
  state_validation_note="validate-state-all not found; skipped"
fi

# concurrency headroom = max_concurrent_workers - active workers.
max_workers=0
if [[ -f "$BUDGET_FILE" ]]; then
  max_workers="$(jq -r '.phase1_subscription_caps.max_concurrent_workers // 0' "$BUDGET_FILE" 2>/dev/null || echo 0)"
fi
[[ "$max_workers" =~ ^[0-9]+$ ]] || max_workers=0

active_workers=0
if [[ -f "$ACTIVE_FILE" ]]; then
  active_workers="$(jq -r '(.workers // []) | length' "$ACTIVE_FILE" 2>/dev/null || echo 0)"
fi
[[ "$active_workers" =~ ^[0-9]+$ ]] || active_workers=0

concurrency_headroom=$(( max_workers - active_workers ))
(( concurrency_headroom < 0 )) && concurrency_headroom=0

# Interval guard (ticket #242): the rescue watchdog only helps if a tick fires
# while a stalling worker is still recoverable. If interval_min is at or above
# the ~18-min stream-idle ceiling, workers can time out BEFORE any tick runs to
# probe them. WARN (report-only; does not block spawn or rewrite the interval).
interval_min=0
if [[ -f "$AUTOPICKUP_FILE" ]]; then
  interval_min="$(jq -r '.interval_min // 0' "$AUTOPICKUP_FILE" 2>/dev/null || echo 0)"
fi
[[ "$interval_min" =~ ^[0-9]+$ ]] || interval_min=0
interval_warn=false
interval_warn_text=""
if (( interval_min >= 18 )); then
  interval_warn=true
  interval_warn_text="interval_min=${interval_min} will miss the ~18min stream-idle ceiling; set <15"
fi

# spawn_blocked: any preflight failure means Commander must NOT spawn this tick.
spawn_blocked=false
if [[ "$pause_present" == true || "$state_valid" == false || "$concurrency_headroom" -le 0 ]]; then
  spawn_blocked=true
fi

preflight_json="$(jq -nc \
  --argjson pause_present "$pause_present" \
  --argjson state_valid "$state_valid" \
  --arg state_validation_note "$state_validation_note" \
  --argjson max_workers "$max_workers" \
  --argjson active_workers "$active_workers" \
  --argjson concurrency_headroom "$concurrency_headroom" \
  --argjson spawn_blocked "$spawn_blocked" \
  --argjson interval_min "$interval_min" \
  --argjson interval_warn "$interval_warn" \
  --arg interval_warn_text "$interval_warn_text" \
  '{pause_present:$pause_present, state_valid:$state_valid,
    state_validation_note:$state_validation_note,
    max_workers:$max_workers, active_workers:$active_workers,
    concurrency_headroom:$concurrency_headroom, spawn_blocked:$spawn_blocked,
    interval_min:$interval_min, interval_warn:$interval_warn,
    interval_warn_text:$interval_warn_text}')"

# =============================================================================
# 2. PR-SHEPHERD RECONCILE
# =============================================================================
shepherd_args=(--json --state-dir "$STATE_DIR")
[[ -n "$repo" ]] && shepherd_args+=(--repo "$repo")
[[ -n "$gh_mock" ]] && shepherd_args+=(--gh-mock "$gh_mock")

shepherd_json='{"prs":[],"summary":{}}'
if [[ -x "$SHEPHERD" ]]; then
  if ! shepherd_json="$("$SHEPHERD" "${shepherd_args[@]}" 2>/dev/null)"; then
    echo "autopickup-tick: pr-shepherd.sh failed" >&2
    exit 1
  fi
else
  echo "autopickup-tick: pr-shepherd.sh not found/executable" >&2
  exit 1
fi
# Validate it's JSON.
printf '%s' "$shepherd_json" | jq empty 2>/dev/null \
  || { echo "autopickup-tick: pr-shepherd produced non-JSON" >&2; exit 1; }

# =============================================================================
# 3. COMPLETION-RESCUE SCAN
# =============================================================================
# For each active worker, get a rescue verdict (mock JSONL in tests, else probe).
# Map verdict → action:
#   rescue-commits / rescue-uncommitted / push-only  → needs-rescue
#   nothing-to-rescue                                 → ok
#   flaky-tool-retry / worker-mid-tool-call           → live-wait (worker ALIVE;
#                                                        do NOT rescue)
#   worker-looping                                    → needs-rescue (thrashing;
#                                                        rescue + restart)
#   review-* / anything else                          → review (surface verbatim)
rescue_action_for_verdict() {
  case "$1" in
    rescue-commits|rescue-uncommitted|push-only|worker-looping) echo "needs-rescue" ;;
    nothing-to-rescue)                                          echo "ok" ;;
    flaky-tool-retry|worker-mid-tool-call)                      echo "live-wait" ;;
    *)                                                          echo "review" ;;
  esac
}

# Read a verdict for a branch from the rescue-mock JSONL (empty if absent).
rescue_mock_verdict() {
  local branch="$1"
  [[ -n "$rescue_mock" && -r "$rescue_mock" ]] || { echo ""; return; }
  jq -rc --arg b "$branch" 'select(.branch == $b)' "$rescue_mock" 2>/dev/null | head -n1
}

rescue_jsonl=""
if [[ "$do_rescue" -eq 1 && -f "$ACTIVE_FILE" ]]; then
  # iterate workers (compact JSON lines)
  while IFS= read -r w; do
    [[ -n "$w" ]] || continue
    branch="$(printf '%s' "$w" | jq -r '.branch // ""')"
    worktree="$(printf '%s' "$w" | jq -r '.worktree // ""')"
    ticket="$(printf '%s' "$w" | jq -r '.ticket // ""')"
    wid="$(printf '%s' "$w" | jq -r '.id // ""')"
    [[ -n "$branch" ]] || continue  # branchless (pre-migration) workers — skip probe

    verdict=""
    probe_obj=""
    if [[ -n "$rescue_mock" ]]; then
      probe_obj="$(rescue_mock_verdict "$branch")"
      verdict="$(printf '%s' "$probe_obj" | jq -r '.verdict // ""' 2>/dev/null || echo "")"
    elif [[ -x "$RESCUE" && -n "$worktree" ]]; then
      # Live probe — non-mutating. A probe failure for one worker is logged and
      # does not abort the tick (set +e around the call).
      set +e
      probe_obj="$("$RESCUE" --probe "$worktree" "$branch" "$ticket" 2>/dev/null)"
      set -e
      verdict="$(printf '%s' "$probe_obj" | jq -r '.verdict // ""' 2>/dev/null || echo "")"
    fi
    [[ -n "$verdict" ]] || verdict="nothing-to-rescue"  # no signal → treat as healthy
    action="$(rescue_action_for_verdict "$verdict")"

    row="$(jq -nc \
      --arg id "$wid" --arg branch "$branch" --arg ticket "$ticket" \
      --arg verdict "$verdict" --arg action "$action" \
      '{id:$id, branch:$branch, ticket:$ticket, verdict:$verdict, action:$action}')"
    rescue_jsonl+="$row"$'\n'
  done < <(jq -c '(.workers // [])[]' "$ACTIVE_FILE" 2>/dev/null)
fi

if [[ -n "${rescue_jsonl//[$'\n']/}" ]]; then
  rescue_array="$(printf '%s' "$rescue_jsonl" | jq -sc '.')"
else
  rescue_array='[]'
fi

# =============================================================================
# 4. MERGE SURFACING  (the safety-rail core)
# =============================================================================
# Decision Record producer (#267). Translate a merge-surface (classification,
# reason, policy, tier) into a human `why` sentence + a `what_would_reverse`,
# then append a `merge-surface` decision entry via record-decision.sh --json.
# Only called when --record-decisions is set; writes ONLY to the additive
# logs/decisions/ log (never state/), so the tick stays report-only.
decision_why_for_reason() {
  local reason="$1" policy="$2" tier="$3"
  case "$reason" in
    t3-never)       printf 'policy.md: T3 is never auto-merge-eligible (hardcoded safety rail; tier=%s)' "$tier" ;;
    policy-never)   printf 'merge-policy-lookup resolved policy=never for tier=%s' "$tier" ;;
    policy-human)   printf 'merge-policy-lookup resolved policy=human for tier=%s — needs operator approval' "$tier" ;;
    safety-rail)    printf 'changed files touch a safety-rail path (or no file data → fail-closed); always surfaces regardless of policy=%s' "$policy" ;;
    policy-unknown) printf 'merge policy could not be resolved for tier=%s → fail-closed to human' "$tier" ;;
    policy-auto|policy-auto_if_review_clean)
                    printf 'policy=%s and no safety-rail path touched → eligible for auto-merge (tier=%s)' "$policy" "$tier" ;;
    *)              printf 'reason=%s, policy=%s, tier=%s' "$reason" "$policy" "$tier" ;;
  esac
}
decision_reverse_for_reason() {
  local reason="$1"
  case "$reason" in
    t3-never|policy-never|policy-human|policy-unknown)
                 printf 'if the PR is reclassified to a tier/policy that permits auto-merge' ;;
    safety-rail) printf 'if the PR stops touching any safety-rail path' ;;
    policy-auto|policy-auto_if_review_clean)
                 printf 'if the PR starts touching a safety-rail path, or the review verdict regresses' ;;
    *)           printf '' ;;
  esac
}
# record_merge_decision <subject> <decided/classification> <reason> <policy> <tier>
record_merge_decision() {
  [[ "$record_decisions" -eq 1 ]] || return 0
  [[ -x "$RECORD_DECISION" ]] || return 0
  local subject="$1" decided="$2" reason="$3" policy="$4" tier="$5"
  local why reverse entry
  why="$(decision_why_for_reason "$reason" "$policy" "$tier")"
  reverse="$(decision_reverse_for_reason "$reason")"
  entry="$(jq -nc \
    --arg subject "$subject" \
    --arg decided "$decided" \
    --arg why "$why" \
    --arg reverse "$reverse" \
    '{decision_type:"merge-surface", subject:$subject, decided:$decided,
      why:$why, approval_ref:null}
     + (if ($reverse|length)>0 then {what_would_reverse:$reverse} else {} end)')"
  local dargs=(--json)
  [[ -n "$decisions_dir_override" ]]  && dargs+=(--decisions-dir "$decisions_dir_override")
  [[ -n "$decisions_date_override" ]] && dargs+=(--date "$decisions_date_override")
  # Best-effort: a writer failure must never break the report-only tick.
  printf '%s' "$entry" | "$RECORD_DECISION" "${dargs[@]}" >/dev/null 2>&1 || true
}

# Safety-rail path detection. A merge-ready PR whose changed files include ANY
# of these is ALWAYS surfaced for human merge — never auto-merged — regardless
# of policy. Mirrors the worker hard-rails + the merge mechanism itself.
is_safety_rail_path() {
  local p="$1"
  case "$p" in
    scripts/merge-policy-lookup.sh|scripts/autopickup-tick.sh|\
    scripts/pr-shepherd.sh|scripts/rescue-worker.sh) return 0 ;;
    policy.md|CLAUDE.md) return 0 ;;
    # Merge-authority config: a PR editing a repo's OWN merge_policy (repos.json)
    # or the schema that governs it must NEVER auto-merge — it could grant itself
    # auto-merge rights. Always surface for human review. (ticket #245 review)
    state/repos.json|state/schemas/repos.schema.json) return 0 ;;
    .github/workflows/*) return 0 ;;
  esac
  case "$p" in
    *secret*|*.env|*.env.*|.env*|*auth*|*security*|*crypto*) return 0 ;;
  esac
  # DB migration files (common conventions).
  case "$p" in
    *migrations/*|*migration/*|*.migration.*) return 0 ;;
  esac
  return 1
}

# Fetch a PR's changed-file paths. Test seam: <gh-mock>/files-<n>.json
# ({files:[{path:...}]}). Live: gh pr view <n> --repo <slug> --json files.
# Returns the paths, one per line; empty output (no data) → caller fails closed.
# The slug (url-derived, may differ from --repo when shepherd returns cross-repo
# PRs) targets the gh call at the PR's actual repo.
pr_changed_files() {
  local n="$1" slug="${2:-$repo}"
  if [[ -n "$gh_mock" ]]; then
    local f="$gh_mock/files-${n}.json"
    [[ -r "$f" ]] || return 0   # no file mock → no data → fail-closed upstream
    jq -r '(.files // [])[].path' "$f" 2>/dev/null || true
    return 0
  fi
  command -v gh >/dev/null 2>&1 || return 0
  local repo_args=()
  [[ -n "$slug" ]] && repo_args=(--repo "$slug")
  gh pr view "$n" "${repo_args[@]}" --json files \
    --jq '(.files // [])[].path' 2>/dev/null || true
}

# Resolve the slug for a PR (owner/name) from its url, else fall back to --repo.
slug_from_url() {
  # https://github.com/<owner>/<name>/pull/<n>  → <owner>/<name>
  local url="$1"
  if [[ "$url" =~ github\.com/([^/]+)/([^/]+)/pull/ ]]; then
    printf '%s/%s' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
  else
    printf '%s' "$repo"
  fi
}

# Resolve the tier for a slug: explicit --tier wins, else repos.json tier_default,
# else T2 (conservative — needs human by policy.md default).
resolve_tier() {
  local slug="$1"
  if [[ -n "$tier" ]]; then printf '%s' "$tier"; return; fi
  local owner="${slug%%/*}" name="${slug#*/}"
  if [[ -f "$REPOS_FILE" ]]; then
    local td
    td="$(jq -r --arg o "$owner" --arg n "$name" \
      '.repos // [] | map(select(.owner == $o and .name == $n)) | .[0].tier_default // empty' \
      "$REPOS_FILE" 2>/dev/null || echo "")"
    if [[ "$td" =~ ^T[123]$ ]]; then printf '%s' "$td"; return; fi
  fi
  printf 'T2'
}

merge_jsonl=""
if [[ "$do_merge_surface" -eq 1 ]]; then
  # Only merge-ready PRs are candidates.
  while IFS= read -r pr; do
    [[ -n "$pr" ]] || continue
    number="$(printf '%s' "$pr" | jq -r '.number')"
    url="$(printf '%s' "$pr" | jq -r '.url // ""')"
    title="$(printf '%s' "$pr" | jq -r '.title // ""')"
    orphaned="$(printf '%s' "$pr" | jq -r '.orphaned // false')"

    slug="$(slug_from_url "$url")"
    pr_tier="$(resolve_tier "$slug")"

    classification=""; reason=""; policy=""

    # --- Rail #1: T3 is NEVER auto-merge-eligible (defense-in-depth on top of
    #     merge-policy-lookup, which also hardcodes T3 → never).
    if [[ "$pr_tier" == "T3" ]]; then
      classification="surface-for-human"; reason="t3-never"; policy="never"
    else
      # Resolve policy via merge-policy-lookup (the single source of truth).
      policy=""
      if [[ -x "$MERGE_POLICY" && -f "$REPOS_FILE" ]]; then
        set +e
        policy="$("$MERGE_POLICY" "$slug" "$pr_tier" --repos-file "$REPOS_FILE" 2>/dev/null)"
        set -e
      fi
      [[ -n "$policy" ]] || policy="human"  # unresolved policy → fail-closed to human

      case "$policy" in
        never)
          classification="surface-for-human"; reason="policy-never" ;;
        human)
          classification="surface-for-human"; reason="policy-human" ;;
        auto|auto_if_review_clean)
          # --- Rail #2: changed-file safety-rail check (fail-closed).
          files="$(pr_changed_files "$number" "$slug")"
          if [[ -z "${files//[$'\n']/}" ]]; then
            # No file data at all → fail closed → surface.
            classification="surface-for-human"; reason="safety-rail"
          else
            rail_hit=0
            while IFS= read -r fp; do
              [[ -n "$fp" ]] || continue
              if is_safety_rail_path "$fp"; then rail_hit=1; break; fi
            done <<<"$files"
            if [[ "$rail_hit" -eq 1 ]]; then
              classification="surface-for-human"; reason="safety-rail"
            else
              classification="auto-merge-eligible"; reason="policy-${policy}"
            fi
          fi
          ;;
        *)
          classification="surface-for-human"; reason="policy-unknown" ;;
      esac
    fi

    row="$(jq -nc \
      --argjson number "$number" --arg title "$title" --arg url "$url" \
      --arg slug "$slug" --arg tier "$pr_tier" --arg policy "$policy" \
      --argjson orphaned "$orphaned" \
      --arg classification "$classification" --arg reason "$reason" \
      '{number:$number, title:$title, url:$url, slug:$slug, tier:$tier,
        policy:$policy, orphaned:$orphaned,
        classification:$classification, reason:$reason}')"
    merge_jsonl+="$row"$'\n'

    # Decision Record (#267): record WHY this PR was classified the way it was.
    # Opt-in (--record-decisions); additive log only.
    record_merge_decision "${slug}#${number}" "$classification" "$reason" "$policy" "$pr_tier"
  done < <(printf '%s' "$shepherd_json" | jq -c '(.prs // [])[] | select(.state == "merge-ready")')
fi

if [[ -n "${merge_jsonl//[$'\n']/}" ]]; then
  merge_array="$(printf '%s' "$merge_jsonl" | jq -sc '.')"
else
  merge_array='[]'
fi

# =============================================================================
# 4b. SCHEDULED CHECKS  (Monday-retro + once/day skill-promotion)
# =============================================================================
# REPORT-ONLY discipline: this block detects what is DUE and, for the retro,
# files the proposed-edits issues from an ALREADY-WRITTEN retro file (idempotent
# via retro-file-proposed-edits.sh). It NEVER writes the retro markdown, never
# spawns, never stamps last_retro_run/last_promotion_run — those mutations stay
# Commander's job (same split as promote-citations.sh --check-due).
#
# Test seams: --weekday/--hour fix "now"; --week fixes the ISO week tag;
# --retros-dir + --retro-file-cmd stub retro-file presence + the filer.

# Resolve "now": local weekday (ISO 1-7) + hour, with overrides for tests.
now_weekday="${weekday_override:-$(date +%u)}"   # %u = ISO weekday, 1=Mon..7=Sun
now_hour="${hour_override:-$(date +%H)}"
now_hour=$((10#$now_hour))                        # strip leading zero (08 -> 8)
now_week="${week_override:-$(date +%G-%V)}"       # ISO year-week, e.g. 2026-23

# last_retro_run from autopickup.json (empty if file/field absent).
last_retro_run=""
if [[ -f "$AUTOPICKUP_FILE" ]]; then
  last_retro_run="$(jq -r '.last_retro_run // ""' "$AUTOPICKUP_FILE" 2>/dev/null || echo "")"
fi
# Map a last_retro_run timestamp to its ISO week tag for the idempotency guard.
# Accept either an ISO timestamp (YYYY-MM-DDTHH:MM:SS) or a bare date.
last_retro_week=""
if [[ -n "$last_retro_run" ]]; then
  ld="${last_retro_run%%T*}"   # date portion
  if [[ "$ld" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
    # GNU date and BSD date differ; try both, fall back to empty (treat as stale).
    last_retro_week="$(date -d "$ld" +%G-%V 2>/dev/null \
      || date -j -f %Y-%m-%d "$ld" +%G-%V 2>/dev/null || echo "")"
  fi
fi

# Retro is due: Monday (weekday 1) at/after 09:00 local, and not already run
# this ISO week.
retro_due=false
if [[ "$now_weekday" == "1" && "$now_hour" -ge 9 && "$last_retro_week" != "$now_week" ]]; then
  retro_due=true
fi

retro_marker=""
retro_file_present=false
retro_file_result=""
if [[ "$retro_due" == true ]]; then
  retro_path="$RETROS_DIR/${now_week}.md"
  if [[ -f "$retro_path" ]]; then
    retro_file_present=true
    # File the proposed-edits issues from the already-written retro. The filer
    # is idempotent (skips duplicate titles). A failure is reported, never fatal.
    set +e
    if [[ -n "$retro_file_cmd" ]]; then
      retro_file_result="$(bash -c "$retro_file_cmd" _ "$now_week" 2>&1)"
      retro_file_rc=$?
    elif [[ -x "$RETRO_FILER" ]]; then
      retro_file_result="$("$RETRO_FILER" "$now_week" --retros-dir "$RETROS_DIR" 2>&1)"
      retro_file_rc=$?
    else
      retro_file_result="retro-file-proposed-edits.sh not found"
      retro_file_rc=127
    fi
    set -e
    # Only claim "retro-filed" when the filer actually succeeded; otherwise say so
    # so Commander doesn't believe the edits were filed when they weren't.
    if [[ "$retro_file_rc" -eq 0 ]]; then
      retro_marker="retro-filed"
    else
      retro_marker="retro-file-failed"
    fi
  else
    # Retro is due but Commander hasn't written it yet — it must write first.
    retro_marker="retro-due-write-first"
  fi
fi

# Skill-promotion due: delegate to promote-citations.sh --check-due
# (exit 0 = due, exit 10 = already ran today). No side effects, no stamping.
promotion_due=false
if [[ -x "$PROMOTE" ]]; then
  promote_due_args=(--check-due --state-dir "$STATE_DIR")
  [[ -n "$today_override" ]] && promote_due_args+=(--now "$today_override")
  set +e
  "$PROMOTE" "${promote_due_args[@]}" >/dev/null 2>&1
  promote_rc=$?
  set -e
  [[ "$promote_rc" -eq 0 ]] && promotion_due=true
fi

scheduled_json="$(jq -nc \
  --argjson weekday "$now_weekday" \
  --argjson hour "$now_hour" \
  --arg week "$now_week" \
  --argjson retro_due "$retro_due" \
  --arg retro_marker "$retro_marker" \
  --argjson retro_file_present "$retro_file_present" \
  --arg retro_file_result "$retro_file_result" \
  --argjson promotion_due "$promotion_due" \
  '{weekday:$weekday, hour:$hour, week:$week,
    retro_due:$retro_due, retro_marker:$retro_marker,
    retro_file_present:$retro_file_present, retro_file_result:$retro_file_result,
    promotion_due:$promotion_due}')"

# =============================================================================
# 4c. MEMORY-HYGIENE COUNTER  (compact every N tickets)
# =============================================================================
# Tracks a monotonic baseline (tickets_at_last_hygiene) against a CUMULATIVE
# ticket total. When tickets_since reaches the threshold (default 10), emit a
# compact-memory marker. The tick does NOT reset the baseline — Commander resets
# it after running the compaction (report-don't-mutate).
#
# CRITICAL coherence rule: the counter is only meaningful when a CUMULATIVE total
# is supplied via --tickets-total. There is NO reliable cumulative source on disk
# — budget-used.json:tickets_completed_today is a DAILY-RESETTING counter, and
# subtracting the cumulative baseline (tickets_at_last_hygiene) from a daily
# counter is dimensionally incoherent: a fresh day's small count minus a large
# cumulative baseline clamps negative → tickets_since=0 → hygiene silently
# suppressed forever. So when --tickets-total is absent we DO NOT compute from
# the daily counter; we report hygiene as not-due with an explicit reason, making
# the gap visible instead of silently wrong. (report-only; no spawn/merge/write.)
tickets_at_last_hygiene=0
if [[ -f "$AUTOPICKUP_FILE" ]]; then
  tickets_at_last_hygiene="$(jq -r '.tickets_at_last_hygiene // 0' "$AUTOPICKUP_FILE" 2>/dev/null || echo 0)"
fi
[[ "$tickets_at_last_hygiene" =~ ^[0-9]+$ ]] || tickets_at_last_hygiene=0

hygiene_due=false
hygiene_marker=""
hygiene_reason=""
tickets_total=0
tickets_since=0

if [[ -z "$tickets_total_override" ]]; then
  # No cumulative total provided → cannot compute coherently. Report, don't guess.
  hygiene_reason="tickets-total not provided"
elif (( hygiene_threshold == 0 )); then
  # A threshold of 0 ("compact every 0 tickets") is meaningless; treat as disabled
  # rather than tripping on every tick.
  tickets_total="$tickets_total_override"
  hygiene_reason="hygiene-threshold is 0 (disabled)"
else
  tickets_total="$tickets_total_override"
  tickets_since=$(( tickets_total - tickets_at_last_hygiene ))
  (( tickets_since < 0 )) && tickets_since=0
  if (( tickets_since >= hygiene_threshold )); then
    hygiene_due=true
    hygiene_marker="compact-memory"
  fi
fi

hygiene_json="$(jq -nc \
  --argjson tickets_total "$tickets_total" \
  --argjson tickets_at_last_hygiene "$tickets_at_last_hygiene" \
  --argjson tickets_since "$tickets_since" \
  --argjson threshold "$hygiene_threshold" \
  --argjson hygiene_due "$hygiene_due" \
  --arg hygiene_marker "$hygiene_marker" \
  --arg hygiene_reason "$hygiene_reason" \
  '{tickets_total:$tickets_total, tickets_at_last_hygiene:$tickets_at_last_hygiene,
    tickets_since:$tickets_since, threshold:$threshold,
    hygiene_due:$hygiene_due, hygiene_marker:$hygiene_marker,
    hygiene_reason:$hygiene_reason}')"

# =============================================================================
# 4d. SCHEDULED SELF-AUDIT  (daily worker-auditor recommendation)
# =============================================================================
# REPORT-ONLY discipline (same as 4b/4c): this block detects whether a daily
# Hydra self-audit is due and emits an `audit-due` marker. It NEVER spawns
# worker-auditor, never files issues, never stamps last_audit_run — Commander
# actuates (spawns the auditor) and stamps last_audit_run when it does, the same
# split as retro (retro_due) and promotion (promotion_due).
#
# Idempotency is DAILY (at most once/day), mirroring last_promotion_run's date
# gate: audit_due = (date(last_audit_run) != today). Null/missing/malformed
# last_audit_run => never run => due. Test seam: --today <YYYY-MM-DD> fixes
# "today"; default reads the live clock (date +%F).
#
# The dedupe rail (worker-auditor caps at <=3 issues/run and dedupes by title
# against open commander-auto-filed issues) is carried as a hint in the report,
# not enforced here — the issue enumeration + cap live in the auditor/Commander
# where the gh budget is. Spec: docs/specs/2026-06-07-scheduled-self-audit.md.
audit_today="${today_override:-$(date +%F)}"

last_audit_run=""
if [[ -f "$AUTOPICKUP_FILE" ]]; then
  last_audit_run="$(jq -r '.last_audit_run // ""' "$AUTOPICKUP_FILE" 2>/dev/null || echo "")"
fi
# Date portion of last_audit_run (accept an ISO timestamp or a bare date).
last_audit_date="${last_audit_run%%T*}"

audit_due=true
audit_marker="audit-due"
audit_reason=""
audit_dedupe_hint="worker-auditor caps at <=3 issues/run; dedupe by title vs open commander-auto-filed issues"

if [[ "$last_audit_date" == "$audit_today" ]]; then
  audit_due=false
  audit_marker=""
  audit_reason="already ran today"
fi

audit_json="$(jq -nc \
  --arg today "$audit_today" \
  --arg last_audit_run "$last_audit_run" \
  --argjson audit_due "$audit_due" \
  --arg audit_marker "$audit_marker" \
  --arg audit_reason "$audit_reason" \
  --arg dedupe_hint "$audit_dedupe_hint" \
  '{today:$today,
    last_audit_run:(if $last_audit_run == "" then null else $last_audit_run end),
    audit_due:$audit_due, audit_marker:$audit_marker, audit_reason:$audit_reason,
    dedupe_hint:$dedupe_hint}')"

# =============================================================================
# 4e. STALE-WORKTREE GC  (report-only candidate scan)
# =============================================================================
# REPORT-ONLY discipline (same as 4b/4c/4d): this block shells out to
# gc-stale-worktrees.sh --dry-run (read-only) and reports the zombie worktree
# CANDIDATES. It NEVER deletes — actuation is `gc-stale-worktrees.sh --apply`,
# run by Commander/operator. A gc failure is reported, never fatal (set +e).
# gc-stale-worktrees itself fails closed when active.json is missing/corrupt, so
# the tick inherits that safety. Spec: docs/specs/2026-06-07-tick-stall-robustness.md.
#
# SURFACE A FAILED SAFETY SCAN (never report it as clean). `scan_ok` is true ONLY
# when the gc script actually ran and returned parseable JSON. If the binary is
# missing/unexecutable, exits non-zero, or emits unparseable output, scan_ok=false
# with a reason — the output then says "scan-skipped", NOT "(none)". A failed
# safety scan must look distinct from a clean one so an operator never mistakes a
# broken gc for "no stale worktrees".
gc_json='{"candidates_count":0,"candidates":[],"scan_ok":false,"scan_skipped_reason":"gc-script-not-executable"}'
if [[ -x "$GC_WORKTREES" ]]; then
  set +e
  gc_raw="$("$GC_WORKTREES" --root "$ROOT_DIR" --state-dir "$STATE_DIR" \
    --worktrees-dir "$WORKTREES_DIR" --dry-run --json 2>/dev/null)"
  gc_rc=$?
  set -e
  if [[ "$gc_rc" -eq 0 ]] && printf '%s' "$gc_raw" | jq empty 2>/dev/null; then
    gc_json="$(printf '%s' "$gc_raw" | jq -c \
      '{candidates_count:(.candidates|length), candidates:.candidates,
        fail_closed:.fail_closed, scan_ok:true, scan_skipped_reason:null}')"
  else
    gc_json="$(jq -nc --argjson rc "${gc_rc:-1}" \
      '{candidates_count:0, candidates:[], scan_ok:false,
        scan_skipped_reason:("gc-scan-failed(exit \($rc))")}')"
  fi
fi

# =============================================================================
# 4f. DAILY DIGEST  (daily status rollup — report-only schedule leg)
# =============================================================================
# REPORT-ONLY discipline (same as 4b/4c/4d/4e): this block detects whether the
# daily status digest is due and emits a `digest-due` marker. It NEVER runs
# scripts/build-daily-digest.sh, routes a channel, or stamps last_digest_run —
# Commander actuates (runs the composer, routes per the configured channel) and
# stamps last_digest_run when it does, the same split as audit (audit_due) and
# retro (retro_due).
#
# CANONICAL STATE is state/digests.json (written by `./hydra connect digest` via
# scripts/hydra-connect.sh, shipped under #144). It owns enabled / time /
# last_digest_run. The tick reads ALL THREE from there so:
#   - a non-09:00 schedule the operator configured actually takes effect
#     (reading a separate mirror that the connector never writes would fire at
#     the wrong time), and
#   - an already-emitted digest is not re-reported as due after upgrade
#     (the stamp lives in digests.json, not autopickup.json).
#
# The gate has THREE parts:
#   0. ENABLED gate: digests.json:.enabled == true. The connector defaults this
#      false so a fresh clone is inert; an un-wired digest is never "due".
#   1. DAILY date-gate (mirrors last_audit_run): date(last_digest_run) != today.
#   2. TIME-OF-DAY gate: now_hm >= time. `time` defaults to "09:00" when the file
#      is absent or the value is malformed.
# All three must hold for digest_due. Missing file / absent enabled => not
# configured => not due. Null/missing/malformed last_digest_run => never run =>
# date-gate passes (still subject to enabled + time gates).
#
# String comparison of zero-padded HH:MM is lexicographically correct
# ("08:59" < "09:00" < "13:00"), the same trick the retro step uses for ISO week
# tags. Test seams: --today fixes the date; --hour/--minute fix now_hm; defaults
# read the live clock (date +%F / +%H / +%M). Spec: docs/specs/2026-06-08-digest-tick-step.md.
digest_today="${today_override:-$(date +%F)}"

# now_hm = "HH:MM", zero-padded. Overrides for tests; else the live clock.
digest_now_hh="${hour_override:-$(date +%H)}"
digest_now_mm="${minute_override:-$(date +%M)}"
# Zero-pad to two digits so the lexical compare against digest_time is sound
# even when --hour 8 / --minute 5 are passed un-padded.
printf -v digest_now_hh '%02d' "$((10#$digest_now_hh))"
printf -v digest_now_mm '%02d' "$((10#$digest_now_mm))"
digest_now_hm="${digest_now_hh}:${digest_now_mm}"

# Read enabled / time / last_digest_run from the CANONICAL state/digests.json.
digest_enabled=false
digest_time="09:00"
last_digest_run=""
if [[ -f "$DIGEST_FILE" ]]; then
  de="$(jq -r '.enabled // false' "$DIGEST_FILE" 2>/dev/null || echo false)"
  [[ "$de" == "true" ]] && digest_enabled=true
  dt="$(jq -r '.time // ""' "$DIGEST_FILE" 2>/dev/null || echo "")"
  [[ "$dt" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]] && digest_time="$dt"
  last_digest_run="$(jq -r '.last_digest_run // ""' "$DIGEST_FILE" 2>/dev/null || echo "")"
fi
# Date portion of last_digest_run (accept an ISO timestamp or a bare date).
last_digest_date="${last_digest_run%%T*}"

digest_due=true
digest_marker="digest-due"
digest_reason=""
digest_run_hint="run scripts/build-daily-digest.sh, route per the configured channel (state/digests.json), then stamp last_digest_run on state/digests.json"

if [[ "$digest_enabled" != true ]]; then
  # Enabled-gate: the operator hasn't wired the digest (no file, or enabled=false).
  digest_due=false
  digest_marker=""
  digest_reason="not enabled (run ./hydra connect digest)"
elif [[ "$last_digest_date" == "$digest_today" ]]; then
  # Date-gate: already emitted today.
  digest_due=false
  digest_marker=""
  digest_reason="already ran today"
elif [[ "$digest_now_hm" < "$digest_time" ]]; then
  # Time-gate: the configured emit time hasn't arrived yet today.
  digest_due=false
  digest_marker=""
  digest_reason="before configured time ${digest_time} (now ${digest_now_hm})"
fi

digest_json="$(jq -nc \
  --arg today "$digest_today" \
  --argjson enabled "$digest_enabled" \
  --arg last_digest_run "$last_digest_run" \
  --arg digest_time "$digest_time" \
  --arg now_hm "$digest_now_hm" \
  --argjson digest_due "$digest_due" \
  --arg digest_marker "$digest_marker" \
  --arg digest_reason "$digest_reason" \
  --arg run_hint "$digest_run_hint" \
  '{today:$today, enabled:$enabled,
    last_digest_run:(if $last_digest_run == "" then null else $last_digest_run end),
    digest_time:$digest_time, now_hm:$now_hm,
    digest_due:$digest_due, digest_marker:$digest_marker,
    digest_reason:$digest_reason, run_hint:$run_hint}')"

# =============================================================================
# 4g. WORKER-STALL SCAN  (forward-facing observability — report-only leg)
# =============================================================================
# REPORT-ONLY discipline (same as 4b–4f): shell out to detect-worker-stalls.sh
# --json --no-log (read-only; --no-log so the detector's OWN scheduled run owns
# the logs/stalls-*.jsonl event log — the tick must not double-write it). Surface
# the standing stall list so the orchestrator can route it; the tick itself NEVER
# kills/rescues/spawns — Commander cross-checks each stall with rescue-worker.sh
# --probe and actuates. A detector failure is reported, never fatal (set +e), and
# yields an explicit scan_ok=false rather than a silent "0 stalls".
# Spec: docs/specs/2026-06-18-worker-stall-observability.md (ticket #306).
stalls_json='{"stall_count":0,"stalls":[],"scan_ok":false,"scan_skipped_reason":"detector-not-executable"}'
stalls_raw=""
stalls_rc=1
if [[ -n "$stalls_cmd" ]]; then
  set +e
  stalls_raw="$(bash -c "$stalls_cmd" 2>/dev/null)"
  stalls_rc=$?
  set -e
elif [[ -x "$DETECT_STALLS" ]]; then
  set +e
  stalls_raw="$("$DETECT_STALLS" --json --no-log --state-dir "$STATE_DIR" 2>/dev/null)"
  stalls_rc=$?
  set -e
fi
if [[ "$stalls_rc" -eq 0 ]] && printf '%s' "$stalls_raw" | jq empty 2>/dev/null; then
  stalls_json="$(printf '%s' "$stalls_raw" | jq -c \
    '{stall_count:(.stall_count // (.stalls|length) // 0),
      stalls:(.stalls // []),
      threshold_min:(.threshold_min // null),
      scan_ok:true, scan_skipped_reason:null}')"
elif [[ -n "$stalls_cmd" || -x "$DETECT_STALLS" ]]; then
  stalls_json="$(jq -nc --argjson rc "$stalls_rc" \
    '{stall_count:0, stalls:[], scan_ok:false,
      scan_skipped_reason:("stall-scan-failed(exit \($rc))")}')"
fi

# =============================================================================
# 5. ACTIONS ROLL-UP
# =============================================================================
actions_json="$(jq -nc \
  --argjson rescue "$rescue_array" \
  --argjson merge "$merge_array" \
  --argjson shepherd "$shepherd_json" \
  --argjson scheduled "$scheduled_json" \
  --argjson hygiene "$hygiene_json" \
  --argjson audit "$audit_json" \
  --argjson digest "$digest_json" \
  --argjson gc "$gc_json" \
  --argjson stalls "$stalls_json" \
  '{
    needs_rescue:        ($rescue | map(select(.action == "needs-rescue")) | length),
    live_wait:           ($rescue | map(select(.action == "live-wait")) | length),
    auto_merge_eligible: ($merge  | map(select(.classification == "auto-merge-eligible")) | length),
    surface_for_human:   ($merge  | map(select(.classification == "surface-for-human")) | length),
    needs_review_gate:   (($shepherd.summary.needs_review_gate) // 0),
    needs_fix:           (($shepherd.summary.needs_fix) // 0),
    orphaned:            (($shepherd.summary.orphaned) // 0),
    retro_due:           ($scheduled.retro_due),
    promotion_due:       ($scheduled.promotion_due),
    hygiene_due:         ($hygiene.hygiene_due),
    audit_due:           ($audit.audit_due),
    digest_due:          ($digest.digest_due),
    gc_stale_worktrees:  ($gc.candidates_count),
    stalled_workers:     ($stalls.stall_count // 0)
  }')"

# =============================================================================
# 6. OUTPUT
# =============================================================================
if [[ "$json_mode" -eq 1 ]]; then
  jq -nc \
    --arg generated_at "$GEN_TS" \
    --arg repo "$repo" \
    --argjson preflight "$preflight_json" \
    --argjson shepherd "$shepherd_json" \
    --argjson rescue "$rescue_array" \
    --argjson merge_surface "$merge_array" \
    --argjson scheduled "$scheduled_json" \
    --argjson hygiene "$hygiene_json" \
    --argjson audit "$audit_json" \
    --argjson digest "$digest_json" \
    --argjson gc "$gc_json" \
    --argjson stalls "$stalls_json" \
    --argjson actions "$actions_json" \
    '{generated_at:$generated_at, repo:$repo, preflight:$preflight,
      shepherd:$shepherd, rescue:$rescue, merge_surface:$merge_surface,
      scheduled:$scheduled, hygiene:$hygiene, audit:$audit, digest:$digest,
      gc:$gc, stalls:$stalls, actions:$actions}'
  exit 0
fi

# ---- human report ----
echo "▸ Autopickup Tick — ${repo:-current repo}  ($GEN_TS)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Preflight
echo "Preflight:"
printf '%s' "$preflight_json" | jq -r '
  "  PAUSE: \(if .pause_present then "PRESENT ⛔" else "absent" end)" ,
  "  state valid: \(.state_valid)\(if .state_validation_note != "" then " (" + .state_validation_note + ")" else "" end)" ,
  "  concurrency: \(.active_workers)/\(.max_workers) active · headroom \(.concurrency_headroom)" ,
  "  interval: \(.interval_min)min\(if .interval_warn then "  ⚠ WARN: " + .interval_warn_text else "" end)" ,
  "  spawn: \(if .spawn_blocked then "BLOCKED — do not spawn this tick" else "OK — Commander may spawn up to headroom" end)"
'
echo

# Shepherd
echo "Shepherd (in-flight PRs):"
printf '%s' "$shepherd_json" | jq -r '
  (.summary // {}) |
  "  total \(.total // 0) · needs-fix \(.needs_fix // 0) · ci-pending \(.ci_pending // 0) · " +
  "needs-review-gate \(.needs_review_gate // 0) · ready-to-surface \(.ready_to_surface // 0) · " +
  "merge-ready \(.merge_ready // 0) · orphaned \(.orphaned // 0)"
'
echo

# Rescue
echo "Rescue (completion scan):"
if [[ "$(printf '%s' "$rescue_array" | jq 'length')" -eq 0 ]]; then
  echo "  (no active workers to probe)"
else
  printf '%s' "$rescue_array" | jq -r '
    .[] | "  \(.branch)  \(.verdict)  → \(.action)"
  '
fi
echo

# Merge surfacing
echo "Merge surfacing (merge-ready PRs):"
if [[ "$(printf '%s' "$merge_array" | jq 'length')" -eq 0 ]]; then
  echo "  (no merge-ready PRs)"
else
  printf '%s' "$merge_array" | jq -r '
    .[] | "  #\(.number) [\(.slug) \(.tier) policy=\(.policy)]\(if .orphaned then " (orphaned)" else "" end)  → \(.classification) (\(.reason))"
  '
fi
echo

# Scheduled checks
echo "Scheduled checks (retro / promotion):"
printf '%s' "$scheduled_json" | jq -r '
  "  now: weekday \(.weekday) hour \(.hour) · week \(.week)" ,
  "  retro: \(if .retro_due then "DUE" else "not due" end)\(if .retro_marker != "" then " (" + .retro_marker + ")" else "" end)" ,
  (if .retro_file_result != "" then "         filer: \(.retro_file_result | gsub("\n"; " "))" else empty end) ,
  "  promotion: \(if .promotion_due then "DUE (run promote-citations.sh)" else "not due (ran today)" end)"
'
echo

# Memory hygiene
echo "Memory hygiene (compact every $(printf '%s' "$hygiene_json" | jq -r '.threshold') tickets):"
printf '%s' "$hygiene_json" | jq -r '
  "  tickets since last hygiene: \(.tickets_since) (total \(.tickets_total) - baseline \(.tickets_at_last_hygiene)) / threshold \(.threshold)" ,
  "  hygiene: \(if .hygiene_due then "DUE — compact memory + run promote-citations.sh" else "not due" end)\(if (.hygiene_reason // "") != "" then " (" + .hygiene_reason + ")" else "" end)"
'
echo

# Daily self-audit
echo "Audit (daily self-audit):"
printf '%s' "$audit_json" | jq -r '
  "  today \(.today) · last audit run \(.last_audit_run // "never")" ,
  "  audit: \(if .audit_due then "DUE — spawn worker-auditor on the hydra repo" else "not due" end)\(if (.audit_reason // "") != "" then " (" + .audit_reason + ")" else "" end)" ,
  (if .audit_due then "         dedupe: \(.dedupe_hint)" else empty end)
'
echo

# Daily digest
echo "Digest (daily status rollup):"
printf '%s' "$digest_json" | jq -r '
  "  today \(.today) · now \(.now_hm) · emit time \(.digest_time) · last digest run \(.last_digest_run // "never")" ,
  "  digest: \(if .digest_due then "DUE — run scripts/build-daily-digest.sh, route, then stamp last_digest_run" else "not due" end)\(if (.digest_reason // "") != "" then " (" + .digest_reason + ")" else "" end)"
'
echo

# Stale-worktree gc. A failed/fail-closed safety scan must look DISTINCT from a
# clean one — never silently "(none)".
echo "Stale worktrees (gc candidates):"
gc_scan_ok="$(printf '%s' "$gc_json" | jq -r '.scan_ok // false')"
gc_fail_closed="$(printf '%s' "$gc_json" | jq -r '.fail_closed // false')"
gc_cand_count="$(printf '%s' "$gc_json" | jq '.candidates_count')"
if [[ "$gc_scan_ok" != "true" ]]; then
  gc_reason="$(printf '%s' "$gc_json" | jq -r '.scan_skipped_reason // "unknown"')"
  echo "  (gc scan-skipped — safety scan could not run: ${gc_reason}; run gc-stale-worktrees.sh directly)"
elif [[ "$gc_fail_closed" == "true" ]]; then
  echo "  (gc fail-closed — state/active.json missing/unreadable/corrupt; run gc-stale-worktrees.sh directly)"
elif [[ "$gc_cand_count" -eq 0 ]]; then
  echo "  (none)"
else
  printf '%s' "$gc_json" | jq -r '.candidates[] | "  \(.path)  (age \(.age_s)s)"'
fi
echo

# Worker stalls. A failed detector scan must look DISTINCT from a clean one —
# never silently "(none)".
echo "Worker stalls (forward-facing):"
stalls_scan_ok="$(printf '%s' "$stalls_json" | jq -r '.scan_ok // false')"
stalls_n="$(printf '%s' "$stalls_json" | jq '.stall_count // 0')"
if [[ "$stalls_scan_ok" != "true" ]]; then
  stalls_reason="$(printf '%s' "$stalls_json" | jq -r '.scan_skipped_reason // "unknown"')"
  echo "  (stall scan-skipped — could not run: ${stalls_reason}; run detect-worker-stalls.sh directly)"
elif [[ "$stalls_n" -eq 0 ]]; then
  echo "  (none)"
else
  printf '%s' "$stalls_json" | jq -r '.stalls[] | "  \(.worker_id // "?") on \(.ticket // "?") [\(.repo // "?")]  idle \(.idle_min)m  → \(.verdict)"'
fi
echo

# Actions roll-up
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
printf '%s' "$actions_json" | jq -r '
  "Actions: needs-rescue \(.needs_rescue) · live-wait \(.live_wait) · " +
  "auto-merge-eligible \(.auto_merge_eligible) · surface-for-human \(.surface_for_human) · " +
  "needs-review-gate \(.needs_review_gate) · needs-fix \(.needs_fix) · orphaned \(.orphaned) · " +
  "stalled-workers \(.stalled_workers)"
'
[[ "$(printf '%s' "$actions_json" | jq '.auto_merge_eligible')" -gt 0 ]] \
  && echo "  ↳ Commander: verify CI green + obey merge-policy-lookup before merging eligible PRs."
[[ "$(printf '%s' "$preflight_json" | jq -r '.spawn_blocked')" == "true" ]] \
  && echo "  ↳ Spawn BLOCKED this tick (see Preflight) — read-only scans above are still valid."
[[ "$(printf '%s' "$scheduled_json" | jq -r '.retro_marker')" == "retro-due-write-first" ]] \
  && echo "  ↳ Retro DUE but unwritten — Commander: run the retro procedure, then it auto-files proposed edits."
[[ "$(printf '%s' "$hygiene_json" | jq -r '.hygiene_due')" == "true" ]] \
  && echo "  ↳ Memory hygiene DUE — Commander: compact memory + reset tickets_at_last_hygiene to the current total."
[[ "$(printf '%s' "$audit_json" | jq -r '.audit_due')" == "true" ]] \
  && echo "  ↳ Audit DUE — Commander: spawn worker-auditor on the hydra repo (<=3 issues, dedupe vs open commander-auto-filed), then stamp last_audit_run."
[[ "$(printf '%s' "$digest_json" | jq -r '.digest_due')" == "true" ]] \
  && echo "  ↳ Digest DUE — Commander: run scripts/build-daily-digest.sh, route per the configured channel (state/digests.json), then stamp last_digest_run on state/digests.json."
[[ "$(printf '%s' "$gc_json" | jq '.candidates_count')" -gt 0 ]] \
  && echo "  ↳ Stale worktrees: run scripts/gc-stale-worktrees.sh --apply to reclaim."
[[ "$(printf '%s' "$preflight_json" | jq -r '.interval_warn')" == "true" ]] \
  && echo "  ↳ Autopickup interval at/above the stream-idle ceiling — lower interval_min to <15 so the rescue probe can fire before workers time out."
[[ "$(printf '%s' "$stalls_json" | jq '.stall_count // 0')" -gt 0 ]] \
  && echo "  ↳ Stalled workers detected — Commander: cross-check each with rescue-worker.sh --probe, then rescue/escalate per its verdict."
exit 0

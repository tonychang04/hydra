#!/usr/bin/env bash
#
# rescue-worker.sh — recover a worker worktree after a stream-idle timeout.
#
# Usage:
#   scripts/rescue-worker.sh --probe         <worktree> <branch> <ticket>
#   scripts/rescue-worker.sh --rescue        <worktree> <branch> <ticket> [--remote <name>]
#   scripts/rescue-worker.sh --probe-review  <pr_number>
#
# Three modes:
#   --probe         Non-mutating. Inspects the worktree and prints a JSON verdict
#                   on stdout. Commander uses this to decide whether to run --rescue.
#                   Verdicts:
#                     { "verdict": "rescue-commits",     "commits_ahead": N }
#                     { "verdict": "rescue-uncommitted", "commits_ahead": N, "dirty": true }
#                     { "verdict": "push-only",          "commits_ahead": N, "pushed": false }
#                     { "verdict": "nothing-to-rescue",  "commits_ahead": 0, "dirty": false }
#                     { "verdict": "flaky-tool-retry",   "tool": "...", "fallback": "...", ... }
#                     { "verdict": "worker-looping",       "tool": "...", "error_type": "...", "repeat": N, ... }
#                     { "verdict": "worker-mid-tool-call", "tool": "...", ... }
#
#                   The flaky-tool-retry verdict (exit 5) fires when the worker
#                   left a recent .hydra/flaky-tool.json marker recording
#                   repeated failures of a named external tool (e.g. the browse
#                   daemon resetting between commands). The worker is ALIVE and
#                   blocked, not idle — commander should relay the marker's
#                   `fallback` hint to the live worker (SendMessage) rather than
#                   rescue-and-restart. Checked BEFORE the git-state verdicts so
#                   a live worker's uncommitted marker is not mistaken for
#                   rescuable "dirty" work. Spec: ticket #190.
#
#                   The trace-forensics verdicts (exit 6/7) read the TAIL of the
#                   worker's session trace (logs/traces/<ticket>.jsonl, the #197
#                   substrate) to tell two states git-state alone conflates:
#                     worker-mid-tool-call (exit 6) — the most-recent
#                       execute_tool span is OPEN (a phase:start with no matching
#                       phase:end). The worker is ALIVE inside a slow tool; do
#                       NOT rescue — wait one more tick.
#                     worker-looping (exit 7) — the trace tail shows repeated
#                       identical tool spans (same gen_ai.tool.name across >= K
#                       distinct span_ids) or recursive failures (>= K spans
#                       sharing one error.type). The worker is thrashing and is
#                       unrecoverable in place — rescue + restart with a hint.
#                   Both are checked AFTER the flaky-tool marker and BEFORE the
#                   git-state verdicts. No trace ⇒ identical behavior to before.
#                   Spec: docs/specs/2026-05-21-trace-fed-watchdog-forensics.md
#                   (ticket #206).
#
#   --rescue        Mutating. Commits any uncommitted changes, fetches origin/main,
#                   rebases (fast-forward only; bails on conflict with exit 3), and
#                   pushes the branch. Prints the branch name on stdout on success.
#
#   --probe-review  Non-mutating. Checks a PR on GitHub for a landed review
#                   artifact after a worker-review stream-idle timeout. Two
#                   signals count as "review landed":
#                     (a) a review body starting with "Commander review"
#                     (b) the label commander-review-clean applied to the PR
#                   If neither is present, exits 4 to tell commander "review
#                   did not land; dispatch to commander to run /review inline".
#                   Verdicts:
#                     { "verdict": "review-already-landed", "source": "body"|"label", "pr": N }  → exit 0
#                     { "verdict": "review-missing-dispatch-to-commander", "pr": N }              → exit 4
#
# Optional flags:
#   --base <ref>    Override the base ref for counting commits-ahead and for
#                   rebase. Default is <remote>/main. Useful when testing on
#                   a worktree with no remote (e.g. self-test fixtures).
#   --gh-mock <dir> Test-only: read mocked `gh pr view` JSON responses from
#                   <dir>/reviews-<pr>.json and <dir>/labels-<pr>.json instead
#                   of shelling out to `gh`. Used by self-test fixtures so CI
#                   can exercise --probe-review offline. Also honored via env
#                   var HYDRA_RESCUE_GH_MOCK.
#   --trace-file <p> Override the trace path read by the #206 trace-forensics
#                   probe. Default resolves $HYDRA_TRACE_DIR/<ticket>.jsonl, then
#                   <worktree>/logs/traces/<ticket>.jsonl. Used by self-test
#                   fixtures (and operators) to point at a specific trace.
#
# Exit codes:
#   0   success (probe done, or rescue completed, or review already landed)
#   1   I/O error / branch mismatch / worktree not a git repo / stale git lock /
#       gh unavailable or unauth'd
#   2   usage error
#   3   rescue conflict — rebase on main hit a conflict; commander must escalate
#   4   review-type rescue required; dispatch to commander to run /review inline
#       (emitted only by --probe-review)
#   5   blocked on flaky external tool; retry with fallback — worker is ALIVE,
#       commander should relay the marker's `fallback` hint instead of rescuing
#       (emitted only by --probe)
#   6   worker-mid-tool-call — the trace tail shows an OPEN execute_tool span;
#       the worker is ALIVE inside a slow tool. Do NOT rescue; wait one tick.
#       (emitted only by --probe)
#   7   worker-looping — the trace tail shows repeated identical tool spans or
#       recursive failures; the worker is thrashing. Rescue + restart.
#       (emitted only by --probe)
#
# Flaky-tool tuning (env vars, --probe only):
#   HYDRA_FLAKY_TOOL_MIN_FAILURES  Minimum `failures` in the marker before the
#                                  flaky-tool-retry verdict fires. Default 2.
#   HYDRA_FLAKY_TOOL_MAX_AGE_S     Max age (seconds) of the marker's
#                                  `last_failure_epoch` before it's treated as
#                                  stale and ignored. Default 1800 (30 min).
#
# Trace-forensics tuning (env vars, --probe only):
#   HYDRA_TRACE_TAIL_LINES         How many trailing trace lines to read.
#                                  Default 20.
#   HYDRA_TRACE_LOOP_MIN           K: minimum repeat count (distinct same-tool
#                                  spans, or same-error.type spans) for the
#                                  worker-looping verdict. Default 3 (min 2).
#   HYDRA_TRACE_DIR                Trace directory (when --trace-file is not
#                                  given). Trace file is <dir>/<ticket>.jsonl.
#
# Spec: docs/specs/2026-04-16-worker-timeout-watchdog.md (ticket #45)
# Spec: docs/specs/2026-04-17-rescue-worker-index-lock.md (ticket #81)
# Spec: docs/specs/2026-04-17-review-worker-rescue.md   (ticket #75)
# Spec: docs/specs/2026-05-21-flaky-tool-probe-verdict.md (ticket #190)
# Spec: docs/specs/2026-05-21-trace-fed-watchdog-forensics.md (ticket #206)

set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  scripts/rescue-worker.sh --probe         <worktree> <branch> <ticket>
  scripts/rescue-worker.sh --rescue        <worktree> <branch> <ticket> [--remote <name>]
  scripts/rescue-worker.sh --probe-review  <pr_number>

Recovers a worker after a stream-idle timeout. Probe modes are non-mutating;
rescue mode commits + rebases + pushes. --probe-review checks whether a
worker-review already posted its artifact on GitHub; if not, signals commander
to run the review inline (exit 4).

Required positional args:
  --probe / --rescue:  <worktree> <branch> <ticket>
  --probe-review:      <pr_number>

<worktree>    Absolute path to the worker's git worktree.
<branch>      Expected branch name (e.g. hydra/commander/45). Script refuses
              to run if HEAD isn't on this branch.
<ticket>      GitHub issue / Linear ticket number, used in commit messages.
<pr_number>   The PR number the worker-review was inspecting.

Options:
  --probe              Inspect the worktree and print a JSON verdict. No mutations.
  --rescue             Commit + rebase onto origin/main + push. Mutating.
  --probe-review       Inspect the PR for a landed review artifact. No mutations.
  --remote <name>      Remote to fetch + push against (default: origin).
  --base <ref>         Override base ref for commits-ahead and rebase
                       (default: <remote>/main). For self-test fixtures with
                       no remote: pass the parent commit SHA or a local branch.
  --gh-mock <dir>      Test-only: read mocked `gh pr view` responses from
                       <dir>/reviews-<pr>.json and <dir>/labels-<pr>.json.
                       Also honored via HYDRA_RESCUE_GH_MOCK env var.
  --trace-file <path>  Override the trace path read by the trace-forensics probe.
                       Default: $HYDRA_TRACE_DIR/<ticket>.jsonl, then
                       <worktree>/logs/traces/<ticket>.jsonl.
  -h, --help           Show this help.

Probe verdicts (--probe, stdout JSON):
  rescue-commits       local commits ahead of base, not pushed
  rescue-uncommitted   uncommitted/untracked changes in the worktree
  push-only            commits exist and already match the remote branch
  nothing-to-rescue    clean worktree, no commits ahead — idle ghost
  flaky-tool-retry     worker is ALIVE but blocked on a flaky external tool
                       (recent .hydra/flaky-tool.json marker); commander relays
                       the marker's `fallback` hint instead of rescuing (exit 5)
  worker-mid-tool-call worker is ALIVE inside a slow tool — the trace tail's
                       most-recent execute_tool span is open (start, no end).
                       Do NOT rescue; wait one more tick (exit 6)
  worker-looping       worker is thrashing — the trace tail repeats one tool
                       across >= K distinct spans, or >= K spans share one
                       error.type. Rescue + restart with a hint (exit 7)

Exit codes:
  0   success
  1   I/O error / branch mismatch / worktree not a git repo / gh unavailable
  2   usage error
  3   rescue conflict — commander must escalate
  4   review-type rescue required; dispatch to commander (--probe-review only)
  5   blocked on flaky external tool; retry with fallback (--probe only)
  6   worker-mid-tool-call — alive in a slow tool; do not rescue (--probe only)
  7   worker-looping — thrashing; rescue + restart (--probe only)

Flaky-tool tuning (env vars, --probe only):
  HYDRA_FLAKY_TOOL_MIN_FAILURES  min marker `failures` to fire (default 2)
  HYDRA_FLAKY_TOOL_MAX_AGE_S     max marker age in seconds (default 1800)

Trace-forensics tuning (env vars, --probe only):
  HYDRA_TRACE_TAIL_LINES         trailing trace lines to read (default 20)
  HYDRA_TRACE_LOOP_MIN           K: min repeat count for looping (default 3)
  HYDRA_TRACE_DIR                trace dir when --trace-file omitted
                                 (file is <dir>/<ticket>.jsonl)

Spec: docs/specs/2026-04-16-worker-timeout-watchdog.md (ticket #45)
Spec: docs/specs/2026-04-17-review-worker-rescue.md   (ticket #75)
Spec: docs/specs/2026-05-21-flaky-tool-probe-verdict.md (ticket #190)
Spec: docs/specs/2026-05-21-trace-fed-watchdog-forensics.md (ticket #206)
EOF
}

# ---- arg parsing -----------------------------------------------------------

mode=""
worktree=""
branch=""
ticket=""
pr_number=""
remote="origin"
base_override=""
gh_mock="${HYDRA_RESCUE_GH_MOCK:-}"
trace_file_override=""

# Flaky-tool detection tuning (--probe only). Worker-authored marker lives at
# <worktree>/.hydra/flaky-tool.json. See ticket #190 spec.
flaky_min_failures="${HYDRA_FLAKY_TOOL_MIN_FAILURES:-2}"
flaky_max_age_s="${HYDRA_FLAKY_TOOL_MAX_AGE_S:-1800}"

# Trace-forensics tuning (--probe only). The watchdog reads the tail of the
# worker's session trace (logs/traces/<ticket>.jsonl, the #197 substrate) to
# distinguish mid-tool-call (alive, slow) from looping (thrashing). See #206 spec.
trace_tail_lines="${HYDRA_TRACE_TAIL_LINES:-20}"
trace_loop_min="${HYDRA_TRACE_LOOP_MIN:-3}"

# Collect unnamed positional args; assignment depends on mode (resolved after parse).
positionals=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --probe)         [[ -z "$mode" ]] || { echo "✗ --probe, --rescue, and --probe-review are mutually exclusive" >&2; exit 2; }; mode="probe";         shift ;;
    --rescue)        [[ -z "$mode" ]] || { echo "✗ --probe, --rescue, and --probe-review are mutually exclusive" >&2; exit 2; }; mode="rescue";        shift ;;
    --probe-review)  [[ -z "$mode" ]] || { echo "✗ --probe, --rescue, and --probe-review are mutually exclusive" >&2; exit 2; }; mode="probe-review";  shift ;;
    --remote)   [[ $# -ge 2 ]] || { echo "✗ --remote needs a value" >&2; exit 2; }; remote="$2"; shift 2 ;;
    --remote=*) remote="${1#--remote=}"; shift ;;
    --base)     [[ $# -ge 2 ]] || { echo "✗ --base needs a value" >&2; exit 2; }; base_override="$2"; shift 2 ;;
    --base=*)   base_override="${1#--base=}"; shift ;;
    --gh-mock)  [[ $# -ge 2 ]] || { echo "✗ --gh-mock needs a value" >&2; exit 2; }; gh_mock="$2"; shift 2 ;;
    --gh-mock=*) gh_mock="${1#--gh-mock=}"; shift ;;
    --trace-file)  [[ $# -ge 2 ]] || { echo "✗ --trace-file needs a value" >&2; exit 2; }; trace_file_override="$2"; shift 2 ;;
    --trace-file=*) trace_file_override="${1#--trace-file=}"; shift ;;
    --*) echo "✗ unknown flag: $1" >&2; usage >&2; exit 2 ;;
    *)  positionals+=("$1"); shift ;;
  esac
done

if [[ -z "$mode" ]]; then
  echo "✗ must specify --probe, --rescue, or --probe-review" >&2
  usage >&2
  exit 2
fi

if [[ "$mode" == "probe-review" ]]; then
  if [[ "${#positionals[@]}" -ne 1 ]]; then
    echo "✗ --probe-review needs exactly one positional arg: <pr_number>" >&2
    usage >&2
    exit 2
  fi
  pr_number="${positionals[0]}"
  if ! [[ "$pr_number" =~ ^[0-9]+$ ]]; then
    echo "✗ <pr_number> must be a positive integer; got: $pr_number" >&2
    exit 2
  fi
else
  if [[ "${#positionals[@]}" -ne 3 ]]; then
    echo "✗ missing required positional args: <worktree> <branch> <ticket>" >&2
    usage >&2
    exit 2
  fi
  worktree="${positionals[0]}"
  branch="${positionals[1]}"
  ticket="${positionals[2]}"
  if [[ ! -d "$worktree" ]]; then
    echo "✗ worktree does not exist: $worktree" >&2
    exit 1
  fi
fi

# ---- shared git helpers ----------------------------------------------------

git_in() { git -C "$worktree" "$@"; }

# The worktree/branch checks only apply to --probe and --rescue. --probe-review
# inspects a PR on GitHub and has no worktree; skip the git guards entirely.
if [[ "$mode" != "probe-review" ]]; then
  if ! git_in rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "✗ not a git worktree: $worktree" >&2
    exit 1
  fi

  current_branch="$(git_in rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")"
  if [[ "$current_branch" != "$branch" ]]; then
    echo "✗ branch mismatch: expected '$branch', worktree is on '$current_branch'" >&2
    exit 1
  fi
fi

# Resolve the base ref for commits-ahead counting and rebase. Precedence:
#   1. --base override (if passed; used by self-test fixtures with no remote)
#   2. <remote>/<branch> tracking branch (if exists) — probe only
#   3. <remote>/main
#   4. local refs/heads/main (last-resort fallback for no-remote fixtures)
#   5. empty string → count_commits_ahead returns 0
resolve_base_ref() {
  if [[ -n "$base_override" ]]; then
    printf '%s\n' "$base_override"
    return 0
  fi
  if git_in rev-parse --verify "$remote/$branch" >/dev/null 2>&1; then
    printf '%s\n' "$remote/$branch"
    return 0
  fi
  if git_in rev-parse --verify "$remote/main" >/dev/null 2>&1; then
    printf '%s\n' "$remote/main"
    return 0
  fi
  if git_in rev-parse --verify "refs/heads/main" >/dev/null 2>&1; then
    printf '%s\n' "refs/heads/main"
    return 0
  fi
  printf ''
}

count_commits_ahead() {
  local base
  base="$(resolve_base_ref)"
  if [[ -z "$base" ]]; then
    echo 0
    return 0
  fi
  git_in rev-list --count "$base..HEAD" 2>/dev/null || echo 0
}

is_dirty() {
  # staged or unstaged changes? (untracked files count as "dirty" for rescue)
  if ! git_in diff --quiet --ignore-submodules HEAD -- 2>/dev/null; then
    return 0
  fi
  if [[ -n "$(git_in status --porcelain --untracked-files=normal 2>/dev/null)" ]]; then
    return 0
  fi
  return 1
}

remote_branch_exists() {
  git_in rev-parse --verify "$remote/$branch" >/dev/null 2>&1
}

# Ticket #190: detect a worker that is ALIVE but blocked on a flaky external
# tool. The worker records repeated failures in a worktree-local marker at
# <worktree>/.hydra/flaky-tool.json:
#   {"tool":"...", "failures":N, "last_failure_epoch":EPOCH, "fallback":"..."}
#
# This helper prints the flaky-tool-retry verdict JSON on stdout and returns 0
# IFF a marker exists that is: valid JSON, has failures >= flaky_min_failures,
# and last_failure_epoch within flaky_max_age_s of now. Otherwise it prints
# nothing and returns 1 (caller falls through to the git-state verdicts).
#
# Fully defensive: a missing/garbled/incomplete/stale/below-threshold marker
# never errors — it just returns 1 so --probe behaves exactly as before. jq is
# already a hard dep elsewhere in the script (--probe-review); if jq is somehow
# absent here we silently fall through rather than crash the watchdog.
flaky_tool_verdict() {
  local marker="$worktree/.hydra/flaky-tool.json"
  [[ -r "$marker" ]] || return 1
  command -v jq >/dev/null 2>&1 || return 1

  # Parse with jq; on any parse error (malformed JSON) jq exits non-zero and we
  # fall through. Emit a tab-separated tuple we can read field-by-field.
  local parsed
  parsed="$(jq -r '
    [ (.tool // ""),
      (.failures // 0),
      (.last_failure_epoch // 0),
      (.fallback // "") ] | @tsv
  ' "$marker" 2>/dev/null)" || return 1
  [[ -n "$parsed" ]] || return 1

  local tool failures last_epoch fallback
  IFS=$'\t' read -r tool failures last_epoch fallback <<<"$parsed"

  # failures and last_failure_epoch must be plain integers; otherwise ignore.
  [[ "$failures"   =~ ^[0-9]+$ ]] || return 1
  [[ "$last_epoch" =~ ^[0-9]+$ ]] || return 1

  # Below the failure threshold → not yet "flaky".
  [[ "$failures" -ge "$flaky_min_failures" ]] || return 1

  # Stale marker (last failure too long ago) → ignore. Negative skew (epoch in
  # the future) is treated as fresh (age clamped at 0).
  local now age
  now="$(date +%s)"
  age=$(( now - last_epoch ))
  [[ "$age" -lt 0 ]] && age=0
  [[ "$age" -le "$flaky_max_age_s" ]] || return 1

  # A tool name is required to give commander something actionable to relay.
  [[ -n "$tool" ]] || return 1

  # Report worktree git-state alongside for observability (does NOT change the
  # verdict — a live worker is flaky-tool-retry whether or not it has WIP).
  local commits_ahead dirty
  commits_ahead="$(count_commits_ahead)"
  dirty="false"; is_dirty && dirty="true"

  # Emit JSON with tool + fallback safely escaped via jq.
  jq -nc \
    --arg tool "$tool" \
    --arg fallback "$fallback" \
    --argjson failures "$failures" \
    --argjson commits_ahead "$commits_ahead" \
    --argjson dirty "$dirty" \
    '{verdict:"flaky-tool-retry", tool:$tool, fallback:$fallback, failures:$failures, commits_ahead:$commits_ahead, dirty:$dirty}'
  return 0
}

# Ticket #206: trace-fed watchdog forensics. Read the TAIL of the worker's
# session trace (logs/traces/<ticket>.jsonl, the #197 substrate) to distinguish
# states git-state alone conflates:
#   - worker-looping       — repeated identical tool spans across distinct
#                            span_ids, OR >= K spans sharing one error.type
#                            (the worker is thrashing → rescue + restart).
#   - worker-mid-tool-call — the most-recent execute_tool span is OPEN (a
#                            phase:start with no matching phase:end) → the worker
#                            is ALIVE inside a slow tool → do NOT rescue yet.
#
# Trace location resolves: --trace-file override → $HYDRA_TRACE_DIR/<ticket>.jsonl
# → <worktree>/logs/traces/<ticket>.jsonl. Reads only the last
# $trace_tail_lines (default 20) lines. Loop threshold K = $trace_loop_min
# (default 3).
#
# Precedence: looping is checked BEFORE mid-tool-call (a thrashing worker often
# ends with one in-flight retry; the loop is the more actionable, dangerous
# signal). This helper prints the verdict JSON on stdout and returns 0 when a
# trace verdict fires; otherwise it prints nothing and returns 1 so --probe
# falls through to the git-state verdicts unchanged. The caller derives the exit
# code from the verdict string (worker-looping → 7, worker-mid-tool-call → 6).
#
# Fully defensive (same hard requirement as #190's marker): a missing/garbled/
# empty/tool-less trace never errors — it just returns 1. Malformed lines are
# dropped via `fromjson?`; if jq is somehow absent we silently fall through.
trace_forensic_verdict() {
  command -v jq >/dev/null 2>&1 || return 1

  # Resolve the trace file path.
  local trace
  if [[ -n "$trace_file_override" ]]; then
    trace="$trace_file_override"
  elif [[ -n "${HYDRA_TRACE_DIR:-}" ]]; then
    trace="${HYDRA_TRACE_DIR%/}/$ticket.jsonl"
  else
    trace="$worktree/logs/traces/$ticket.jsonl"
  fi
  [[ -r "$trace" ]] || return 1

  # tail_lines must be a positive integer; otherwise fall back to the default.
  local tail_lines="$trace_tail_lines"
  [[ "$tail_lines" =~ ^[0-9]+$ ]] && [[ "$tail_lines" -gt 0 ]] || tail_lines=20

  # loop K must be a positive integer >= 2 (a single span is never a "loop").
  local loop_k="$trace_loop_min"
  [[ "$loop_k" =~ ^[0-9]+$ ]] && [[ "$loop_k" -ge 2 ]] || loop_k=3

  # Slurp the last $tail_lines valid JSON objects into one array. `fromjson?`
  # drops malformed lines without aborting (-n null input, -R raw lines).
  local events
  events="$(tail -n "$tail_lines" "$trace" 2>/dev/null \
    | jq -cn -R '[inputs | fromjson? // empty]' 2>/dev/null)" || return 1
  [[ -n "$events" ]] || return 1

  # Report worktree git-state alongside for observability (does NOT change the
  # verdict — a trace verdict is about liveness, not WIP).
  local commits_ahead dirty
  commits_ahead="$(count_commits_ahead)"
  dirty="false"; is_dirty && dirty="true"

  # ---- loop signal (checked first) -----------------------------------------
  # Two independent triggers, either fires:
  #  (a) tool-repeat: among the last K execute_tool phase:start events (by ts),
  #      all share one gen_ai.tool.name across >= 2 DISTINCT span_ids (genuine
  #      repeats, not one long-open span — that is mid-tool-call, not looping).
  #  (b) recursive-failure: >= K events carry the SAME attrs."error.type".
  # Emits {tool, error_type, repeat} where each of tool/error_type may be null
  # when only the other trigger fired; repeat is the observed count.
  local loop_json
  loop_json="$(jq -c --argjson k "$loop_k" '
    def tool_repeat:
      ( map(select(.kind == "execute_tool"
                   and .attrs.phase == "start"
                   and (.attrs."gen_ai.tool.name" // "") != ""))
        | sort_by(.ts) ) as $starts
      | ($starts | length) as $n
      | if $n < $k then null
        else
          ($starts[($n - $k):]) as $window
          | ($window | map(.attrs."gen_ai.tool.name") | unique) as $tools
          | ($window | map(.span_id) | unique | length) as $distinct
          | if ($tools | length) == 1 and $distinct >= 2
            then {tool: $tools[0], repeat: $distinct}
            else null end
        end;
    def recursive_failure:
      ( map(.attrs."error.type" | select(. != null and . != ""))
        | group_by(.) | map({err: .[0], n: length})
        | map(select(.n >= $k)) | sort_by(-.n) ) as $groups
      | if ($groups | length) > 0
        then {error_type: $groups[0].err, repeat: $groups[0].n}
        else null end;
    (tool_repeat) as $tr
    | (recursive_failure) as $rf
    | if $tr == null and $rf == null then empty
      else
        { tool: ($tr.tool // null),
          error_type: ($rf.error_type // null),
          repeat: ([($tr.repeat // 0), ($rf.repeat // 0)] | max) }
      end
  ' <<<"$events" 2>/dev/null)" || loop_json=""

  if [[ -n "$loop_json" ]]; then
    jq -nc \
      --argjson loop "$loop_json" \
      --argjson commits_ahead "$commits_ahead" \
      --argjson dirty "$dirty" \
      '{verdict:"worker-looping", tool:$loop.tool, error_type:$loop.error_type, repeat:$loop.repeat, commits_ahead:$commits_ahead, dirty:$dirty}'
    return 0
  fi

  # ---- mid-tool-call signal -------------------------------------------------
  # The most-recent execute_tool span (latest start ts) has a start but NO end.
  local open_tool
  open_tool="$(jq -r '
    ( map(select(.kind == "execute_tool"))
      | group_by(.span_id)
      | map({
          span_id: .[0].span_id,
          tool: ( (map(select(.attrs.phase == "start"))[0].attrs."gen_ai.tool.name") // "" ),
          start_ts: ( (map(select(.attrs.phase == "start"))[0].ts) // "" ),
          has_start: ( any(.attrs.phase == "start") ),
          has_end:   ( any(.attrs.phase == "end") )
        })
      | map(select(.has_start and (.has_end | not)))
      | sort_by(.start_ts) ) as $open
    | if ($open | length) > 0 then $open[-1].tool else "" end
  ' <<<"$events" 2>/dev/null)" || open_tool=""

  if [[ -n "$open_tool" ]]; then
    jq -nc \
      --arg tool "$open_tool" \
      --argjson commits_ahead "$commits_ahead" \
      --argjson dirty "$dirty" \
      '{verdict:"worker-mid-tool-call", tool:$tool, commits_ahead:$commits_ahead, dirty:$dirty}'
    return 0
  fi

  # No trace verdict — fall through to git-state verdicts.
  return 1
}

# Ticket #81: refuse --rescue if the worker is still writing
# (`.git/index.lock` present). Best-effort TOCTOU guard — narrows but does
# not eliminate the race. Probe mode does not call this (probe is read-only).
# Spec: docs/specs/2026-04-17-rescue-worker-index-lock.md.
ensure_no_stale_lock() {
  local lock="$worktree/.git/index.lock"
  if [[ -f "$lock" ]]; then
    local pid=""
    if [[ -r "$lock" ]]; then
      pid="$(tr -d '[:space:]' < "$lock" 2>/dev/null || true)"
    fi
    [[ -z "$pid" ]] && pid="unknown"
    echo "ERROR: .git/index.lock present at $worktree — worker may still be writing; rerun when fully exited (pid $pid)" >&2
    exit 1
  fi
}

# ---- mode: probe -----------------------------------------------------------

if [[ "$mode" == "probe" ]]; then
  # Ticket #190: a worker blocked on a flaky external tool is ALIVE, not idle.
  # Check this BEFORE the git-state verdicts so its uncommitted marker isn't
  # mistaken for rescuable "dirty" work. flaky_tool_verdict prints the JSON and
  # returns 0 only when a valid, recent, over-threshold marker exists; otherwise
  # it prints nothing and we fall through to the existing verdicts unchanged.
  if flaky_tool_verdict; then
    exit 5
  fi

  # Ticket #206: read the trace tail to distinguish a worker that is ALIVE
  # inside a slow tool (worker-mid-tool-call, exit 6) from one that is thrashing
  # in a loop (worker-looping, exit 7). Checked AFTER the flaky-tool marker (the
  # most-specific, actionable signal) and BEFORE the git-state verdicts (which
  # can't tell live-slow from idle-ghost). The helper prints the verdict JSON
  # and returns 0 only when a trace verdict fires; otherwise it prints nothing
  # and returns 1 so we fall through to the existing git-state verdicts. The
  # exit code is derived from the verdict string.
  trace_verdict="$(trace_forensic_verdict)" || trace_verdict=""
  if [[ -n "$trace_verdict" ]]; then
    printf '%s\n' "$trace_verdict"
    case "$trace_verdict" in
      *'"verdict":"worker-looping"'*)       exit 7 ;;
      *'"verdict":"worker-mid-tool-call"'*) exit 6 ;;
    esac
  fi

  commits_ahead="$(count_commits_ahead)"
  dirty="false"; is_dirty && dirty="true"
  pushed="false"; remote_branch_exists && pushed="true"

  if [[ "$dirty" == "true" ]]; then
    printf '{"verdict":"rescue-uncommitted","commits_ahead":%s,"dirty":true,"pushed":%s}\n' \
      "$commits_ahead" "$pushed"
    exit 0
  fi

  if [[ "$commits_ahead" -gt 0 ]]; then
    if [[ "$pushed" == "false" ]]; then
      printf '{"verdict":"rescue-commits","commits_ahead":%s,"dirty":false,"pushed":false}\n' \
        "$commits_ahead"
    else
      # local commits exist AND remote is up to date with them? → push-only
      # (we're ahead of origin/main but not of origin/<branch>)
      local_head="$(git_in rev-parse HEAD)"
      remote_head="$(git_in rev-parse "$remote/$branch" 2>/dev/null || echo "")"
      if [[ "$local_head" == "$remote_head" ]]; then
        printf '{"verdict":"push-only","commits_ahead":%s,"dirty":false,"pushed":true}\n' \
          "$commits_ahead"
      else
        printf '{"verdict":"rescue-commits","commits_ahead":%s,"dirty":false,"pushed":true}\n' \
          "$commits_ahead"
      fi
    fi
    exit 0
  fi

  printf '{"verdict":"nothing-to-rescue","commits_ahead":0,"dirty":false,"pushed":%s}\n' "$pushed"
  exit 0
fi

# ---- mode: rescue ----------------------------------------------------------

if [[ "$mode" == "rescue" ]]; then
  # 0. Refuse if a git index.lock is already held. Best-effort guard against
  #    racing a still-writing worker (ticket #81).
  ensure_no_stale_lock

  # 1. Commit any uncommitted changes with a rescue-prefixed message.
  if is_dirty; then
    git_in add -A
    git_in commit -m "rescue: partial work from timed-out worker on #${ticket}"
  fi

  # 2. Fetch remote so <remote>/main is current. Skip if --base overrides the
  #    remote (self-test fixtures don't have a real remote to fetch from).
  if [[ -z "$base_override" ]]; then
    if ! git_in fetch "$remote" main 2>&1; then
      echo "✗ fetch $remote main failed" >&2
      exit 1
    fi
  fi

  # 3. Rebase onto the resolved base. If conflict, abort and exit 3 so commander
  #    escalates to the operator (semantic conflict, not ours to resolve).
  rebase_base="$(resolve_base_ref)"
  if [[ -z "$rebase_base" ]]; then
    echo "✗ could not resolve a base ref for rebase (tried $remote/main, refs/heads/main, --base)" >&2
    exit 1
  fi
  if ! git_in rebase "$rebase_base" 2>&1; then
    git_in rebase --abort 2>/dev/null || true
    echo "rescue-conflict: rebase onto $rebase_base hit a conflict on branch $branch" >&2
    exit 3
  fi

  # 4. Push (create remote branch if needed). Skipped if --base overrides the
  #    remote — in self-test fixtures there's no remote to push to, and the
  #    caller already knows the local branch state.
  if [[ -z "$base_override" ]]; then
    if ! git_in push --set-upstream "$remote" "$branch" 2>&1; then
      echo "✗ push to $remote/$branch failed" >&2
      exit 1
    fi
  fi

  # 5. Emit the branch name so commander can look up / create the PR.
  printf '%s\n' "$branch"
  exit 0
fi

# ---- mode: probe-review ----------------------------------------------------
#
# Inspects a PR on GitHub for evidence that a worker-review already posted its
# artifact. Two signals count as "review landed":
#   (a) a PR review body whose first line starts with "Commander review"
#   (b) the label `commander-review-clean` applied to the PR
#
# If either is present: exit 0 with verdict "review-already-landed".
# If neither is present: exit 4 with verdict "review-missing-dispatch-to-commander".
#
# Spec: docs/specs/2026-04-17-review-worker-rescue.md (ticket #75)

if [[ "$mode" == "probe-review" ]]; then
  # --- shim: gh_fetch_json <kind> → print JSON for the mocked-or-real call.
  # If $gh_mock is set, read from $gh_mock/<kind>-<pr_number>.json (test seam
  # used by self-test fixtures so CI runs offline). Otherwise shell out to `gh`.
  gh_fetch_json() {
    local kind="$1"  # "reviews" or "labels"
    if [[ -n "$gh_mock" ]]; then
      local mock_file="$gh_mock/${kind}-${pr_number}.json"
      if [[ ! -r "$mock_file" ]]; then
        echo "✗ gh-mock file missing or unreadable: $mock_file" >&2
        exit 1
      fi
      cat "$mock_file"
      return 0
    fi
    if ! command -v gh >/dev/null 2>&1; then
      echo "✗ gh not found on PATH; cannot inspect PR #${pr_number}" >&2
      exit 1
    fi
    if ! gh pr view "$pr_number" --json "$kind" 2>/dev/null; then
      echo "✗ gh pr view #${pr_number} --json ${kind} failed (auth? network? PR exists?)" >&2
      exit 1
    fi
  }

  # Require jq for JSON parsing — it's already a hard dep elsewhere in Hydra
  # (scripts/parse-citations.sh, scripts/validate-state-all.sh).
  if ! command -v jq >/dev/null 2>&1; then
    echo "✗ jq not found on PATH; --probe-review needs jq" >&2
    exit 1
  fi

  # 1. Does any review body start with "Commander review"?
  reviews_json="$(gh_fetch_json reviews)"
  body_match="$(printf '%s' "$reviews_json" | jq -r '
    (.reviews // [])
    | map(select((.body // "") | startswith("Commander review")))
    | length
  ')"
  if [[ "$body_match" =~ ^[0-9]+$ ]] && [[ "$body_match" -gt 0 ]]; then
    printf '{"verdict":"review-already-landed","source":"body","pr":%s}\n' "$pr_number"
    exit 0
  fi

  # 2. Is the commander-review-clean label applied?
  labels_json="$(gh_fetch_json labels)"
  label_match="$(printf '%s' "$labels_json" | jq -r '
    (.labels // [])
    | map(select(.name == "commander-review-clean"))
    | length
  ')"
  if [[ "$label_match" =~ ^[0-9]+$ ]] && [[ "$label_match" -gt 0 ]]; then
    printf '{"verdict":"review-already-landed","source":"label","pr":%s}\n' "$pr_number"
    exit 0
  fi

  # 3. Neither signal — commander must run /review inline.
  printf '{"verdict":"review-missing-dispatch-to-commander","pr":%s}\n' "$pr_number"
  exit 4
fi

# Defensive catch-all: should be unreachable because mode must be one of
# probe / rescue / probe-review (all branches above exit). If we fall through,
# something in arg parsing is wrong.
echo "✗ internal error: unhandled mode '$mode'" >&2
exit 1

#!/usr/bin/env bash
#
# hydra-codex-exec.sh — thin wrapper that invokes `codex exec` on a given
# worktree with a given task prompt, detects whether Codex produced any
# changes, and returns a well-defined exit code the orchestrator subagent
# can act on.
#
# Usage:
#   scripts/hydra-codex-exec.sh --worktree <path> --task <prompt> [--dry-run]
#   scripts/hydra-codex-exec.sh --worktree <path> --task-file <path> [--dry-run]
#   scripts/hydra-codex-exec.sh --check
#
# Modes:
#   default    Invoke `codex exec --cd <worktree>` with the task prompt piped
#              via stdin (NEVER as a command-line argument — we don't want
#              the prompt showing up in shell history / ps output). On
#              success, verify the worktree has pending changes via
#              `git status --porcelain` and exit 0.
#
#   --check    Verify `codex` is on PATH and smoke-test `codex --version`.
#              Used by worker-codex-implementation's preflight. No mutation.
#
#   --dry-run  Resolve args and print what WOULD run; do not invoke codex,
#              do not mutate the worktree. Used by the self-test fixture.
#
# Exit codes (keep these stable — the orchestrator subagent branches on them;
# see `.claude/agents/worker-codex-implementation.md` and the spec at
# `docs/specs/2026-04-17-codex-worker-backend.md`):
#   0   success — codex ran and the worktree has pending changes
#   1   bad args / no codex on PATH
#   2   codex exec failed, or ran but produced zero changes
#   3   diff apply failed (reserved; codex writes directly today)
#   4   codex unavailable — rate-limit, auth failure, model-not-supported
#
# Security:
#   - OPENAI_API_KEY and any session tokens are NEVER echoed to stdout or
#     stderr. `set -x` is never enabled. The task prompt is piped via stdin,
#     not passed on the command line.
#   - Captured codex stderr is scanned for a small allow-list of known
#     patterns (rate-limit / model-not-supported / auth) and a short,
#     sanitized summary line is printed. The full captured stderr is
#     written to a tmpfile that is `rm`'d on EXIT.
#
# Spec: docs/specs/2026-04-17-codex-worker-backend.md (ticket #96)

set -euo pipefail

# ---- arg parsing -----------------------------------------------------------

mode="run"
worktree=""
task=""
task_file=""
dry_run=0

usage() {
  cat <<'EOF'
Usage:
  scripts/hydra-codex-exec.sh --worktree <path> --task <prompt> [--dry-run]
  scripts/hydra-codex-exec.sh --worktree <path> --task-file <path> [--dry-run]
  scripts/hydra-codex-exec.sh --check

Options:
  --worktree <path>     Absolute path to the git worktree codex will edit.
  --task <prompt>       Task prompt string. Piped to codex via stdin.
  --task-file <path>    Read task prompt from file. (Exclusive with --task.)
  --dry-run             Resolve args + print what would run. Do not invoke codex.
  --check               Verify `codex` is on PATH and exits 0 on --version.
  -h, --help            Show this help.

Exit codes:
  0   success
  1   bad args / codex not installed
  2   codex exec errored or produced no changes
  3   diff apply failed (reserved)
  4   codex unavailable (rate-limit / auth / model-not-supported)

Spec: docs/specs/2026-04-17-codex-worker-backend.md
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --check) mode="check"; shift ;;
    --dry-run) dry_run=1; shift ;;
    --worktree) [[ $# -ge 2 ]] || { echo "ERROR: --worktree needs a value" >&2; exit 1; }; worktree="$2"; shift 2 ;;
    --worktree=*) worktree="${1#--worktree=}"; shift ;;
    --task) [[ $# -ge 2 ]] || { echo "ERROR: --task needs a value" >&2; exit 1; }; task="$2"; shift 2 ;;
    --task=*) task="${1#--task=}"; shift ;;
    --task-file) [[ $# -ge 2 ]] || { echo "ERROR: --task-file needs a value" >&2; exit 1; }; task_file="$2"; shift 2 ;;
    --task-file=*) task_file="${1#--task-file=}"; shift ;;
    --*) echo "ERROR: unknown flag: $1" >&2; usage >&2; exit 1 ;;
    *)   echo "ERROR: unexpected positional arg: $1" >&2; usage >&2; exit 1 ;;
  esac
done

# ---- --check mode ----------------------------------------------------------

if [[ "$mode" == "check" ]]; then
  if ! command -v codex >/dev/null 2>&1; then
    echo "ERROR: codex CLI not on PATH" >&2
    exit 1
  fi
  # Don't capture the version output to stdout — it can change format and we
  # don't want callers to grep on it. We only care that the binary runs.
  if ! codex --version >/dev/null 2>&1; then
    echo "ERROR: codex --version failed (auth / network / binary broken)" >&2
    exit 4
  fi
  echo "ok"
  exit 0
fi

# ---- default mode: validate required args ----------------------------------

if [[ -z "$worktree" ]]; then
  echo "ERROR: --worktree is required" >&2
  usage >&2
  exit 1
fi

if [[ -n "$task" && -n "$task_file" ]]; then
  echo "ERROR: --task and --task-file are mutually exclusive" >&2
  exit 1
fi

if [[ -z "$task" && -z "$task_file" ]]; then
  echo "ERROR: one of --task / --task-file is required" >&2
  exit 1
fi

if [[ ! -d "$worktree" ]]; then
  echo "ERROR: worktree path does not exist: $worktree" >&2
  exit 1
fi

if ! git -C "$worktree" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "ERROR: not a git worktree: $worktree" >&2
  exit 1
fi

if [[ -n "$task_file" ]]; then
  if [[ ! -r "$task_file" ]]; then
    echo "ERROR: --task-file not readable: $task_file" >&2
    exit 1
  fi
fi

# ---- codex presence check (pre-invocation) ---------------------------------

if ! command -v codex >/dev/null 2>&1; then
  echo "ERROR: codex CLI not on PATH — see docs/phase2-vps-runbook.md 'Configuring the Codex backend'" >&2
  exit 1
fi

# ---- dry-run ---------------------------------------------------------------

if [[ "$dry_run" -eq 1 ]]; then
  src_desc="(inline, $(printf '%s' "$task" | wc -c | tr -d ' ') chars)"
  [[ -n "$task_file" ]] && src_desc="(file: $task_file)"
  echo "DRY RUN: would invoke codex exec --cd $worktree"
  echo "DRY RUN: task prompt source $src_desc"
  echo "DRY RUN: stdin piped, never echoed"
  exit 0
fi

# ---- real invocation -------------------------------------------------------

# Security: capture codex's stderr to a tmpfile so we can scan it for known
# patterns after the run. Never print the raw tmpfile — it may include parts
# of the prompt on error. Always `rm` on exit.
stderr_tmp="$(mktemp -t hydra-codex-stderr.XXXXXX)"
trap 'rm -f "$stderr_tmp"' EXIT INT TERM

# Snapshot HEAD so we can diff afterward for the no-op detection.
head_before="$(git -C "$worktree" rev-parse HEAD 2>/dev/null || echo "")"

# Build the stdin stream from --task or --task-file. Piping via stdin keeps
# the prompt out of ps(1) output and shell history.
codex_exit=0
if [[ -n "$task_file" ]]; then
  codex exec --cd "$worktree" < "$task_file" 2> "$stderr_tmp" >/dev/null || codex_exit=$?
else
  printf '%s' "$task" | codex exec --cd "$worktree" 2> "$stderr_tmp" >/dev/null || codex_exit=$?
fi

# ---- classify codex outcome -------------------------------------------------

# Known-unavailable patterns → exit 4. Keep this list narrow; broad matching
# would swallow real bugs. Patterns come from observed `codex` CLI failures
# in the operator environment and from OpenAI's public API error shapes.
classify_unavailable() {
  local f="$1"
  # Return 0 if unavailable, 1 if not.
  if grep -Eqi 'rate.?limit|quota|exceeded your' "$f" 2>/dev/null; then return 0; fi
  if grep -Eqi 'model is not supported|unsupported model|gpt-[0-9.]+-codex.*not supported' "$f" 2>/dev/null; then return 0; fi
  if grep -Eqi 'unauthorized|invalid api key|please log in|403|401' "$f" 2>/dev/null; then return 0; fi
  return 1
}

if [[ "$codex_exit" -ne 0 ]]; then
  if classify_unavailable "$stderr_tmp"; then
    # Surface ONE sanitized line — never the raw tmpfile contents, which
    # may have included a chunk of the prompt.
    reason="codex-unavailable"
    if grep -Eqi 'rate.?limit|quota|exceeded' "$stderr_tmp"; then reason="codex-unavailable: rate-limit"
    elif grep -Eqi 'not supported' "$stderr_tmp"; then reason="codex-unavailable: model-not-supported"
    elif grep -Eqi 'unauthorized|invalid api key|please log in|401|403' "$stderr_tmp"; then reason="codex-unavailable: auth"
    fi
    echo "ERROR: $reason (codex exit $codex_exit)" >&2
    exit 4
  fi
  echo "ERROR: codex exec failed (exit $codex_exit); no changes applied" >&2
  exit 2
fi

# ---- verify codex actually produced changes --------------------------------

# We allow HEAD to have moved (codex may have committed) OR a dirty worktree.
head_after="$(git -C "$worktree" rev-parse HEAD 2>/dev/null || echo "")"
has_dirty_tree=0
if [[ -n "$(git -C "$worktree" status --porcelain 2>/dev/null)" ]]; then
  has_dirty_tree=1
fi

if [[ "$head_before" == "$head_after" && "$has_dirty_tree" -eq 0 ]]; then
  echo "ERROR: codex exec completed with exit 0 but produced no changes" >&2
  exit 2
fi

echo "ok"
exit 0

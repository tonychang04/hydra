#!/usr/bin/env bash
#
# launcher-dispatch smoke test — regenerate ./hydra via setup.sh in a
# tmpdir and assert every documented subcommand dispatches to its helper
# script instead of falling through to `claude`.
#
# Why this fixture exists:
#   Prior workers "verified" CLI subcommands by running
#   `scripts/hydra-<x>.sh --help` directly, which works. But the real user
#   path goes through `./hydra <x>` — and if that `case` block doesn't
#   route to the helper, the args fall through to `claude` which
#   fabricates plausible-looking output from state files. This is the
#   illusion-of-working bug #117 catches going forward.
#
# Shape follows other self-test fixtures (e.g. setup-interactive-ci-mode,
# activity-command-smoke): each assertion greps for a marker + echoes
# the check status; the final SMOKE_OK signals success. Any failure
# exits non-zero with a specific error message.
#
# Runs locally; no network, no Claude auth, no gh auth (setup.sh will
# still probe `gh auth status` but the harness copes by reusing the
# host's gh creds — same as setup-interactive-ci-mode).

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# Fixture is at self-test/fixtures/launcher-dispatch/run.sh.
# Worktree root is three levels up.
ROOT_DIR="$(cd -- "$SCRIPT_DIR/../../.." && pwd)"

TMPDIR_BASE="${TMPDIR:-/tmp}"
WORK_DIR="$(mktemp -d "$TMPDIR_BASE/launcher-dispatch-XXXXXX")"

cleanup() {
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

# -----------------------------------------------------------------------------
# 1. Stage a fresh copy of the worktree into a tmpdir so setup.sh can
#    regenerate ./hydra from scratch. Exclude .git (heavy + not needed)
#    and any pre-existing ./hydra launcher / .hydra.env so we force a
#    clean regeneration.
# -----------------------------------------------------------------------------
# rsync is preferred; fall back to tar + excludes if not available.
if command -v rsync >/dev/null 2>&1; then
  rsync -a \
    --exclude='.git' \
    --exclude='node_modules' \
    --exclude='.claude/worktrees' \
    --exclude='hydra' \
    --exclude='.hydra.env' \
    --exclude='state/active.json' \
    --exclude='state/budget-used.json' \
    --exclude='state/memory-citations.json' \
    --exclude='state/autopickup.json' \
    --exclude='.claude/settings.local.json' \
    "$ROOT_DIR/" "$WORK_DIR/"
else
  (cd "$ROOT_DIR" && tar --exclude='.git' --exclude='node_modules' \
    --exclude='.claude/worktrees' --exclude='./hydra' \
    --exclude='.hydra.env' --exclude='state/active.json' \
    --exclude='state/budget-used.json' \
    --exclude='state/memory-citations.json' \
    --exclude='state/autopickup.json' \
    --exclude='.claude/settings.local.json' \
    -cf - .) | (cd "$WORK_DIR" && tar -xf -)
fi

cd "$WORK_DIR"

# -----------------------------------------------------------------------------
# 2. Regenerate the launcher. HYDRA_EXTERNAL_MEMORY_DIR skips the prompt;
#    HYDRA_NON_INTERACTIVE=1 belt-and-suspenders in case stdin is a TTY.
# -----------------------------------------------------------------------------
MEMDIR="$WORK_DIR/memdir"
mkdir -p "$MEMDIR"

if ! HYDRA_NON_INTERACTIVE=1 HYDRA_EXTERNAL_MEMORY_DIR="$MEMDIR" \
    ./setup.sh --non-interactive >"$WORK_DIR/setup.log" 2>&1; then
  echo "FAIL: setup.sh failed to regenerate launcher" >&2
  cat "$WORK_DIR/setup.log" >&2
  exit 1
fi

if [[ ! -x ./hydra ]]; then
  echo "FAIL: setup.sh did not produce an executable ./hydra launcher" >&2
  exit 1
fi
echo "SETUP_OK"

# -----------------------------------------------------------------------------
# 3. For each documented subcommand, assert `./hydra <cmd> --help` dispatches
#    to the Hydra helper (not to claude). Hydra helpers all emit a usage line
#    starting `Usage: ./hydra <cmd>`; `claude --help` emits
#    `Usage: claude [options] [command] [prompt]`. The difference is
#    unambiguous — we grep for the specific marker.
# -----------------------------------------------------------------------------
assert_dispatches() {
  local cmd="$1" marker="$2"
  local out
  if ! out="$(./hydra $cmd --help 2>&1)"; then
    # Some helpers exit non-zero on --help? None should, but be explicit if so.
    echo "FAIL: ./hydra $cmd --help exited non-zero" >&2
    echo "$out" >&2
    return 1
  fi
  if ! grep -qF "$marker" <<<"$out"; then
    echo "FAIL: ./hydra $cmd --help did not contain marker '$marker'" >&2
    echo "--- actual output ---" >&2
    echo "$out" >&2
    echo "--- end ---" >&2
    return 1
  fi
  # Guard against Claude's help leaking in — its signature line is very
  # distinctive and not present in any Hydra helper.
  if grep -qF "Claude Code - starts an interactive session" <<<"$out"; then
    echo "FAIL: ./hydra $cmd --help fell through to claude (illusion-of-working)" >&2
    echo "$out" >&2
    return 1
  fi
  echo "DISPATCH_OK: $cmd"
}

assert_dispatches "doctor"       "Usage: scripts/hydra-doctor.sh"
assert_dispatches "add-repo"     "Usage: ./hydra add-repo"
assert_dispatches "remove-repo"  "Usage: ./hydra remove-repo"
assert_dispatches "list-repos"   "Usage: ./hydra list-repos"
assert_dispatches "status"       "Usage: ./hydra status"
assert_dispatches "ps"           "Usage: ./hydra ps"
assert_dispatches "pause"        "Usage: ./hydra pause"
assert_dispatches "resume"       "Usage: ./hydra resume"
assert_dispatches "issue"        "Usage: ./hydra issue"
assert_dispatches "activity"     "Usage: ./hydra activity"

# mcp has two levels. --help at the top prints the MCP usage sub-table
# (cat'd inline in the launcher), --help on subcommands dispatches to
# the helper script.
assert_dispatches "mcp"                  "Usage: ./hydra mcp"
assert_dispatches "mcp serve"            "Usage: ./hydra mcp serve"
assert_dispatches "mcp register-agent"   "Usage: ./hydra mcp register-agent"

# -----------------------------------------------------------------------------
# 4. ./hydra --help / -h / help MUST print Hydra's help, NOT claude's.
# -----------------------------------------------------------------------------
for flag in "--help" "-h" "help"; do
  out="$(./hydra $flag 2>&1)"
  if ! grep -qF "Hydra — persistent AI agent orchestrator" <<<"$out"; then
    echo "FAIL: ./hydra $flag did not print Hydra's top-level help" >&2
    echo "--- actual output ---" >&2
    echo "$out" >&2
    echo "--- end ---" >&2
    exit 1
  fi
  if grep -qF "Claude Code - starts an interactive session" <<<"$out"; then
    echo "FAIL: ./hydra $flag fell through to claude --help" >&2
    exit 1
  fi
  echo "TOPLEVEL_HELP_OK: $flag"
done

# -----------------------------------------------------------------------------
# 5. --version still works (not changed by #117 but worth asserting that the
#    -h|--help case added before it doesn't break the pre-existing short-circuit).
# -----------------------------------------------------------------------------
ver="$(./hydra --version 2>&1)"
if [[ -z "$ver" ]]; then
  echo "FAIL: ./hydra --version produced empty output" >&2
  exit 1
fi
if grep -qF "Claude Code - starts an interactive session" <<<"$ver"; then
  echo "FAIL: ./hydra --version fell through to claude" >&2
  exit 1
fi
echo "VERSION_OK: $ver"

# -----------------------------------------------------------------------------
# 6. Unknown subcommand should fall through to claude (that's the
#    documented behavior — passthrough for prompts / flags claude handles).
#    We can't test "does it invoke claude" without claude creds, but we CAN
#    assert the case block doesn't match any of the documented subcommands,
#    which is verified structurally by grepping the generated launcher.
# -----------------------------------------------------------------------------
if ! grep -qE '^\s*(doctor|add-repo|remove-repo|list-repos|status|ps|pause|resume|issue|activity|mcp)\)' hydra; then
  echo "FAIL: generated ./hydra is missing expected subcommand case entries" >&2
  exit 1
fi
echo "CASE_BLOCK_OK"

echo "SMOKE_OK"

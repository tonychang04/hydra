#!/usr/bin/env bash
#
# self-test fixture driver for scripts/hydra-codex-exec.sh.
#
# The real `codex` CLI is:
#   - expensive (burns real quota)
#   - non-deterministic (different diffs per run)
#   - not guaranteed to be installed on the CI bot
#
# So this fixture stubs `codex` with a shell script we prepend to $PATH.
# The stub emits a fixed, predictable diff (writes one file to the worktree)
# which lets us exercise every exit-code path of the wrapper deterministically.
#
# Exits 0 on PASS, non-zero on FAIL with a clear stderr message.
#
# Invoked by self-test/golden-cases.example.json case "codex-worker-fixture".
#
# Gate: set HYDRA_TEST_CODEX_E2E=1 to additionally exercise a real `codex`
# binary end-to-end (skipped otherwise; the stubbed run still executes
# because it's the point of this fixture).

set -euo pipefail
export NO_COLOR=1

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd -- "$SCRIPT_DIR/../../.." && pwd)"
WRAPPER="$ROOT_DIR/scripts/hydra-codex-exec.sh"

[[ -x "$WRAPPER" ]] || { echo "FAIL: $WRAPPER not executable" >&2; exit 1; }

# ---- set up a throwaway git worktree for codex to "modify" -----------------

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT INT TERM

(
  cd "$tmp"
  git init -q
  git config user.email codex-fixture@example.com
  git config user.name "codex fixture"
  git symbolic-ref HEAD refs/heads/main
  echo "baseline" > README.md
  git add README.md
  git commit -q -m "init"
)

# ---- stub `codex` variants --------------------------------------------------
# We build three different PATHs, each containing a different stub that
# simulates a specific codex behavior. The wrapper is invoked with each in
# turn to verify every exit-code branch.

stub_dir_success="$(mktemp -d)"
cat > "$stub_dir_success/codex" <<'STUB'
#!/usr/bin/env bash
# Stub: success path. Writes a known file to --cd dir, reads prompt from
# stdin (just to verify piping works), prints nothing to stdout/stderr.
set -euo pipefail
cd_dir=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    exec) shift ;;
    --cd) cd_dir="$2"; shift 2 ;;
    --cd=*) cd_dir="${1#--cd=}"; shift ;;
    --version) echo "codex-stub-1.0"; exit 0 ;;
    *) shift ;;
  esac
done
[[ -n "$cd_dir" && -d "$cd_dir" ]] || { echo "stub: bad --cd" >&2; exit 1; }
# Consume stdin (never echo the prompt back — that would leak it to caller).
cat >/dev/null
# Simulate a diff: add a new file.
echo "codex wrote this" > "$cd_dir/generated.txt"
STUB
chmod +x "$stub_dir_success/codex"

stub_dir_nochange="$(mktemp -d)"
cat > "$stub_dir_nochange/codex" <<'STUB'
#!/usr/bin/env bash
# Stub: exit 0 but produce no changes. Tests the "codex refused" branch.
set -euo pipefail
while [[ $# -gt 0 ]]; do
  case "$1" in
    --version) echo "codex-stub-1.0"; exit 0 ;;
    *) shift ;;
  esac
done
cat >/dev/null
exit 0
STUB
chmod +x "$stub_dir_nochange/codex"

stub_dir_unavail="$(mktemp -d)"
cat > "$stub_dir_unavail/codex" <<'STUB'
#!/usr/bin/env bash
# Stub: emit the model-not-supported error the operator's real env hits.
# Tests the exit-4 codex-unavailable branch.
set -euo pipefail
while [[ $# -gt 0 ]]; do
  case "$1" in
    --version) echo "codex-stub-1.0"; exit 0 ;;
    *) shift ;;
  esac
done
cat >/dev/null
echo "error: gpt-5.2-codex model is not supported when using Codex with a ChatGPT account" >&2
exit 1
STUB
chmod +x "$stub_dir_unavail/codex"

stub_dir_ratelimit="$(mktemp -d)"
cat > "$stub_dir_ratelimit/codex" <<'STUB'
#!/usr/bin/env bash
# Stub: rate-limit error → exit-4 codex-unavailable.
set -euo pipefail
while [[ $# -gt 0 ]]; do
  case "$1" in
    --version) echo "codex-stub-1.0"; exit 0 ;;
    *) shift ;;
  esac
done
cat >/dev/null
echo "429: you have exceeded your rate-limit for this model" >&2
exit 1
STUB
chmod +x "$stub_dir_ratelimit/codex"

# ---- shared invoker: runs the wrapper with a given $PATH, returns exit code
# Silences wrapper stdout + stderr so the caller's `$(run_wrapper ...)` only
# captures the exit-code integer on the last echo. Individual tests that need
# to inspect stderr (e.g. error-message assertions) invoke the wrapper
# directly rather than going through this helper.
run_wrapper() {
  local PATH_OVERRIDE="$1"; shift
  local ec=0
  PATH="$PATH_OVERRIDE:$PATH" "$WRAPPER" "$@" >/dev/null 2>&1 || ec=$?
  echo "$ec"
}

# ---- 1. --help prints usage and exits 0 ------------------------------------

if ! "$WRAPPER" --help 2>&1 | grep -q 'Usage:'; then
  echo "FAIL: --help output missing 'Usage:'" >&2
  exit 1
fi

# ---- 2. missing --worktree → exit 1 ----------------------------------------

set +e
"$WRAPPER" --task "noop" >/dev/null 2>&1
ec=$?
set -e
if [[ "$ec" -ne 1 ]]; then
  echo "FAIL: missing --worktree should exit 1, got $ec" >&2
  exit 1
fi

# ---- 3. --task and --task-file mutually exclusive → exit 1 -----------------

tmpfile="$(mktemp)"; echo "prompt" > "$tmpfile"
set +e
"$WRAPPER" --worktree "$tmp" --task "x" --task-file "$tmpfile" >/dev/null 2>&1
ec=$?
set -e
rm -f "$tmpfile"
if [[ "$ec" -ne 1 ]]; then
  echo "FAIL: --task + --task-file should exit 1, got $ec" >&2
  exit 1
fi

# ---- 4. non-existent worktree → exit 1 -------------------------------------

set +e
"$WRAPPER" --worktree "/nonexistent/codex/$$" --task "noop" >/dev/null 2>&1
ec=$?
set -e
if [[ "$ec" -ne 1 ]]; then
  echo "FAIL: bad --worktree should exit 1, got $ec" >&2
  exit 1
fi

# ---- 5. codex not on PATH → exit 1 -----------------------------------------

# Use a PATH that intentionally lacks codex (and everything except a minimal
# set of commands the wrapper calls: git, grep, mktemp, etc. — these are in
# /usr/bin + /bin). This also implicitly tests that the wrapper exits 1
# BEFORE trying to invoke the missing binary.
set +e
PATH="/usr/bin:/bin" "$WRAPPER" --worktree "$tmp" --task "noop" >/dev/null 2>&1
ec=$?
set -e
if [[ "$ec" -ne 1 ]]; then
  echo "FAIL: missing codex should exit 1, got $ec" >&2
  exit 1
fi

# ---- 6. --dry-run resolves args + skips invocation → exit 0 ----------------

# Must use the success stub path (or any PATH with codex) since --dry-run
# still requires codex to be found (we're verifying the pre-check).
ec="$(run_wrapper "$stub_dir_success" --worktree "$tmp" --task "noop" --dry-run)"
if [[ "$ec" -ne 0 ]]; then
  echo "FAIL: --dry-run should exit 0, got $ec" >&2
  exit 1
fi
# Must NOT have mutated the worktree.
if [[ -n "$(git -C "$tmp" status --porcelain)" ]]; then
  echo "FAIL: --dry-run mutated the worktree" >&2
  exit 1
fi

# ---- 7. success path: stub writes a file, wrapper exits 0 ------------------

ec="$(run_wrapper "$stub_dir_success" --worktree "$tmp" --task "add a file please")"
if [[ "$ec" -ne 0 ]]; then
  echo "FAIL: success stub should exit 0, got $ec" >&2
  exit 1
fi
if [[ ! -f "$tmp/generated.txt" ]]; then
  echo "FAIL: success stub was supposed to write generated.txt but didn't" >&2
  exit 1
fi
# Clean up for next test.
( cd "$tmp" && git checkout -q -- . && git clean -qfd )

# ---- 8. no-change path: stub exits 0 but writes nothing → wrapper exits 2 --

ec="$(run_wrapper "$stub_dir_nochange" --worktree "$tmp" --task "do nothing")"
if [[ "$ec" -ne 2 ]]; then
  echo "FAIL: no-change stub should exit 2 (codex produced nothing), got $ec" >&2
  exit 1
fi

# ---- 9. model-not-supported → wrapper exits 4 ------------------------------

set +e
err="$(PATH="$stub_dir_unavail:$PATH" "$WRAPPER" --worktree "$tmp" --task "go" 2>&1 >/dev/null)"
ec=$?
set -e
if [[ "$ec" -ne 4 ]]; then
  echo "FAIL: model-not-supported stub should exit 4, got $ec" >&2
  echo "stderr: $err" >&2
  exit 1
fi
if ! printf '%s' "$err" | grep -q 'codex-unavailable: model-not-supported'; then
  echo "FAIL: expected 'codex-unavailable: model-not-supported' in stderr; got: $err" >&2
  exit 1
fi

# ---- 10. rate-limit → wrapper exits 4 + rate-limit reason ------------------

set +e
err="$(PATH="$stub_dir_ratelimit:$PATH" "$WRAPPER" --worktree "$tmp" --task "go" 2>&1 >/dev/null)"
ec=$?
set -e
if [[ "$ec" -ne 4 ]]; then
  echo "FAIL: rate-limit stub should exit 4, got $ec" >&2
  exit 1
fi
if ! printf '%s' "$err" | grep -q 'codex-unavailable: rate-limit'; then
  echo "FAIL: expected 'codex-unavailable: rate-limit' in stderr; got: $err" >&2
  exit 1
fi

# ---- 11. --check with codex available → exit 0 -----------------------------

ec="$(run_wrapper "$stub_dir_success" --check)"
if [[ "$ec" -ne 0 ]]; then
  echo "FAIL: --check with codex on PATH should exit 0, got $ec" >&2
  exit 1
fi

# ---- 12. --check with no codex → exit 1 ------------------------------------

set +e
PATH="/usr/bin:/bin" "$WRAPPER" --check >/dev/null 2>&1
ec=$?
set -e
if [[ "$ec" -ne 1 ]]; then
  echo "FAIL: --check with no codex should exit 1, got $ec" >&2
  exit 1
fi

# ---- 13. SECURITY: prompt never leaks to stdout/stderr ---------------------
# This is the critical security assertion: if the wrapper were sloppy (e.g.
# `set -x`, or passing the prompt on the command line instead of stdin), the
# prompt would end up in the captured output. Use a unique marker as the
# prompt and assert it's NOWHERE in combined stdout+stderr.

marker="HYDRA-CODEX-PROMPT-LEAK-MARKER-$$"
set +e
combined="$(PATH="$stub_dir_success:$PATH" "$WRAPPER" --worktree "$tmp" --task "$marker" 2>&1)"
ec=$?
set -e
( cd "$tmp" && git checkout -q -- . && git clean -qfd ) || true
if [[ "$ec" -ne 0 ]]; then
  echo "FAIL: security-leak test harness hit unexpected wrapper exit $ec" >&2
  exit 1
fi
if printf '%s' "$combined" | grep -qF "$marker"; then
  echo "FAIL: prompt marker '$marker' leaked to combined output:" >&2
  echo "$combined" >&2
  exit 1
fi

# ---- 14. HYDRA_TEST_CODEX_E2E gate (optional real codex roundtrip) ---------
# Off by default. When set, we additionally smoke-test against whatever
# `codex` is actually on PATH. CI leaves this unset; operators with a
# working local codex can flip it on.

if [[ "${HYDRA_TEST_CODEX_E2E:-0}" == "1" ]]; then
  if ! command -v codex >/dev/null 2>&1; then
    echo "FAIL: HYDRA_TEST_CODEX_E2E=1 but no codex on PATH" >&2
    exit 1
  fi
  # Just --check the real binary; we don't burn quota actually running
  # `codex exec` here. The non-gated path above already exercises the full
  # wrapper control flow against the stub.
  if ! "$WRAPPER" --check >/dev/null 2>&1; then
    echo "NOTE: HYDRA_TEST_CODEX_E2E real codex --check failed (non-fatal, informational)" >&2
  fi
fi

echo "PASS: scripts/hydra-codex-exec.sh stub-driven fixture"

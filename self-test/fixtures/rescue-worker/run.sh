#!/usr/bin/env bash
#
# self-test fixture driver for scripts/rescue-worker.sh.
#
# Exercises the --probe mode (non-mutating) against synthetic worktrees that
# represent each possible timeout-rescue state. Uses --base refs/heads/main so
# the fixture needs no remote. Only probe + help / usage / branch-mismatch are
# tested here because --rescue pushes to origin, which would need a live
# upstream. The full rescue loop is exercised end-to-end by commander itself
# on real worker worktrees.
#
# Exits 0 on PASS, non-zero on FAIL with a clear message on stderr.
#
# Invoked by self-test/golden-cases.example.json case "worker-timeout-watchdog-script".

set -euo pipefail
export NO_COLOR=1

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd -- "$SCRIPT_DIR/../../.." && pwd)"
RESCUE="$ROOT_DIR/scripts/rescue-worker.sh"

[[ -x "$RESCUE" ]] || { echo "FAIL: $RESCUE not executable" >&2; exit 1; }

# build a throwaway git repo on branch hydra/commander/45, parented on main
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

(
  cd "$tmp"
  git init -q
  git config user.email rescue-fixture@example.com
  git config user.name "rescue fixture"
  git symbolic-ref HEAD refs/heads/main
  echo "baseline" > base.txt
  git add base.txt
  git commit -q -m "init"
  git checkout -q -b hydra/commander/45
)

# ---- 1. nothing-to-rescue verdict on a clean branch at parent of main ----
out="$("$RESCUE" --probe "$tmp" hydra/commander/45 45 --base refs/heads/main)"
if ! printf '%s' "$out" | grep -q '"verdict":"nothing-to-rescue"'; then
  echo "FAIL: expected nothing-to-rescue on clean branch; got: $out" >&2
  exit 1
fi

# ---- 2. rescue-uncommitted verdict when worktree has dirty files ----
printf 'unsaved worker output\n' > "$tmp/unsaved.txt"
out="$("$RESCUE" --probe "$tmp" hydra/commander/45 45 --base refs/heads/main)"
if ! printf '%s' "$out" | grep -q '"verdict":"rescue-uncommitted"'; then
  echo "FAIL: expected rescue-uncommitted with dirty file; got: $out" >&2
  exit 1
fi
if ! printf '%s' "$out" | grep -q '"dirty":true'; then
  echo "FAIL: expected dirty:true in verdict; got: $out" >&2
  exit 1
fi

# ---- 3. rescue-commits verdict when a worker commit exists ahead of main ----
( cd "$tmp" && git add unsaved.txt && git commit -q -m "wip" )
out="$("$RESCUE" --probe "$tmp" hydra/commander/45 45 --base refs/heads/main)"
if ! printf '%s' "$out" | grep -q '"verdict":"rescue-commits"'; then
  echo "FAIL: expected rescue-commits after committing; got: $out" >&2
  exit 1
fi
if ! printf '%s' "$out" | grep -q '"commits_ahead":1'; then
  echo "FAIL: expected commits_ahead:1; got: $out" >&2
  exit 1
fi

# ---- 4. branch-mismatch check: refuse with exit 1 ----
if "$RESCUE" --probe "$tmp" wrong-branch 45 --base refs/heads/main >/dev/null 2>&1; then
  echo "FAIL: branch mismatch should have exited non-zero" >&2
  exit 1
fi

# ---- 5. missing positional args: exit 2 (usage error) ----
set +e
"$RESCUE" --probe >/dev/null 2>&1
ec=$?
set -e
if [[ "$ec" -ne 2 ]]; then
  echo "FAIL: missing args should exit 2, got $ec" >&2
  exit 1
fi

# ---- 6. invalid worktree path: exit 1 ----
set +e
"$RESCUE" --probe "/nonexistent/path/$$" hydra/commander/45 45 >/dev/null 2>&1
ec=$?
set -e
if [[ "$ec" -ne 1 ]]; then
  echo "FAIL: nonexistent worktree should exit 1, got $ec" >&2
  exit 1
fi

# ---- 7. --help prints usage and exits 0 ----
if ! "$RESCUE" --help 2>&1 | grep -q 'Usage:'; then
  echo "FAIL: --help output missing 'Usage:'" >&2
  exit 1
fi

# ---- 8. no mode → exit 2 ----
set +e
"$RESCUE" "$tmp" hydra/commander/45 45 >/dev/null 2>&1
ec=$?
set -e
if [[ "$ec" -ne 2 ]]; then
  echo "FAIL: no --probe/--rescue flag should exit 2, got $ec" >&2
  exit 1
fi

# ---- 9. --rescue with .git/index.lock present → exit 1 + stale-lock message ----
# Ticket #81: guard the race where a worker is still writing during rescue.
# The worktree already has a clean HEAD + branch hydra/commander/45. Drop a
# fake .git/index.lock with a dummy PID; --rescue must refuse before any
# mutating git call and surface a rescue-specific message (not git's opaque
# "File exists" 128). The lock file is in $tmp/.git/ since this is a plain
# repo, not a linked worktree.
printf '99999\n' > "$tmp/.git/index.lock"
set +e
err="$("$RESCUE" --rescue "$tmp" hydra/commander/45 45 --base refs/heads/main 2>&1)"
ec=$?
set -e
rm -f "$tmp/.git/index.lock"
if [[ "$ec" -ne 1 ]]; then
  echo "FAIL: --rescue with stale index.lock should exit 1, got $ec" >&2
  echo "stderr was: $err" >&2
  exit 1
fi
if ! printf '%s' "$err" | grep -q '.git/index.lock present'; then
  echo "FAIL: expected '.git/index.lock present' in stderr; got: $err" >&2
  exit 1
fi
if ! printf '%s' "$err" | grep -q 'worker may still be writing'; then
  echo "FAIL: expected 'worker may still be writing' in stderr; got: $err" >&2
  exit 1
fi

echo "PASS: scripts/rescue-worker.sh probe fixture roundtrip"

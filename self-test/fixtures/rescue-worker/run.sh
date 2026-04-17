#!/usr/bin/env bash
#
# self-test fixture driver for scripts/rescue-worker.sh.
#
# Exercises the --probe and --probe-review modes (both non-mutating) against
# synthetic inputs. The --probe side uses a throwaway git repo and --base
# refs/heads/main so the fixture needs no remote. The --probe-review side uses
# --gh-mock to point at local JSON files so CI never shells out to `gh`.
#
# Only probe paths are tested here because --rescue pushes to origin (needs a
# live upstream) and the commander-side review-dispatch runs `/review` inline
# (needs the worker-subagent executor — see CLAUDE.md "Worker timeout watchdog").
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

# ---- 10. --probe-review: review-already-landed via body ----
# Ticket #75. Mocks `gh pr view --json reviews/labels` with local JSON files so
# CI can exercise the review-rescue path offline. The body opener "Commander
# review" is the canonical marker from Commander's /review skill output.
mock="$(mktemp -d)"
trap 'rm -rf "$tmp" "$mock"' EXIT

cat > "$mock/reviews-101.json" <<'EOF'
{"reviews":[{"body":"Commander review for PR #101\n\nLGTM, no blockers."}]}
EOF
cat > "$mock/labels-101.json" <<'EOF'
{"labels":[{"name":"commander-review"}]}
EOF

out="$("$RESCUE" --probe-review 101 --gh-mock "$mock")"
ec=$?
if [[ "$ec" -ne 0 ]]; then
  echo "FAIL: probe-review review-already-landed (body) expected exit 0, got $ec; out=$out" >&2
  exit 1
fi
if ! printf '%s' "$out" | grep -q '"verdict":"review-already-landed"'; then
  echo "FAIL: expected review-already-landed verdict; got: $out" >&2
  exit 1
fi
if ! printf '%s' "$out" | grep -q '"source":"body"'; then
  echo "FAIL: expected source:body; got: $out" >&2
  exit 1
fi

# ---- 11. --probe-review: review-already-landed via commander-review-clean label ----
cat > "$mock/reviews-202.json" <<'EOF'
{"reviews":[]}
EOF
cat > "$mock/labels-202.json" <<'EOF'
{"labels":[{"name":"commander-review-clean"}]}
EOF

out="$("$RESCUE" --probe-review 202 --gh-mock "$mock")"
ec=$?
if [[ "$ec" -ne 0 ]]; then
  echo "FAIL: probe-review review-already-landed (label) expected exit 0, got $ec; out=$out" >&2
  exit 1
fi
if ! printf '%s' "$out" | grep -q '"source":"label"'; then
  echo "FAIL: expected source:label; got: $out" >&2
  exit 1
fi

# ---- 12. --probe-review: no review + no label → exit 4 ----
# This is the core review-rescue trigger. The observed failure is a review
# worker that dies mid-stream and never posts anything to the PR — exit 4
# tells commander "dispatch yourself to run /review inline".
cat > "$mock/reviews-303.json" <<'EOF'
{"reviews":[]}
EOF
cat > "$mock/labels-303.json" <<'EOF'
{"labels":[{"name":"commander-working"}]}
EOF

set +e
out="$("$RESCUE" --probe-review 303 --gh-mock "$mock")"
ec=$?
set -e
if [[ "$ec" -ne 4 ]]; then
  echo "FAIL: probe-review no-review/no-label expected exit 4, got $ec; out=$out" >&2
  exit 1
fi
if ! printf '%s' "$out" | grep -q '"verdict":"review-missing-dispatch-to-commander"'; then
  echo "FAIL: expected review-missing-dispatch-to-commander verdict; got: $out" >&2
  exit 1
fi

# ---- 13. --probe-review: reviews present but none with the Commander marker → exit 4 ----
# Guards against the heuristic false-matching unrelated human review comments
# (e.g. a nitpick comment from a reviewer); the script must require the
# "Commander review" prefix specifically, not just any body text.
cat > "$mock/reviews-404.json" <<'EOF'
{"reviews":[{"body":"Nitpick: missing period on line 12"},{"body":"LGTM"}]}
EOF
cat > "$mock/labels-404.json" <<'EOF'
{"labels":[{"name":"commander-working"}]}
EOF
set +e
out="$("$RESCUE" --probe-review 404 --gh-mock "$mock")"
ec=$?
set -e
if [[ "$ec" -ne 4 ]]; then
  echo "FAIL: probe-review with non-commander review bodies expected exit 4, got $ec; out=$out" >&2
  exit 1
fi

# ---- 14. --probe-review: missing pr_number arg → exit 2 ----
set +e
"$RESCUE" --probe-review >/dev/null 2>&1
ec=$?
set -e
if [[ "$ec" -ne 2 ]]; then
  echo "FAIL: probe-review with no pr_number should exit 2, got $ec" >&2
  exit 1
fi

# ---- 15. --probe-review: non-integer pr_number → exit 2 ----
set +e
"$RESCUE" --probe-review not-a-number >/dev/null 2>&1
ec=$?
set -e
if [[ "$ec" -ne 2 ]]; then
  echo "FAIL: probe-review with non-integer pr_number should exit 2, got $ec" >&2
  exit 1
fi

# ---- 16. mutual-exclusion: --probe-review + --probe → exit 2 ----
set +e
"$RESCUE" --probe --probe-review 101 --gh-mock "$mock" >/dev/null 2>&1
ec=$?
set -e
if [[ "$ec" -ne 2 ]]; then
  echo "FAIL: --probe and --probe-review together should exit 2, got $ec" >&2
  exit 1
fi

echo "PASS: scripts/rescue-worker.sh probe fixture roundtrip"

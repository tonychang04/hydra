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

# ===========================================================================
# Ticket #190: --probe must distinguish a worker BLOCKED on a flaky external
# tool (alive, retrying a daemon that keeps resetting) from an idle ghost.
# The worker leaves a worktree-local marker at .hydra/flaky-tool.json; --probe
# reads it and emits verdict "flaky-tool-retry" + exit 5 so commander relays a
# fallback hint to the live worker instead of rescue-and-restart.
# Spec: docs/specs/2026-05-21-flaky-tool-probe-verdict.md
# ===========================================================================

# Build a second throwaway repo dedicated to the flaky-tool cases so we don't
# disturb the commit/dirty state accumulated in $tmp above.
ftmp="$(mktemp -d)"
trap 'rm -rf "$tmp" "$mock" "$ftmp"' EXIT
(
  cd "$ftmp"
  git init -q
  git config user.email flaky-fixture@example.com
  git config user.name "flaky fixture"
  git symbolic-ref HEAD refs/heads/main
  echo "baseline" > base.txt
  git add base.txt
  git commit -q -m "init"
  git checkout -q -b hydra/commander/190
)

# Helper: write a flaky-tool marker into $ftmp/.hydra/flaky-tool.json.
# Args: <failures> <last_failure_epoch> [raw_override]
write_marker() {
  mkdir -p "$ftmp/.hydra"
  if [[ -n "${3:-}" ]]; then
    printf '%s' "$3" > "$ftmp/.hydra/flaky-tool.json"
  else
    printf '{"tool":"browse-daemon","failures":%s,"last_failure_epoch":%s,"fallback":"curl/SDK + single screenshot"}\n' \
      "$1" "$2" > "$ftmp/.hydra/flaky-tool.json"
  fi
}
clear_marker() { rm -rf "$ftmp/.hydra"; }
now_epoch() { date +%s; }

# ---- 17. flaky-tool-retry: valid + recent marker on a CLEAN worktree → exit 5 ----
write_marker 4 "$(now_epoch)"
set +e
out="$("$RESCUE" --probe "$ftmp" hydra/commander/190 190 --base refs/heads/main)"
ec=$?
set -e
if [[ "$ec" -ne 5 ]]; then
  echo "FAIL: flaky-tool marker (clean worktree) expected exit 5, got $ec; out=$out" >&2
  exit 1
fi
if ! printf '%s' "$out" | grep -q '"verdict":"flaky-tool-retry"'; then
  echo "FAIL: expected flaky-tool-retry verdict; got: $out" >&2
  exit 1
fi
if ! printf '%s' "$out" | grep -q '"tool":"browse-daemon"'; then
  echo "FAIL: expected tool:browse-daemon in verdict; got: $out" >&2
  exit 1
fi
if ! printf '%s' "$out" | grep -q '"fallback":"curl/SDK + single screenshot"'; then
  echo "FAIL: expected fallback string in verdict; got: $out" >&2
  exit 1
fi

# ---- 18. flaky-tool-retry takes precedence over a DIRTY worktree ----
# A live worker blocked on a flaky tool may also have uncommitted edits. The
# flaky signal must win over the dirty→rescue-uncommitted path (we do NOT want
# to rescue-and-restart a live worker).
printf 'work in progress\n' > "$ftmp/wip.txt"
set +e
out="$("$RESCUE" --probe "$ftmp" hydra/commander/190 190 --base refs/heads/main)"
ec=$?
set -e
if [[ "$ec" -ne 5 ]]; then
  echo "FAIL: flaky-tool marker (dirty worktree) expected exit 5, got $ec; out=$out" >&2
  exit 1
fi
if ! printf '%s' "$out" | grep -q '"verdict":"flaky-tool-retry"'; then
  echo "FAIL: dirty worktree should still report flaky-tool-retry; got: $out" >&2
  exit 1
fi
rm -f "$ftmp/wip.txt"

# ---- 19. gating: marker below failure threshold → falls through (NOT flaky) ----
# A single failure is not yet "flaky"; default threshold is 2.
write_marker 1 "$(now_epoch)"
set +e
out="$("$RESCUE" --probe "$ftmp" hydra/commander/190 190 --base refs/heads/main)"
ec=$?
set -e
if [[ "$ec" -ne 0 ]]; then
  echo "FAIL: below-threshold marker should fall through to a normal verdict (exit 0), got $ec; out=$out" >&2
  exit 1
fi
if printf '%s' "$out" | grep -q '"verdict":"flaky-tool-retry"'; then
  echo "FAIL: below-threshold marker must NOT report flaky-tool-retry; got: $out" >&2
  exit 1
fi

# ---- 20. gating: stale marker (old last_failure_epoch) → falls through ----
# Default staleness window is 1800s; an hour-old failure is ignored.
write_marker 9 "$(( $(now_epoch) - 3600 ))"
set +e
out="$("$RESCUE" --probe "$ftmp" hydra/commander/190 190 --base refs/heads/main)"
ec=$?
set -e
if [[ "$ec" -ne 0 ]]; then
  echo "FAIL: stale marker should fall through to a normal verdict (exit 0), got $ec; out=$out" >&2
  exit 1
fi
if printf '%s' "$out" | grep -q '"verdict":"flaky-tool-retry"'; then
  echo "FAIL: stale marker must NOT report flaky-tool-retry; got: $out" >&2
  exit 1
fi

# ---- 21. gating: malformed marker (invalid JSON) → falls through, no crash ----
write_marker "" "" 'this is not json {{{'
set +e
out="$("$RESCUE" --probe "$ftmp" hydra/commander/190 190 --base refs/heads/main)"
ec=$?
set -e
if [[ "$ec" -ne 0 ]]; then
  echo "FAIL: malformed marker should fall through without crashing (exit 0), got $ec; out=$out" >&2
  exit 1
fi
if printf '%s' "$out" | grep -q '"verdict":"flaky-tool-retry"'; then
  echo "FAIL: malformed marker must NOT report flaky-tool-retry; got: $out" >&2
  exit 1
fi

# ---- 22. regression: NO marker → existing verdicts unchanged ----
# nothing-to-rescue on a clean branch with no marker (proves the new branch is
# fully gated behind the marker file's presence).
clear_marker
out="$("$RESCUE" --probe "$ftmp" hydra/commander/190 190 --base refs/heads/main)"
if ! printf '%s' "$out" | grep -q '"verdict":"nothing-to-rescue"'; then
  echo "FAIL: no marker on clean branch should still be nothing-to-rescue; got: $out" >&2
  exit 1
fi
# rescue-uncommitted on a dirty branch with no marker.
printf 'dirty without marker\n' > "$ftmp/dirty.txt"
out="$("$RESCUE" --probe "$ftmp" hydra/commander/190 190 --base refs/heads/main)"
if ! printf '%s' "$out" | grep -q '"verdict":"rescue-uncommitted"'; then
  echo "FAIL: no marker + dirty should still be rescue-uncommitted; got: $out" >&2
  exit 1
fi
rm -f "$ftmp/dirty.txt"

# ---- 23. --help documents the flaky-tool-retry verdict + exit code 5 ----
help_out="$("$RESCUE" --help 2>&1)"
if ! printf '%s' "$help_out" | grep -q 'flaky-tool-retry'; then
  echo "FAIL: --help missing 'flaky-tool-retry'" >&2
  exit 1
fi
if ! printf '%s' "$help_out" | grep -qE '^[[:space:]]*5[[:space:]]'; then
  echo "FAIL: --help missing exit code 5 row" >&2
  exit 1
fi

# ===========================================================================
# Ticket #206: --probe must read the TAIL of the worker's session trace
# (logs/traces/<ticket>.jsonl, the #197 substrate) to distinguish three states
# git-state alone conflates:
#   - worker-mid-tool-call (exit 6): an execute_tool span is open (start, no end)
#     — worker is ALIVE inside a slow tool; do NOT rescue.
#   - worker-looping       (exit 7): repeated identical tool spans / recursive
#     failures — worker is thrashing; rescue + restart.
#   - idle/inconclusive: falls through to the existing git-state verdicts.
# Trace is read via --trace-file so the fixture stays offline. The flaky-tool
# marker (#190) still wins over any trace verdict.
# Spec: docs/specs/2026-05-21-trace-fed-watchdog-forensics.md
# ===========================================================================

# A throwaway repo for the trace cases (keep $tmp/$ftmp state undisturbed).
ttmp="$(mktemp -d)"
trace_dir="$(mktemp -d)"
trap 'rm -rf "$tmp" "$mock" "$ftmp" "$ttmp" "$trace_dir"' EXIT
(
  cd "$ttmp"
  git init -q
  git config user.email trace-fixture@example.com
  git config user.name "trace fixture"
  git symbolic-ref HEAD refs/heads/main
  echo "baseline" > base.txt
  git add base.txt
  git commit -q -m "init"
  git checkout -q -b hydra/commander/206
)

trace_file="$trace_dir/206.jsonl"
write_trace() { printf '%s\n' "$@" > "$trace_file"; }

# Convenience: a root start line shared by several traces.
ROOT_START='{"ts":"2026-05-21T18:00:00.000Z","span_id":"root1","parent_span_id":null,"kind":"invoke_agent","attrs":{"gen_ai.operation.name":"invoke_agent","phase":"start","hydra.ticket":"206"}}'

# ---- 24. worker-mid-tool-call: trailing open execute_tool span → exit 6 ----
write_trace \
  "$ROOT_START" \
  '{"ts":"2026-05-21T18:00:01.000Z","span_id":"t1","parent_span_id":"root1","kind":"execute_tool","attrs":{"gen_ai.operation.name":"execute_tool","phase":"start","gen_ai.tool.name":"Edit"}}' \
  '{"ts":"2026-05-21T18:00:01.100Z","span_id":"t1","parent_span_id":"root1","kind":"execute_tool","attrs":{"gen_ai.operation.name":"execute_tool","phase":"end","gen_ai.tool.name":"Edit","hydra.tool.exit_code":0}}' \
  '{"ts":"2026-05-21T18:00:02.000Z","span_id":"t2","parent_span_id":"root1","kind":"execute_tool","attrs":{"gen_ai.operation.name":"execute_tool","phase":"start","gen_ai.tool.name":"Bash"}}'
set +e
out="$("$RESCUE" --probe "$ttmp" hydra/commander/206 206 --base refs/heads/main --trace-file "$trace_file")"
ec=$?
set -e
if [[ "$ec" -ne 6 ]]; then
  echo "FAIL: mid-tool-call trace expected exit 6, got $ec; out=$out" >&2
  exit 1
fi
if ! printf '%s' "$out" | grep -q '"verdict":"worker-mid-tool-call"'; then
  echo "FAIL: expected worker-mid-tool-call verdict; got: $out" >&2
  exit 1
fi
if ! printf '%s' "$out" | grep -q '"tool":"Bash"'; then
  echo "FAIL: expected tool:Bash (the open span's tool); got: $out" >&2
  exit 1
fi

# ---- 25. worker-looping (tool-repeat): K=3 same-tool closed spans → exit 7 ----
write_trace \
  "$ROOT_START" \
  '{"ts":"2026-05-21T18:00:01.000Z","span_id":"r1","parent_span_id":"root1","kind":"execute_tool","attrs":{"gen_ai.operation.name":"execute_tool","phase":"start","gen_ai.tool.name":"Bash"}}' \
  '{"ts":"2026-05-21T18:00:01.500Z","span_id":"r1","parent_span_id":"root1","kind":"execute_tool","attrs":{"gen_ai.operation.name":"execute_tool","phase":"end","gen_ai.tool.name":"Bash","hydra.tool.exit_code":1}}' \
  '{"ts":"2026-05-21T18:00:02.000Z","span_id":"r2","parent_span_id":"root1","kind":"execute_tool","attrs":{"gen_ai.operation.name":"execute_tool","phase":"start","gen_ai.tool.name":"Bash"}}' \
  '{"ts":"2026-05-21T18:00:02.500Z","span_id":"r2","parent_span_id":"root1","kind":"execute_tool","attrs":{"gen_ai.operation.name":"execute_tool","phase":"end","gen_ai.tool.name":"Bash","hydra.tool.exit_code":1}}' \
  '{"ts":"2026-05-21T18:00:03.000Z","span_id":"r3","parent_span_id":"root1","kind":"execute_tool","attrs":{"gen_ai.operation.name":"execute_tool","phase":"start","gen_ai.tool.name":"Bash"}}' \
  '{"ts":"2026-05-21T18:00:03.500Z","span_id":"r3","parent_span_id":"root1","kind":"execute_tool","attrs":{"gen_ai.operation.name":"execute_tool","phase":"end","gen_ai.tool.name":"Bash","hydra.tool.exit_code":1}}'
set +e
out="$("$RESCUE" --probe "$ttmp" hydra/commander/206 206 --base refs/heads/main --trace-file "$trace_file")"
ec=$?
set -e
if [[ "$ec" -ne 7 ]]; then
  echo "FAIL: looping (tool-repeat) trace expected exit 7, got $ec; out=$out" >&2
  exit 1
fi
if ! printf '%s' "$out" | grep -q '"verdict":"worker-looping"'; then
  echo "FAIL: expected worker-looping verdict; got: $out" >&2
  exit 1
fi
if ! printf '%s' "$out" | grep -q '"tool":"Bash"'; then
  echo "FAIL: expected tool:Bash (the looping tool); got: $out" >&2
  exit 1
fi
if ! printf '%s' "$out" | grep -qE '"repeat":[3-9]'; then
  echo "FAIL: expected repeat>=3; got: $out" >&2
  exit 1
fi

# ---- 26. worker-looping (recursive-failure): >=3 same error.type → exit 7 ----
write_trace \
  "$ROOT_START" \
  '{"ts":"2026-05-21T18:00:01.000Z","span_id":"e1","parent_span_id":"root1","kind":"execute_tool","attrs":{"gen_ai.operation.name":"execute_tool","phase":"end","gen_ai.tool.name":"Bash","error.type":"tool_error"}}' \
  '{"ts":"2026-05-21T18:00:02.000Z","span_id":"e2","parent_span_id":"root1","kind":"execute_tool","attrs":{"gen_ai.operation.name":"execute_tool","phase":"end","gen_ai.tool.name":"Edit","error.type":"tool_error"}}' \
  '{"ts":"2026-05-21T18:00:03.000Z","span_id":"e3","parent_span_id":"root1","kind":"execute_tool","attrs":{"gen_ai.operation.name":"execute_tool","phase":"end","gen_ai.tool.name":"Read","error.type":"tool_error"}}'
set +e
out="$("$RESCUE" --probe "$ttmp" hydra/commander/206 206 --base refs/heads/main --trace-file "$trace_file")"
ec=$?
set -e
if [[ "$ec" -ne 7 ]]; then
  echo "FAIL: looping (recursive-failure) trace expected exit 7, got $ec; out=$out" >&2
  exit 1
fi
if ! printf '%s' "$out" | grep -q '"verdict":"worker-looping"'; then
  echo "FAIL: expected worker-looping verdict (recursive-failure); got: $out" >&2
  exit 1
fi
if ! printf '%s' "$out" | grep -q '"error_type":"tool_error"'; then
  echo "FAIL: expected error_type:tool_error; got: $out" >&2
  exit 1
fi

# ---- 27. looping wins over a trailing open span (precedence) → exit 7 ----
# 3x repeated Bash, then one more open Bash start. Must be worker-looping, NOT
# worker-mid-tool-call (a thrashing worker often has one in-flight retry).
write_trace \
  "$ROOT_START" \
  '{"ts":"2026-05-21T18:00:01.000Z","span_id":"p1","parent_span_id":"root1","kind":"execute_tool","attrs":{"gen_ai.operation.name":"execute_tool","phase":"start","gen_ai.tool.name":"Bash"}}' \
  '{"ts":"2026-05-21T18:00:01.500Z","span_id":"p1","parent_span_id":"root1","kind":"execute_tool","attrs":{"gen_ai.operation.name":"execute_tool","phase":"end","gen_ai.tool.name":"Bash","hydra.tool.exit_code":1}}' \
  '{"ts":"2026-05-21T18:00:02.000Z","span_id":"p2","parent_span_id":"root1","kind":"execute_tool","attrs":{"gen_ai.operation.name":"execute_tool","phase":"start","gen_ai.tool.name":"Bash"}}' \
  '{"ts":"2026-05-21T18:00:02.500Z","span_id":"p2","parent_span_id":"root1","kind":"execute_tool","attrs":{"gen_ai.operation.name":"execute_tool","phase":"end","gen_ai.tool.name":"Bash","hydra.tool.exit_code":1}}' \
  '{"ts":"2026-05-21T18:00:03.000Z","span_id":"p3","parent_span_id":"root1","kind":"execute_tool","attrs":{"gen_ai.operation.name":"execute_tool","phase":"start","gen_ai.tool.name":"Bash"}}' \
  '{"ts":"2026-05-21T18:00:03.500Z","span_id":"p3","parent_span_id":"root1","kind":"execute_tool","attrs":{"gen_ai.operation.name":"execute_tool","phase":"end","gen_ai.tool.name":"Bash","hydra.tool.exit_code":1}}' \
  '{"ts":"2026-05-21T18:00:04.000Z","span_id":"p4","parent_span_id":"root1","kind":"execute_tool","attrs":{"gen_ai.operation.name":"execute_tool","phase":"start","gen_ai.tool.name":"Bash"}}'
set +e
out="$("$RESCUE" --probe "$ttmp" hydra/commander/206 206 --base refs/heads/main --trace-file "$trace_file")"
ec=$?
set -e
if [[ "$ec" -ne 7 ]]; then
  echo "FAIL: looping-with-trailing-open expected exit 7, got $ec; out=$out" >&2
  exit 1
fi
if ! printf '%s' "$out" | grep -q '"verdict":"worker-looping"'; then
  echo "FAIL: trailing-open-after-loop must be worker-looping, not mid-tool-call; got: $out" >&2
  exit 1
fi

# ---- 28. clean completed trace → falls through to git-state (nothing-to-rescue) ----
# All spans closed, no repeats. Clean worktree → nothing-to-rescue (exit 0).
write_trace \
  "$ROOT_START" \
  '{"ts":"2026-05-21T18:00:01.000Z","span_id":"c1","parent_span_id":"root1","kind":"execute_tool","attrs":{"gen_ai.operation.name":"execute_tool","phase":"start","gen_ai.tool.name":"Edit"}}' \
  '{"ts":"2026-05-21T18:00:01.100Z","span_id":"c1","parent_span_id":"root1","kind":"execute_tool","attrs":{"gen_ai.operation.name":"execute_tool","phase":"end","gen_ai.tool.name":"Edit","hydra.tool.exit_code":0}}' \
  '{"ts":"2026-05-21T18:00:09.000Z","span_id":"root1","parent_span_id":null,"kind":"invoke_agent","attrs":{"gen_ai.operation.name":"invoke_agent","phase":"end","hydra.ticket":"206"}}'
out="$("$RESCUE" --probe "$ttmp" hydra/commander/206 206 --base refs/heads/main --trace-file "$trace_file")"
if ! printf '%s' "$out" | grep -q '"verdict":"nothing-to-rescue"'; then
  echo "FAIL: clean completed trace should fall through to nothing-to-rescue; got: $out" >&2
  exit 1
fi

# ---- 29. no trace file → existing verdicts unchanged (regression) ----
# clean branch, no --trace-file, no trace at default path → nothing-to-rescue.
out="$("$RESCUE" --probe "$ttmp" hydra/commander/206 206 --base refs/heads/main)"
if ! printf '%s' "$out" | grep -q '"verdict":"nothing-to-rescue"'; then
  echo "FAIL: no trace on clean branch should still be nothing-to-rescue; got: $out" >&2
  exit 1
fi
# dirty branch, no trace → rescue-uncommitted.
printf 'dirty no trace\n' > "$ttmp/dirty.txt"
out="$("$RESCUE" --probe "$ttmp" hydra/commander/206 206 --base refs/heads/main)"
if ! printf '%s' "$out" | grep -q '"verdict":"rescue-uncommitted"'; then
  echo "FAIL: no trace + dirty should still be rescue-uncommitted; got: $out" >&2
  exit 1
fi
rm -f "$ttmp/dirty.txt"

# ---- 30. malformed trace → falls through, no crash ----
printf 'this is not json {{{\n{"partial":\n' > "$trace_file"
set +e
out="$("$RESCUE" --probe "$ttmp" hydra/commander/206 206 --base refs/heads/main --trace-file "$trace_file")"
ec=$?
set -e
if [[ "$ec" -ne 0 ]]; then
  echo "FAIL: malformed trace should fall through without crashing (exit 0), got $ec; out=$out" >&2
  exit 1
fi
if printf '%s' "$out" | grep -qE '"verdict":"worker-(looping|mid-tool-call)"'; then
  echo "FAIL: malformed trace must NOT report a trace verdict; got: $out" >&2
  exit 1
fi

# ---- 31. single non-repeated closed tool call → falls through (not looping/mid) ----
write_trace \
  "$ROOT_START" \
  '{"ts":"2026-05-21T18:00:01.000Z","span_id":"s1","parent_span_id":"root1","kind":"execute_tool","attrs":{"gen_ai.operation.name":"execute_tool","phase":"start","gen_ai.tool.name":"Bash"}}' \
  '{"ts":"2026-05-21T18:00:01.500Z","span_id":"s1","parent_span_id":"root1","kind":"execute_tool","attrs":{"gen_ai.operation.name":"execute_tool","phase":"end","gen_ai.tool.name":"Bash","hydra.tool.exit_code":0}}'
out="$("$RESCUE" --probe "$ttmp" hydra/commander/206 206 --base refs/heads/main --trace-file "$trace_file")"
if printf '%s' "$out" | grep -qE '"verdict":"worker-(looping|mid-tool-call)"'; then
  echo "FAIL: single closed tool span must NOT report a trace verdict; got: $out" >&2
  exit 1
fi
if ! printf '%s' "$out" | grep -q '"verdict":"nothing-to-rescue"'; then
  echo "FAIL: single closed tool span on clean branch should be nothing-to-rescue; got: $out" >&2
  exit 1
fi

# ---- 32. flaky-tool marker (#190) beats a looping trace (precedence) ----
# A worktree with BOTH a valid recent flaky-tool marker AND a looping trace must
# report flaky-tool-retry (exit 5) — the flaky signal is the most specific,
# carries an actionable fallback, and is checked before trace analysis.
write_trace \
  "$ROOT_START" \
  '{"ts":"2026-05-21T18:00:01.000Z","span_id":"f1","parent_span_id":"root1","kind":"execute_tool","attrs":{"gen_ai.operation.name":"execute_tool","phase":"start","gen_ai.tool.name":"Bash"}}' \
  '{"ts":"2026-05-21T18:00:01.500Z","span_id":"f1","parent_span_id":"root1","kind":"execute_tool","attrs":{"gen_ai.operation.name":"execute_tool","phase":"end","gen_ai.tool.name":"Bash","hydra.tool.exit_code":1}}' \
  '{"ts":"2026-05-21T18:00:02.000Z","span_id":"f2","parent_span_id":"root1","kind":"execute_tool","attrs":{"gen_ai.operation.name":"execute_tool","phase":"start","gen_ai.tool.name":"Bash"}}' \
  '{"ts":"2026-05-21T18:00:02.500Z","span_id":"f2","parent_span_id":"root1","kind":"execute_tool","attrs":{"gen_ai.operation.name":"execute_tool","phase":"end","gen_ai.tool.name":"Bash","hydra.tool.exit_code":1}}' \
  '{"ts":"2026-05-21T18:00:03.000Z","span_id":"f3","parent_span_id":"root1","kind":"execute_tool","attrs":{"gen_ai.operation.name":"execute_tool","phase":"start","gen_ai.tool.name":"Bash"}}' \
  '{"ts":"2026-05-21T18:00:03.500Z","span_id":"f3","parent_span_id":"root1","kind":"execute_tool","attrs":{"gen_ai.operation.name":"execute_tool","phase":"end","gen_ai.tool.name":"Bash","hydra.tool.exit_code":1}}'
mkdir -p "$ttmp/.hydra"
printf '{"tool":"browse-daemon","failures":4,"last_failure_epoch":%s,"fallback":"curl/SDK"}\n' "$(date +%s)" > "$ttmp/.hydra/flaky-tool.json"
set +e
out="$("$RESCUE" --probe "$ttmp" hydra/commander/206 206 --base refs/heads/main --trace-file "$trace_file")"
ec=$?
set -e
rm -rf "$ttmp/.hydra"
if [[ "$ec" -ne 5 ]]; then
  echo "FAIL: flaky marker + looping trace expected exit 5 (flaky wins), got $ec; out=$out" >&2
  exit 1
fi
if ! printf '%s' "$out" | grep -q '"verdict":"flaky-tool-retry"'; then
  echo "FAIL: flaky marker must win over trace looping verdict; got: $out" >&2
  exit 1
fi

# ---- 33. --help documents the trace verdicts + exit codes 6 and 7 ----
help_out="$("$RESCUE" --help 2>&1)"
if ! printf '%s' "$help_out" | grep -q 'worker-mid-tool-call'; then
  echo "FAIL: --help missing 'worker-mid-tool-call'" >&2
  exit 1
fi
if ! printf '%s' "$help_out" | grep -q 'worker-looping'; then
  echo "FAIL: --help missing 'worker-looping'" >&2
  exit 1
fi
if ! printf '%s' "$help_out" | grep -qE '^[[:space:]]*6[[:space:]]'; then
  echo "FAIL: --help missing exit code 6 row" >&2
  exit 1
fi
if ! printf '%s' "$help_out" | grep -qE '^[[:space:]]*7[[:space:]]'; then
  echo "FAIL: --help missing exit code 7 row" >&2
  exit 1
fi

# ===========================================================================
# Ticket #219: auto-rescue on completion. A worker that finishes CLEANLY but
# leaves verified work committed-but-unpushed (the #198 case: draft PR pushed
# early via #216, then newer commits never pushed) must be detectable distinctly
# from "never pushed at all". --probe gains a "rescue-unpushed" verdict; --rescue
# pushes the unpushed commits; and --rescue must NEVER commit gitignored secrets.
# These cases need a real remote, so they build a local bare repo as `origin`.
# Spec: docs/specs/2026-05-23-auto-rescue-on-completion.md
# ===========================================================================

# A dedicated repo pair with a real (local bare) remote so push paths work
# offline. Keeps $tmp/$ftmp/$ttmp state undisturbed.
rtmp_root="$(mktemp -d)"
trap 'rm -rf "$tmp" "$mock" "$ftmp" "$ttmp" "$trace_dir" "$rtmp_root"' EXIT
rremote="$rtmp_root/remote.git"
rwork="$rtmp_root/work"
git init -q --bare "$rremote"
(
  cd "$rtmp_root"
  git clone -q "$rremote" work
  cd work
  git config user.email rescue-unpushed@example.com
  git config user.name "rescue-unpushed fixture"
  git symbolic-ref HEAD refs/heads/main
  echo "baseline" > base.txt
  git add base.txt
  git commit -q -m "init"
  git push -q origin main
  git checkout -q -b hydra/commander/219
)

# ---- 34. rescue-commits regression: committed, NO remote branch → pushed:false
# Before the early-PR push, the branch only exists locally. This is the classic
# timeout-rescue path and must stay rescue-commits with pushed:false.
( cd "$rwork" && echo c1 > c1.txt && git add c1.txt && git commit -q -m "wip 1" )
out="$("$RESCUE" --probe "$rwork" hydra/commander/219 219)"
if ! printf '%s' "$out" | grep -q '"verdict":"rescue-commits"'; then
  echo "FAIL: committed + no remote branch should be rescue-commits; got: $out" >&2
  exit 1
fi
if ! printf '%s' "$out" | grep -q '"pushed":false'; then
  echo "FAIL: rescue-commits (no remote branch) should report pushed:false; got: $out" >&2
  exit 1
fi

# ---- 35. nothing-left regression: after the early draft-PR push, local==remote
# so there is nothing unpushed. The probe must NOT report rescue-unpushed (the
# truthful verdict is push-only or nothing-to-rescue depending on base ref).
( cd "$rwork" && git push -q -u origin hydra/commander/219 )
out="$("$RESCUE" --probe "$rwork" hydra/commander/219 219)"
if printf '%s' "$out" | grep -q '"verdict":"rescue-unpushed"'; then
  echo "FAIL: local==remote must NOT be rescue-unpushed; got: $out" >&2
  exit 1
fi
if ! printf '%s' "$out" | grep -qE '"verdict":"(push-only|nothing-to-rescue)"'; then
  echo "FAIL: after draft-PR push (local==remote) should be push-only/nothing-to-rescue; got: $out" >&2
  exit 1
fi

# ---- 36. rescue-unpushed: remote branch exists but local HEAD is ahead → NEW.
# This is the #198 bug: draft PR pushed, then a 2nd verified commit never pushed.
( cd "$rwork" && echo c2 > c2.txt && git add c2.txt && git commit -q -m "verified fixes, never pushed" )
out="$("$RESCUE" --probe "$rwork" hydra/commander/219 219)"
if ! printf '%s' "$out" | grep -q '"verdict":"rescue-unpushed"'; then
  echo "FAIL: committed-but-unpushed (remote branch behind) should be rescue-unpushed; got: $out" >&2
  exit 1
fi
if ! printf '%s' "$out" | grep -q '"pushed":true'; then
  echo "FAIL: rescue-unpushed should report pushed:true (the branch exists); got: $out" >&2
  exit 1
fi
if ! printf '%s' "$out" | grep -q '"unpushed":1'; then
  echo "FAIL: rescue-unpushed should report unpushed:1; got: $out" >&2
  exit 1
fi
# Must NOT regress to the old contradictory rescue-commits+pushed:true.
if printf '%s' "$out" | grep -q '"verdict":"rescue-commits"'; then
  echo "FAIL: committed-but-unpushed must be rescue-unpushed, not rescue-commits; got: $out" >&2
  exit 1
fi

# ---- 37. --rescue pushes the unpushed commit to the PR branch ----
# Use the real local remote (no --base override) so the script fetches+rebases+
# pushes for real. After rescue, origin/<branch> must equal local HEAD.
out="$("$RESCUE" --rescue "$rwork" hydra/commander/219 219)"
ec=$?
if [[ "$ec" -ne 0 ]]; then
  echo "FAIL: --rescue on committed-but-unpushed expected exit 0, got $ec; out=$out" >&2
  exit 1
fi
# --rescue prints git fetch/rebase/push progress on stdout, then the branch name
# as the LAST line (the documented contract Commander reads). Check the tail.
last_line="$(printf '%s\n' "$out" | tail -n1)"
if [[ "$last_line" != "hydra/commander/219" ]]; then
  echo "FAIL: --rescue should print the branch name as its last stdout line; got last: '$last_line' (full: $out)" >&2
  exit 1
fi
local_head="$(cd "$rwork" && git rev-parse HEAD)"
remote_head="$(cd "$rwork" && git rev-parse origin/hydra/commander/219)"
if [[ "$local_head" != "$remote_head" ]]; then
  echo "FAIL: after --rescue, origin branch ($remote_head) should equal local HEAD ($local_head)" >&2
  exit 1
fi
# A fresh probe now sees nothing left to rescue.
out="$("$RESCUE" --probe "$rwork" hydra/commander/219 219)"
if ! printf '%s' "$out" | grep -qE '"verdict":"(push-only|nothing-to-rescue)"'; then
  echo "FAIL: after --rescue push, probe should be push-only/nothing-to-rescue; got: $out" >&2
  exit 1
fi

# ---- 38. --rescue NEVER commits gitignored secrets ----
# Build a separate clean worktree with a .gitignore that excludes .env, drop an
# untracked .env (secret) plus a real work.txt, then --rescue. The rescue commit
# must contain work.txt but NOT .env. Uses --base refs/heads/main (no remote
# needed — we only assert what got committed, not the push).
stmp="$(mktemp -d)"
trap 'rm -rf "$tmp" "$mock" "$ftmp" "$ttmp" "$trace_dir" "$rtmp_root" "$stmp"' EXIT
(
  cd "$stmp"
  git init -q
  git config user.email secret-fixture@example.com
  git config user.name "secret fixture"
  git symbolic-ref HEAD refs/heads/main
  printf '.env\n' > .gitignore
  git add .gitignore
  git commit -q -m "init with gitignore"
  git checkout -q -b hydra/commander/219
)
printf 'SECRET_TOKEN=should-never-be-committed\n' > "$stmp/.env"
printf 'verified worker output\n' > "$stmp/work.txt"
# Sanity: git agrees .env is ignored.
if ! ( cd "$stmp" && git check-ignore .env >/dev/null 2>&1 ); then
  echo "FAIL: fixture .gitignore did not ignore .env" >&2
  exit 1
fi
out="$("$RESCUE" --rescue "$stmp" hydra/commander/219 219 --base refs/heads/main)"
ec=$?
if [[ "$ec" -ne 0 ]]; then
  echo "FAIL: --rescue (secrets fixture) expected exit 0, got $ec; out=$out" >&2
  exit 1
fi
# The rescue commit must include work.txt.
committed="$(cd "$stmp" && git show --stat --name-only --format= HEAD)"
if ! printf '%s' "$committed" | grep -qx 'work.txt'; then
  echo "FAIL: rescue commit should include work.txt; committed: $committed" >&2
  exit 1
fi
# The rescue commit must NOT include .env, and .env must not be tracked at all.
if printf '%s' "$committed" | grep -qx '.env'; then
  echo "FAIL: rescue commit committed gitignored .env (secret leak!); committed: $committed" >&2
  exit 1
fi
if ( cd "$stmp" && git ls-files --error-unmatch .env >/dev/null 2>&1 ); then
  echo "FAIL: .env is tracked after rescue (secret leak!)" >&2
  exit 1
fi

# ---- 39. --help documents the rescue-unpushed verdict ----
help_out="$("$RESCUE" --help 2>&1)"
if ! printf '%s' "$help_out" | grep -q 'rescue-unpushed'; then
  echo "FAIL: --help missing 'rescue-unpushed'" >&2
  exit 1
fi

echo "PASS: scripts/rescue-worker.sh probe fixture roundtrip"

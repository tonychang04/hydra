#!/usr/bin/env bash
#
# test-retro-file-proposed-edits.sh — regression test for
# scripts/retro-file-proposed-edits.sh.
#
# Uses a stub `gh` binary installed on PATH via HYDRA_GH that records
# argv into a log file and echoes predetermined URLs. No real GitHub
# calls are made.
#
# Style: matches scripts/test-check-claude-md-size.sh — bash, colored
# output, pass/fail counter, no external test harness.
#
# Spec: docs/specs/2026-04-17-retro-auto-file.md (ticket #142).

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SUBJECT="$SCRIPT_DIR/retro-file-proposed-edits.sh"

if [[ ! -x "$SUBJECT" ]]; then
  echo "test-retro-file-proposed-edits: $SUBJECT not found/executable" >&2
  exit 2
fi

if [[ -t 1 ]] && [[ "${NO_COLOR:-}" != "1" ]]; then
  C_GREEN=$'\033[32m'
  C_RED=$'\033[31m'
  C_DIM=$'\033[2m'
  C_BOLD=$'\033[1m'
  C_RESET=$'\033[0m'
else
  C_GREEN=""; C_RED=""; C_DIM=""; C_BOLD=""; C_RESET=""
fi

passed=0
failed=0
tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

say()  { printf "\n${C_BOLD}▸ %s${C_RESET}\n" "$*"; }
ok()   { printf "  ${C_GREEN}✓${C_RESET} %s\n" "$*"; passed=$((passed + 1)); }
bad()  { printf "  ${C_RED}✗${C_RESET} %s\n" "$*"; failed=$((failed + 1)); }

# -----------------------------------------------------------------------------
# Build a stub gh binary per scenario.
#
# The stub is a shell script we drop into a case-specific temp dir and
# point HYDRA_GH at. It reads state from env:
#   STUB_EXISTING_TITLES  — newline-delimited list of titles to report on
#                           `gh issue list`.
#   STUB_CREATE_URL       — URL to echo on `gh issue create`.
#   STUB_LOG              — path to append argv to (one line per call).
# -----------------------------------------------------------------------------

_write_stub() {
  local path="$1"
  cat >"$path" <<'STUB'
#!/usr/bin/env bash
# argv log
if [[ -n "${STUB_LOG:-}" ]]; then
  printf 'GH'
  for a in "$@"; do printf ' %q' "$a"; done
  printf '\n'
fi >>"${STUB_LOG:-/dev/null}"

case "$1" in
  issue)
    case "$2" in
      list)
        # Emit stub existing issues as a JSON array of {"title": "..."}.
        python3 - <<PY
import json, os
titles = os.environ.get("STUB_EXISTING_TITLES","")
rows = [{"title": t} for t in titles.splitlines() if t.strip()]
print(json.dumps(rows))
PY
        ;;
      create)
        # Echo the URL and exit 0 (unless STUB_CREATE_FAIL=1, then exit 1).
        if [[ "${STUB_CREATE_FAIL:-0}" == "1" ]]; then
          echo "stub create failure" >&2
          exit 1
        fi
        echo "${STUB_CREATE_URL:-https://github.com/tonychang04/hydra/issues/999}"
        ;;
      *)
        echo "stub: unknown issue subcommand $2" >&2; exit 2 ;;
    esac ;;
  api|label)
    # Label ops & REST POSTs just succeed silently.
    exit 0 ;;
  *)
    echo "stub: unknown top-level $1" >&2; exit 2 ;;
esac
STUB
  chmod +x "$path"
}

# -----------------------------------------------------------------------------
# Fixture writers
# -----------------------------------------------------------------------------

_retro_header() {
  cat <<MD
# Hydra Retro — Week of $1

## Shipped
- 4 PRs opened, 3 merged

## Stuck
- 7 workers hit commander-stuck; top 3 patterns:
  - pattern a: 3
  - pattern b: 2
  - pattern c: 2

## Escalations
- Human answered 3 novel questions; top themes:
  - theme a: 2
  - theme b: 1

## Citation leaderboard
- one entry

MD
}

_write_retro() {
  local dir="$1" week="$2" body="$3"
  mkdir -p "$dir"
  {
    _retro_header "$week"
    echo "$body"
  } >"$dir/$week.md"
}

# -----------------------------------------------------------------------------
# Assertion helpers
# -----------------------------------------------------------------------------

_run_subject() {
  # Pipes stdout so tests can capture. stderr flows to caller.
  local retros_dir="$1" week="$2"
  shift 2
  HYDRA_GH="$STUB" STUB_LOG="$STUB_LOG" \
    STUB_EXISTING_TITLES="${STUB_EXISTING_TITLES:-}" \
    STUB_CREATE_URL="${STUB_CREATE_URL:-https://github.com/tonychang04/hydra/issues/999}" \
    STUB_CREATE_FAIL="${STUB_CREATE_FAIL:-0}" \
    "$SUBJECT" --retros-dir "$retros_dir" --default-repo "tonychang04/hydra" "$@" "$week"
}

# -----------------------------------------------------------------------------
# Case 1: empty Proposed edits section
# -----------------------------------------------------------------------------

case1() {
  say "case 1: empty ## Proposed edits → exit 0, no gh calls"
  local dir="$tmpdir/c1"
  _write_retro "$dir" "2026-50" '
## Proposed edits

no pattern above minimum sample size this week
'
  STUB="$tmpdir/c1-gh"; _write_stub "$STUB"
  STUB_LOG="$tmpdir/c1-log"; : >"$STUB_LOG"

  local out rc
  out="$(_run_subject "$dir" "2026-50" 2>/dev/null)" && rc=0 || rc=$?

  if [[ "$rc" -eq 0 ]]; then ok "exit 0"; else bad "exit $rc, expected 0"; fi
  if [[ -z "$out" ]]; then ok "no stdout output"; else bad "stdout non-empty: $out"; fi
  if [[ ! -s "$STUB_LOG" ]]; then ok "no gh calls"; else bad "gh invoked: $(cat "$STUB_LOG")"; fi
}

# -----------------------------------------------------------------------------
# Case 2: one T2 bullet, no inline slug → files on default repo
# -----------------------------------------------------------------------------

case2() {
  say "case 2: one T2 bullet → FILED line, one gh issue create call"
  local dir="$tmpdir/c2"
  _write_retro "$dir" "2026-51" '
## Proposed edits

- Tighten the worker-spawn prompt so it always passes a ticket URL rather than the inlined body
'
  STUB="$tmpdir/c2-gh"; _write_stub "$STUB"
  STUB_LOG="$tmpdir/c2-log"; : >"$STUB_LOG"
  STUB_CREATE_URL="https://github.com/tonychang04/hydra/issues/1001"

  local out
  out="$(_run_subject "$dir" "2026-51")"

  if grep -q '^FILED: https://github.com/tonychang04/hydra/issues/1001$' <<<"$out"; then
    ok "FILED line emitted"
  else
    bad "FILED line missing; got: $out"
  fi

  local create_calls
  create_calls="$(grep -c 'issue create' "$STUB_LOG" || true)"
  if [[ "$create_calls" == "1" ]]; then ok "exactly one gh issue create"; else bad "got $create_calls create calls"; fi

  if grep -q -- '--label commander-ready' "$STUB_LOG" \
     && grep -q -- '--label commander-auto-filed' "$STUB_LOG" \
     && grep -q -- '--label commander-retro' "$STUB_LOG" \
     && grep -q -- '--label T2' "$STUB_LOG"; then
    ok "all four labels applied (commander-ready, commander-auto-filed, commander-retro, T2)"
  else
    bad "labels missing; log: $(cat "$STUB_LOG")"
  fi

  if grep -q -- '--assignee tonychang04' "$STUB_LOG"; then
    ok "assignee tonychang04 passed"
  else
    bad "assignee missing; log: $(cat "$STUB_LOG")"
  fi

  if grep -q 'retro 2026-51' "$STUB_LOG"; then
    ok "title contains [retro 2026-51]"
  else
    bad "title prefix missing; log: $(cat "$STUB_LOG")"
  fi
}

# -----------------------------------------------------------------------------
# Case 3: T1-prefix bullet → T1 label
# -----------------------------------------------------------------------------

case3() {
  say "case 3: T1-prefix bullet (docs:) → T1 label"
  local dir="$tmpdir/c3"
  _write_retro "$dir" "2026-52" '
## Proposed edits

- docs: clarify the retro auto-file flow in README
'
  STUB="$tmpdir/c3-gh"; _write_stub "$STUB"
  STUB_LOG="$tmpdir/c3-log"; : >"$STUB_LOG"

  _run_subject "$dir" "2026-52" >/dev/null

  if grep -q -- '--label T1' "$STUB_LOG" && ! grep -q -- '--label T2' "$STUB_LOG"; then
    ok "T1 applied, T2 not applied"
  else
    bad "tier label wrong; log: $(cat "$STUB_LOG")"
  fi
}

# -----------------------------------------------------------------------------
# Case 3b: T1-prefix mid-sentence → T2 (spec says prefixes match at START only)
# Regression for PR #169 review concern #2. Was incorrectly T1 before fix.
# -----------------------------------------------------------------------------

case3b() {
  say "case 3b: T1 keyword mid-sentence → T2 (not T1)"
  local dir="$tmpdir/c3b"
  _write_retro "$dir" "2026-02" '
## Proposed edits

- Improve testing coverage for docs: the retro flow
'
  STUB="$tmpdir/c3b-gh"; _write_stub "$STUB"
  STUB_LOG="$tmpdir/c3b-log"; : >"$STUB_LOG"

  _run_subject "$dir" "2026-02" >/dev/null

  if grep -q -- '--label T2' "$STUB_LOG" && ! grep -q -- '--label T1' "$STUB_LOG"; then
    ok "T2 applied, T1 not applied"
  else
    bad "tier label wrong (expected T2, not T1); log: $(cat "$STUB_LOG")"
  fi
}

# -----------------------------------------------------------------------------
# Case 4: T3 tripwire (auth) → SURFACE, no gh issue create
# -----------------------------------------------------------------------------

case4() {
  say "case 4: T3 tripwire → SURFACE line, no gh issue create"
  local dir="$tmpdir/c4"
  _write_retro "$dir" "2026-53" '
## Proposed edits

- Rework the supervisor auth handshake to rotate tokens on every session
'
  STUB="$tmpdir/c4-gh"; _write_stub "$STUB"
  STUB_LOG="$tmpdir/c4-log"; : >"$STUB_LOG"

  local out
  out="$(_run_subject "$dir" "2026-53")"

  if grep -q '^SURFACE: T3 ' <<<"$out"; then
    ok "SURFACE: T3 emitted"
  else
    bad "SURFACE line missing; got: $out"
  fi

  if ! grep -q 'issue create' "$STUB_LOG"; then
    ok "no gh issue create call"
  else
    bad "gh issue create invoked for T3; log: $(cat "$STUB_LOG")"
  fi
}

# -----------------------------------------------------------------------------
# Case 5: inline repo slug → files on that repo
# -----------------------------------------------------------------------------

case5() {
  say "case 5: inline slug owner/repo → target overrides default"
  local dir="$tmpdir/c5"
  _write_retro "$dir" "2026-54" '
## Proposed edits

- Improve otherorg/thingy build script handling for parallel test runs
'
  STUB="$tmpdir/c5-gh"; _write_stub "$STUB"
  STUB_LOG="$tmpdir/c5-log"; : >"$STUB_LOG"

  _run_subject "$dir" "2026-54" >/dev/null

  if grep -q -- '--repo otherorg/thingy' "$STUB_LOG"; then
    ok "--repo otherorg/thingy passed"
  else
    bad "repo not overridden; log: $(cat "$STUB_LOG")"
  fi
}

# -----------------------------------------------------------------------------
# Case 6: idempotency — matching title pre-exists → SKIPPED
# -----------------------------------------------------------------------------

case6() {
  say "case 6: duplicate title → SKIPPED, no issue create"
  local dir="$tmpdir/c6"
  local bullet='Tighten the worker-spawn prompt so it always passes a ticket URL rather than the inlined body'
  _write_retro "$dir" "2026-55" "
## Proposed edits

- $bullet
"
  STUB="$tmpdir/c6-gh"; _write_stub "$STUB"
  STUB_LOG="$tmpdir/c6-log"; : >"$STUB_LOG"

  # Compose the expected title the same way the subject does. Python
  # truncates the 95-char summary at codepoint 59 then appends "...".
  local expected_title="[retro 2026-55] Tighten the worker-spawn prompt so it always passes a ticke..."
  export STUB_EXISTING_TITLES="$expected_title"

  local out
  out="$(_run_subject "$dir" "2026-55")"
  unset STUB_EXISTING_TITLES

  if grep -q '^SKIPPED: ' <<<"$out"; then
    ok "SKIPPED line emitted"
  else
    bad "SKIPPED missing; got: $out"
  fi

  if ! grep -q 'issue create' "$STUB_LOG"; then
    ok "no gh issue create"
  else
    bad "gh issue create called despite duplicate; log: $(cat "$STUB_LOG")"
  fi
}

# -----------------------------------------------------------------------------
# Case 7: retro file missing → exit 1
# -----------------------------------------------------------------------------

case7() {
  say "case 7: missing retro file → exit 1"
  local dir="$tmpdir/c7-empty"; mkdir -p "$dir"
  STUB="$tmpdir/c7-gh"; _write_stub "$STUB"
  STUB_LOG="$tmpdir/c7-log"; : >"$STUB_LOG"

  local rc
  _run_subject "$dir" "2026-99" >/dev/null 2>&1 && rc=0 || rc=$?

  if [[ "$rc" -eq 1 ]]; then ok "exit 1"; else bad "exit $rc, expected 1"; fi
  if [[ ! -s "$STUB_LOG" ]]; then ok "no gh calls"; else bad "gh invoked: $(cat "$STUB_LOG")"; fi
}

# -----------------------------------------------------------------------------
# Case 8: two bullets, mixed (T2 file + T3 surface)
# -----------------------------------------------------------------------------

case8() {
  say "case 8: mixed bullets → one FILED, one SURFACE, one create call"
  local dir="$tmpdir/c8"
  _write_retro "$dir" "2026-56" '
## Proposed edits

- Tighten the worker-spawn prompt to pass ticket URL by reference
- Rotate auth tokens on supervisor handshake every session
'
  STUB="$tmpdir/c8-gh"; _write_stub "$STUB"
  STUB_LOG="$tmpdir/c8-log"; : >"$STUB_LOG"

  local out
  out="$(_run_subject "$dir" "2026-56")"

  local filed_count surf_count create_count
  filed_count="$(grep -c '^FILED:' <<<"$out" || true)"
  surf_count="$(grep -c '^SURFACE: T3 ' <<<"$out" || true)"
  create_count="$(grep -c 'issue create' "$STUB_LOG" || true)"

  if [[ "$filed_count" -eq 1 ]]; then ok "one FILED line"; else bad "got $filed_count FILED lines; out: $out"; fi
  if [[ "$surf_count" -eq 1 ]]; then ok "one SURFACE line"; else bad "got $surf_count SURFACE lines; out: $out"; fi
  if [[ "$create_count" -eq 1 ]]; then ok "one gh issue create call"; else bad "got $create_count create calls; log: $(cat "$STUB_LOG")"; fi
}

# -----------------------------------------------------------------------------
# Case 9: usage errors
# -----------------------------------------------------------------------------

case9() {
  say "case 9: usage error paths"
  local rc

  # missing week arg
  "$SUBJECT" >/dev/null 2>&1 && rc=0 || rc=$?
  if [[ "$rc" -eq 2 ]]; then ok "no args → exit 2"; else bad "no args exit $rc, expected 2"; fi

  # malformed week
  "$SUBJECT" "not-a-week" >/dev/null 2>&1 && rc=0 || rc=$?
  if [[ "$rc" -eq 2 ]]; then ok "malformed week → exit 2"; else bad "malformed week exit $rc, expected 2"; fi

  # unknown flag
  "$SUBJECT" --frobnicate foo 2026-16 >/dev/null 2>&1 && rc=0 || rc=$?
  if [[ "$rc" -eq 2 ]]; then ok "unknown flag → exit 2"; else bad "unknown flag exit $rc, expected 2"; fi
}

# -----------------------------------------------------------------------------
# Case 10: dry-run skips gh issue create
# -----------------------------------------------------------------------------

case10() {
  say "case 10: --dry-run skips gh issue create"
  local dir="$tmpdir/c10"
  _write_retro "$dir" "2026-57" '
## Proposed edits

- A simple T2 bullet with no tripwires at all
'
  STUB="$tmpdir/c10-gh"; _write_stub "$STUB"
  STUB_LOG="$tmpdir/c10-log"; : >"$STUB_LOG"

  local out
  out="$(_run_subject "$dir" "2026-57" --dry-run)"

  if grep -q '^DRY-RUN: would file on ' <<<"$out"; then
    ok "DRY-RUN line emitted"
  else
    bad "DRY-RUN missing; got: $out"
  fi

  if ! grep -q 'issue create' "$STUB_LOG"; then
    ok "no gh issue create in dry-run"
  else
    bad "gh issue create called despite --dry-run; log: $(cat "$STUB_LOG")"
  fi
}

# -----------------------------------------------------------------------------
# Run all
# -----------------------------------------------------------------------------

case1
case2
case3
case3b
case4
case5
case6
case7
case8
case9
case10

printf "\n${C_BOLD}Result:${C_RESET} %d passed, %d failed\n" "$passed" "$failed"
if [[ "$failed" -gt 0 ]]; then
  exit 1
fi
exit 0

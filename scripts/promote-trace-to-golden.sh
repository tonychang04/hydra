#!/usr/bin/env bash
#
# promote-trace-to-golden.sh — production-trace → self-test golden-case promotion.
#
# The production-to-test flywheel: convert ONE stuck/failed/rescued ticket's
# session trace (logs/traces/<ticket>.jsonl, #197) plus its rescue/review
# outcome into ONE kind:"script" golden case that self-test/run.sh consumes,
# growing the regression suite from real failures.
#
# What it produces (a "trace-replay" regression case, NOT a session-replay):
#   - A sanitized fixture self-test/fixtures/trace-golden/<ticket>.jsonl — the
#     trace with content attrs (gen_ai.prompt / gen_ai.completion) stripped from
#     every event (secrets hard-rail; default-off content rule from
#     trace-append.sh, belt-and-suspenders here).
#   - A kind:"script" case with id trace-golden-<ticket> whose steps assert:
#       1. the trace parses (trace-analyze.sh summary --json → exit 0, events>=1)
#       2. the recorded failure signature (an attrs."error.type") is still
#          detected (trace-analyze.sh errors --json). For a trace with NO
#          error.type (an idle ghost / nothing-to-rescue), step 2 instead asserts
#          .errors == 0 so the case is never empty and still guards the shape.
#
# Output modes:
#   - default / --dry-run / --emit-case-only : print the case JSON to stdout.
#   - --into <cases-file>                    : idempotently merge the case into
#                                              that file (drop any existing
#                                              trace-golden-<ticket>, then append).
#
# Idempotent: the case id is deterministic (trace-golden-<ticket>); re-running
# replaces, never duplicates. The fixture is overwritten in place.
#
# Conventions: mirrors scripts/promote-citations.sh (idempotent, --dry-run,
# --help, jq-built JSON, exit 0/2). bash + jq, offline, no daemon.
#
# Spec: docs/specs/2026-05-21-trace-to-golden-promotion.md (ticket #205)

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"
TRACE_ANALYZE="$SCRIPT_DIR/trace-analyze.sh"

# Default locations (relative to ROOT_DIR; the case cmds reference repo-relative
# paths so run.sh — which runs cmds from worktree root — resolves them).
FIXTURE_DIR_DEFAULT="$ROOT_DIR/self-test/fixtures/trace-golden"
FIXTURE_REL_DEFAULT="self-test/fixtures/trace-golden"

usage() {
  cat <<'EOF'
Usage: promote-trace-to-golden.sh --ticket <n> [options]

Convert a stuck/failed/rescued ticket's session trace into a kind:"script"
self-test golden case. Prints the case JSON to stdout by default.

Required:
  --ticket <n>          Ticket number/ref. Case id is trace-golden-<n>.

Options:
  --trace <file>        Trace JSONL (default: logs/traces/<n>.jsonl).
  --verdict <v>         Rescue verdict for provenance (e.g. nothing-to-rescue,
                        rescue-commits). Default: unknown.
  --outcome <o>         Review outcome for provenance (e.g. review-fail). Optional.
  --fixture-dir <dir>   Where to write the sanitized fixture
                        (default: self-test/fixtures/trace-golden).
  --into <cases-file>   Idempotently merge the case into this JSON cases file
                        instead of printing it (drops any existing case with the
                        same id, then appends). Writes the fixture too.
  --emit-case-only      Print ONLY the case JSON to stdout (no plan banner).
                        (default output already prints the case; this suppresses
                        the human-readable plan line on stderr.)
  --dry-run             Print the plan + case to stdout; write NOTHING (no
                        fixture, no merge).
  -h, --help            Show this help.

Exit codes:
  0  case emitted / merged
  2  usage error / missing-or-malformed trace
EOF
}

die_usage() { echo "promote-trace-to-golden: $1" >&2; usage >&2; exit 2; }
die_input() { echo "promote-trace-to-golden: $1" >&2; exit 2; }

# --- argument parsing --------------------------------------------------------
ticket=""
trace_file=""
verdict="unknown"
outcome=""
fixture_dir="$FIXTURE_DIR_DEFAULT"
into_file=""
dry_run=0
emit_case_only=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --ticket)        [[ $# -ge 2 ]] || die_usage "--ticket needs a value"; ticket="$2"; shift 2 ;;
    --trace)         [[ $# -ge 2 ]] || die_usage "--trace needs a value"; trace_file="$2"; shift 2 ;;
    --verdict)       [[ $# -ge 2 ]] || die_usage "--verdict needs a value"; verdict="$2"; shift 2 ;;
    --outcome)       [[ $# -ge 2 ]] || die_usage "--outcome needs a value"; outcome="$2"; shift 2 ;;
    --fixture-dir)   [[ $# -ge 2 ]] || die_usage "--fixture-dir needs a value"; fixture_dir="$2"; shift 2 ;;
    --into)          [[ $# -ge 2 ]] || die_usage "--into needs a value"; into_file="$2"; shift 2 ;;
    --emit-case-only) emit_case_only=1; shift ;;
    --dry-run)       dry_run=1; shift ;;
    -h|--help)       usage; exit 0 ;;
    *)               die_usage "unknown argument: $1" ;;
  esac
done

[[ -n "$ticket" ]] || die_usage "--ticket is required"
# Harden against shell injection: $ticket flows into the generated case `cmd`
# strings, which self-test/run.sh later executes via `bash -c "$cmd"`. A ticket
# like `99; rm -rf /` would inject. Ticket refs are always a number or a simple
# slug (e.g. 205, LIN-123) — restrict to a safe charset so a crafted value can
# never break out of the path argument in the generated command.
if [[ ! "$ticket" =~ ^[A-Za-z0-9._-]+$ ]]; then
  die_usage "--ticket must match ^[A-Za-z0-9._-]+$ (got '$ticket')"
fi

command -v jq >/dev/null 2>&1 || die_input "jq required but not found"
[[ -x "$TRACE_ANALYZE" ]] || die_input "trace-analyze.sh required but not found at $TRACE_ANALYZE"

# Default trace path.
[[ -n "$trace_file" ]] || trace_file="$ROOT_DIR/logs/traces/$ticket.jsonl"

[[ -f "$trace_file" ]] || die_input "trace file not found: $trace_file"
[[ -s "$trace_file" ]] || die_input "trace file is empty: $trace_file"

# Validate the trace is parseable JSONL with at least one event. Use plain
# `jq empty` (NOT `jq -e empty`): -e sets a non-zero exit when the last value is
# null/false/absent, and `empty` produces no output, so -e would spuriously fail
# a perfectly valid file. `jq empty` exits non-zero only on an actual parse error.
if ! jq empty "$trace_file" >/dev/null 2>&1; then
  die_input "trace file is not valid JSONL: $trace_file"
fi
n_events="$(jq -s 'length' "$trace_file")"
if [[ "$n_events" -lt 1 ]]; then
  die_input "trace has no events; nothing to promote: $trace_file"
fi

# --- compute the failure signature ------------------------------------------
# Distinct error.type values present in the trace (via the read tool, so the
# case is grounded in exactly what trace-analyze.sh reports today).
errors_json="$("$TRACE_ANALYZE" errors --json "$trace_file")"
# First error_type (the signature we pin); empty for an idle-ghost trace.
err_type="$(jq -r 'map(.error_type) | map(select(. != null)) | (.[0] // "")' <<<"$errors_json")"
# Harden: $err_type is interpolated into the generated jq filter string
# (index("$err_type")). A value containing a quote/backslash would break that
# filter (and is a content-injection vector via a crafted trace). error.type is
# a small known vocabulary (test_failed, tool_error, ...); if a value carries
# anything outside a safe charset, drop the signature and fall back to the
# idle-ghost (count-only) assertion rather than emit a broken filter.
if [[ -n "$err_type" ]] && [[ ! "$err_type" =~ ^[A-Za-z0-9._-]+$ ]]; then
  echo "promote-trace-to-golden: error.type '$err_type' has unsafe chars; falling back to count-only assertion" >&2
  err_type=""
fi

# --- relative fixture path for the case cmd ----------------------------------
# The generated case cmds must reference a worktree-root-relative path, because
# run.sh runs each step's cmd from worktree root (ROOT_DIR). So we resolve the
# (possibly relative) --fixture-dir to an absolute path, then express it relative
# to ROOT_DIR.
#
# Resolve to absolute: an absolute --fixture-dir is used as-is; a relative one is
# resolved against the CURRENT working directory (which, when run.sh invokes a
# case cmd, is ROOT_DIR). We canonicalize the parent dir (which may not exist yet)
# via a subshell mkdir-free pwd trick that tolerates a not-yet-created leaf.
abs_fixture_dir="$fixture_dir"
case "$fixture_dir" in
  /*) : ;;  # already absolute
  *)  abs_fixture_dir="$(pwd)/$fixture_dir" ;;
esac
# Normalize to ROOT_DIR-relative when under ROOT_DIR; else fall back to the
# default committed-location relative path (the case is meant to be committed at
# the default location and the fixture copied there).
fixture_rel="$FIXTURE_REL_DEFAULT"
case "$abs_fixture_dir" in
  "$ROOT_DIR"/*) fixture_rel="${abs_fixture_dir#"$ROOT_DIR"/}" ;;
  "$ROOT_DIR")   fixture_rel="" ;;
esac
if [[ -n "$fixture_rel" ]]; then
  fixture_path_rel="$fixture_rel/$ticket.jsonl"
else
  fixture_path_rel="$ticket.jsonl"
fi

# --- build the case JSON -----------------------------------------------------
case_id="trace-golden-$ticket"
promoted_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

if [[ -n "$err_type" ]]; then
  description="Auto-promoted from ticket #$ticket's failed/stuck/rescued run trace (verdict: $verdict). Regression-replay: pins that the trace still parses and that its failure signature '$err_type' is still detected by trace-analyze.sh. Production-to-test flywheel; spec docs/specs/2026-05-21-trace-to-golden-promotion.md."
  # Step 2 asserts the captured error.type is still in the errors output.
  sig_jq="map(.error_type) | index(\"$err_type\") != null"
  sig_name="trace-$ticket still detects failure signature: $err_type"
else
  description="Auto-promoted from ticket #$ticket's stuck/idle run trace (verdict: $verdict). Regression-replay: pins that the trace parses and reports zero errors (idle ghost). Production-to-test flywheel; spec docs/specs/2026-05-21-trace-to-golden-promotion.md."
  sig_jq=".errors == 0"
  sig_name="trace-$ticket reports zero errors (idle ghost)"
fi

case_json="$(jq -nc \
  --arg id "$case_id" \
  --arg desc "$description" \
  --arg ticket "$ticket" \
  --arg verdict "$verdict" \
  --arg outcome "$outcome" \
  --arg promoted_at "$promoted_at" \
  --arg fixpath "$fixture_path_rel" \
  --arg sig_name "$sig_name" \
  --arg sig_jq "$sig_jq" \
  '{
    id: $id,
    kind: "script",
    _description: $desc,
    _provenance: ({ ticket: $ticket, verdict: $verdict, promoted_at: $promoted_at }
                  + (if $outcome == "" then {} else { outcome: $outcome } end)),
    tier: "T1",
    steps: [
      {
        name: ("trace-" + $ticket + " parses (summary exits 0)"),
        cmd: ("scripts/trace-analyze.sh summary --json " + $fixpath),
        expected_exit: 0,
        expected_stdout_jq: ".events >= 1 and .spans >= 1"
      },
      {
        name: $sig_name,
        cmd: ("scripts/trace-analyze.sh " + (if ($sig_jq | startswith(".errors")) then "summary" else "errors" end) + " --json " + $fixpath),
        expected_exit: 0,
        expected_stdout_jq: $sig_jq
      }
    ]
  }')"

# --- emit or write -----------------------------------------------------------
if [[ "$dry_run" -eq 1 ]]; then
  if [[ "$emit_case_only" -ne 1 ]]; then
    echo "promote-trace-to-golden: [dry-run] would write fixture $fixture_path_rel and case $case_id (verdict=$verdict, signature='${err_type:-<none>}')" >&2
  fi
  jq . <<<"$case_json"
  exit 0
fi

# Sanitize the trace: drop content attrs from every event, write the fixture.
mkdir -p "$fixture_dir"
fixture_out="$fixture_dir/$ticket.jsonl"
jq -c 'if (.attrs | type) == "object"
       then .attrs |= (del(."gen_ai.prompt") | del(."gen_ai.completion"))
       else . end' "$trace_file" > "$fixture_out"

if [[ -n "$into_file" ]]; then
  [[ -f "$into_file" ]] || die_input "--into cases file not found: $into_file"
  jq empty "$into_file" >/dev/null 2>&1 || die_input "--into cases file is not valid JSON: $into_file"
  # Idempotent merge: drop any existing case with this id, then append.
  tmp="$(mktemp)"
  jq --argjson c "$case_json" --arg id "$case_id" \
    '.cases = ((.cases // []) | map(select(.id != $id)) + [$c])' \
    "$into_file" > "$tmp"
  mv "$tmp" "$into_file"
  if [[ "$emit_case_only" -ne 1 ]]; then
    echo "promote-trace-to-golden: merged $case_id into $into_file; fixture $fixture_out" >&2
  fi
  exit 0
fi

# Default: print the case JSON (fixture already written).
if [[ "$emit_case_only" -ne 1 ]]; then
  echo "promote-trace-to-golden: wrote fixture $fixture_out; case $case_id (verdict=$verdict, signature='${err_type:-<none>}')" >&2
fi
jq . <<<"$case_json"
exit 0

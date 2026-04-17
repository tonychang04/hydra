#!/usr/bin/env bash
#
# record-demo.sh — drive a scripted asciinema recording of the Hydra auto-loop.
#
# This script sets up the recording harness; the operator drives the actual
# flow in front of a live terminal. That's the same pattern aider, lazygit, and
# k9s use — the script prints the scenario to stdout, the operator follows it,
# the cast captures everything in between.
#
# Spec: docs/specs/2026-04-17-asciinema-demo.md (ticket #37)
# Fixture: examples/hello-hydra-demo/ (from ticket #29)
#
# Usage:
#   ./scripts/record-demo.sh                       # interactive, writes docs/demo/demo.cast
#   ./scripts/record-demo.sh --output <path>       # custom cast path
#   ./scripts/record-demo.sh --convert             # after recording, render to SVG via agg
#   ./scripts/record-demo.sh --dry-run             # print the scenario, skip asciinema rec
#   ./scripts/record-demo.sh --help
#
# Environment:
#   HYDRA_DEMO_SPEED       Playback speed factor for asciinema (default: 1).
#                          Useful values: 1 (real-time), 2 (2x), 0.5 (half-speed).
#                          Applied at render time via `asciinema play -s $SPEED`
#                          or `agg --speed $SPEED` — does NOT affect recording.
#   HYDRA_DEMO_IDLE_LIMIT  asciinema --idle-time-limit value in seconds
#                          (default: 2). Collapses long pauses so the recording
#                          stays watchable.
#
# Hard rules:
#   - set -euo pipefail
#   - Bash only (no jq for this script; cast file is consumed elsewhere)
#   - Does NOT overwrite an existing non-placeholder cast without --force
#   - Refuses to run `agg` against a placeholder cast (detects via title)
#   - Does NOT touch CLAUDE.md, policy.md, state/*.json, or any code outside
#     docs/demo/

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"

DEFAULT_OUTPUT="$ROOT_DIR/docs/demo/demo.cast"
DEFAULT_SVG="$ROOT_DIR/docs/demo/demo.svg"
DEFAULT_IDLE_LIMIT="${HYDRA_DEMO_IDLE_LIMIT:-2}"
DEFAULT_SPEED="${HYDRA_DEMO_SPEED:-1}"

usage() {
  cat <<'EOF'
Usage: ./scripts/record-demo.sh [options]

Drives a scripted asciinema recording of the Hydra auto-loop end-to-end
against examples/hello-hydra-demo/. The script prints the scenario to follow,
launches `asciinema rec`, and the operator executes each step live inside the
recording session.

Options:
  --output <path>     Cast output path (default: docs/demo/demo.cast).
  --convert           After recording, render to SVG via `agg`. Requires agg
                      on PATH. Refuses on placeholder casts.
  --svg-output <path> SVG output path when --convert is set
                      (default: docs/demo/demo.svg).
  --force             Overwrite an existing non-placeholder cast.
  --dry-run           Print the scenario + environment summary; skip `asciinema rec`.
                      Exit 0. Useful for CI and for reviewing the flow.
  --no-preflight      Skip preflight checks (dangerous — only use in CI fixtures).
  -h, --help          Show this help.

Environment:
  HYDRA_DEMO_SPEED       Playback speed factor (default: 1). Applied at
                         render / convert time, not during recording.
  HYDRA_DEMO_IDLE_LIMIT  asciinema --idle-time-limit value in seconds
                         (default: 2). Collapses long pauses.

Exit codes:
  0   recording completed (or --dry-run succeeded)
  1   preflight failed (missing asciinema, missing gh auth, etc.)
  2   usage error
  3   refused to overwrite existing non-placeholder cast (use --force)
  4   refused to convert a placeholder cast to SVG (record a real cast first)

Example — preview the scenario without recording:
  ./scripts/record-demo.sh --dry-run

Example — record at 2x playback rendered to SVG:
  HYDRA_DEMO_SPEED=2 ./scripts/record-demo.sh --convert
EOF
}

# -----------------------------------------------------------------------------
# color / logging
# -----------------------------------------------------------------------------
if [[ -t 1 ]] && [[ "${NO_COLOR:-}" != "1" ]]; then
  C_GREEN=$'\033[32m'
  C_RED=$'\033[31m'
  C_YELLOW=$'\033[33m'
  C_DIM=$'\033[2m'
  C_BOLD=$'\033[1m'
  C_RESET=$'\033[0m'
else
  C_GREEN=""; C_RED=""; C_YELLOW=""; C_DIM=""; C_BOLD=""; C_RESET=""
fi

err()  { printf "%s✗%s %s\n" "$C_RED" "$C_RESET" "$*" >&2; }
ok()   { printf "%s✓%s %s\n" "$C_GREEN" "$C_RESET" "$*"; }
warn() { printf "%s⚠%s %s\n" "$C_YELLOW" "$C_RESET" "$*" >&2; }
info() { printf "%s•%s %s\n" "$C_DIM" "$C_RESET" "$*"; }

# -----------------------------------------------------------------------------
# arg parsing
# -----------------------------------------------------------------------------
OUTPUT="$DEFAULT_OUTPUT"
SVG_OUTPUT="$DEFAULT_SVG"
CONVERT=0
FORCE=0
DRY_RUN=0
NO_PREFLIGHT=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --output)
      [[ $# -ge 2 ]] || { err "--output needs a value"; usage >&2; exit 2; }
      OUTPUT="$2"; shift 2
      ;;
    --output=*)
      OUTPUT="${1#--output=}"; shift
      ;;
    --svg-output)
      [[ $# -ge 2 ]] || { err "--svg-output needs a value"; usage >&2; exit 2; }
      SVG_OUTPUT="$2"; shift 2
      ;;
    --svg-output=*)
      SVG_OUTPUT="${1#--svg-output=}"; shift
      ;;
    --convert)
      CONVERT=1; shift
      ;;
    --force)
      FORCE=1; shift
      ;;
    --dry-run)
      DRY_RUN=1; shift
      ;;
    --no-preflight)
      NO_PREFLIGHT=1; shift
      ;;
    -h|--help)
      usage; exit 0
      ;;
    *)
      err "unknown argument: $1"
      usage >&2
      exit 2
      ;;
  esac
done

# -----------------------------------------------------------------------------
# preflight
# -----------------------------------------------------------------------------
preflight() {
  local failed=0

  if ! command -v asciinema >/dev/null 2>&1; then
    err "asciinema not found on PATH."
    echo "   install: pip install asciinema   (macOS: brew install asciinema)" >&2
    failed=1
  fi

  if ! command -v gh >/dev/null 2>&1; then
    err "gh CLI not found on PATH."
    echo "   install: https://cli.github.com/" >&2
    failed=1
  elif ! gh auth status >/dev/null 2>&1; then
    err "gh is not authenticated."
    echo "   run: gh auth login" >&2
    failed=1
  fi

  if [[ ! -d "$ROOT_DIR/examples/hello-hydra-demo" ]]; then
    err "examples/hello-hydra-demo/ not found — this script expects the fixture from ticket #29."
    failed=1
  fi

  if [[ "$CONVERT" -eq 1 ]] && ! command -v agg >/dev/null 2>&1; then
    err "agg not found but --convert was requested."
    echo "   install: https://github.com/asciinema/agg" >&2
    echo "            cargo install --git https://github.com/asciinema/agg" >&2
    failed=1
  fi

  if [[ "$failed" -eq 1 ]]; then
    return 1
  fi
  return 0
}

# -----------------------------------------------------------------------------
# placeholder detection (refuses to convert placeholder -> SVG)
# -----------------------------------------------------------------------------
is_placeholder_cast() {
  local cast="$1"
  # asciinema v2 first line is a JSON object with optional "title" field.
  # Placeholder casts use `"title": "... placeholder ..."`.
  if [[ ! -s "$cast" ]]; then
    return 0  # empty counts as placeholder
  fi
  head -1 "$cast" | grep -q -i '"title"[[:space:]]*:[[:space:]]*"[^"]*placeholder'
}

# -----------------------------------------------------------------------------
# scenario — what the operator runs during the recording
# -----------------------------------------------------------------------------
print_scenario() {
  cat <<'EOF'

  ╭────────────────────────────────────────────────────────────────╮
  │  Hydra demo recording scenario                                 │
  │  Target length: ~60–90 seconds at 1x                           │
  │  Fixture:       examples/hello-hydra-demo/                     │
  ╰────────────────────────────────────────────────────────────────╯

  STEP 1 — Open Hydra (5s)
    cd ~/projects/hydra
    ./hydra

    Expected: session greeting prints; "3 tickets ready across 1 repo"

  STEP 2 — File the three fixture issues (10s)
    (in a second terminal, or paste this into the live Hydra terminal
     AFTER the session greeting)

    cd examples/hello-hydra-demo
    ./gh-filings.sh <your-fork-owner>/hello-hydra-demo

    Expected: 3 issue URLs print; all assigned to @me.

  STEP 3 — Dispatch Commander (5s)
    (back in the Hydra terminal)

    pick up 3

    Expected: one-line status per ticket. Three spawn announcements.

  STEP 4 — Watch the T1 auto-merge (20–30s)
    Commander spawns worker-implementation on issue #1 (the typo fix).
    Worker opens a draft PR, review worker runs, auto-merge fires.

    Expected: "PR #N auto-merged" one-liner in chat.

  STEP 5 — Watch the T3 refusal (instant)
    Issue #3 was refused at classification time — no worker was spawned.
    Run:

    gh issue view 3 --repo <your-fork>/hello-hydra-demo

    Expected: commander-stuck label + comment explaining the T3 tripwire.

  STEP 6 — Merge the T2 (15–20s)
    Issue #2 is T2 — worker-review cleared it, Commander surfaces it
    for your merge. Run:

    merge #<PR-num>

    Expected: Commander merges the PR. Issue #2 closes.

  STEP 7 — Inspect the learnings file (5s)
    cat memory/learnings-hello-hydra-demo.md

    Expected: one or more entries captured by the worker.

  STEP 8 — Stop the recording
    Press Ctrl+D inside asciinema (or exit the shell that asciinema
    spawned). The cast is saved to the --output path.

EOF
}

# -----------------------------------------------------------------------------
# main
# -----------------------------------------------------------------------------
main() {
  info "Hydra demo recorder — ticket #37"
  info "root:           $ROOT_DIR"
  info "output:         $OUTPUT"
  info "idle limit:     ${DEFAULT_IDLE_LIMIT}s"
  info "playback speed: ${DEFAULT_SPEED}x  (applied at render/convert, not record)"
  if [[ "$CONVERT" -eq 1 ]]; then
    info "svg output:     $SVG_OUTPUT"
  fi
  echo

  # Preflight unless explicitly skipped.
  if [[ "$NO_PREFLIGHT" -eq 0 ]]; then
    if ! preflight; then
      err "preflight failed — fix the issues above and re-run."
      exit 1
    fi
    ok "preflight passed"
  else
    warn "preflight skipped (--no-preflight)"
  fi

  # Overwrite guard.
  if [[ -f "$OUTPUT" ]] && [[ "$FORCE" -eq 0 ]] && [[ "$DRY_RUN" -eq 0 ]]; then
    if is_placeholder_cast "$OUTPUT"; then
      info "existing cast at $OUTPUT is a placeholder — will overwrite."
    else
      err "cast already exists at $OUTPUT (and is not a placeholder)."
      err "re-run with --force to overwrite, or use --output <path> to write elsewhere."
      exit 3
    fi
  fi

  # Print the scenario. The operator follows this while the recording runs.
  print_scenario

  if [[ "$DRY_RUN" -eq 1 ]]; then
    ok "dry-run complete — no recording started."
    exit 0
  fi

  # Ensure output directory exists.
  mkdir -p "$(dirname "$OUTPUT")"

  # Launch asciinema rec.
  # --idle-time-limit collapses long pauses
  # --overwrite: asciinema would refuse on an existing file; we already checked force above
  # --title: makes the cast identifiable in listings + lets self-tests verify provenance
  echo
  info "starting asciinema rec — follow the scenario above."
  info "press Ctrl+D (or 'exit') when done to save the cast."
  echo

  asciinema rec \
    --idle-time-limit "$DEFAULT_IDLE_LIMIT" \
    --overwrite \
    --title "Hydra auto-loop demo (recorded via scripts/record-demo.sh)" \
    "$OUTPUT"

  ok "recording saved: $OUTPUT"

  # Optional conversion to SVG via agg.
  if [[ "$CONVERT" -eq 1 ]]; then
    if is_placeholder_cast "$OUTPUT"; then
      err "refusing to convert a placeholder cast to SVG."
      err "record a real cast first (re-run without --convert, then run agg manually)."
      exit 4
    fi
    info "rendering SVG via agg at ${DEFAULT_SPEED}x…"
    agg --speed "$DEFAULT_SPEED" "$OUTPUT" "$SVG_OUTPUT"
    ok "svg saved: $SVG_OUTPUT"
  else
    echo
    info "next steps:"
    echo "   1. review: asciinema play $OUTPUT"
    echo "   2. render: agg --speed $DEFAULT_SPEED $OUTPUT $SVG_OUTPUT"
    echo "   3. embed:  update README.md '## Demo' block to reference docs/demo/demo.svg"
    echo "   4. commit: git add $OUTPUT $SVG_OUTPUT && git commit -m 'docs: refresh demo recording'"
  fi
}

main "$@"

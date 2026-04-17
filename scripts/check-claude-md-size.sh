#!/usr/bin/env bash
#
# check-claude-md-size.sh — enforce the CLAUDE.md character budget.
#
# CLAUDE.md is loaded into every Commander session's context. Every inlined
# procedure is a token tax paid forever. This script is the hard rail that
# keeps CLAUDE.md to routing tables + hard rails + one-line spec pointers;
# full procedures belong in docs/specs/.
#
# Behavior:
#   - Default path:      <repo-root>/CLAUDE.md
#   - Default threshold: 18000 chars (ticket #138, spec docs/specs/2026-04-17-claudemd-size-guard.md)
#   - Override threshold via --max <N> or env HYDRA_CLAUDEMD_MAX (flag wins)
#   - Exit 0: size <= max. One-line ok message.
#   - Exit 1: size >  max. Prints size header + top 5 H2 sections by char count
#             as trim candidates, each tagged with an "already has spec?" hint.
#   - Exit 2: usage error / file unreadable.
#
# Intended caller: scripts/validate-state-all.sh (first preflight item).
# Also safe for operator pre-push sanity, pre-commit hooks, or CI gates.
#
# Spec: docs/specs/2026-04-17-claudemd-size-guard.md

set -euo pipefail

# -----------------------------------------------------------------------------
# resolve worktree root (script lives at <root>/scripts/check-claude-md-size.sh)
# -----------------------------------------------------------------------------
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"

# -----------------------------------------------------------------------------
# color / TTY
# -----------------------------------------------------------------------------
if [[ -t 1 ]] && [[ "${NO_COLOR:-}" != "1" ]]; then
  C_GREEN=$'\033[32m'
  C_RED=$'\033[31m'
  C_YELLOW=$'\033[33m'
  C_DIM=$'\033[2m'
  C_BOLD=$'\033[1m'
  C_RESET=$'\033[0m'
else
  C_GREEN=""
  C_RED=""
  C_YELLOW=""
  C_DIM=""
  C_BOLD=""
  C_RESET=""
fi

usage() {
  cat <<'EOF'
Usage: check-claude-md-size.sh [options]

Enforces the CLAUDE.md character budget. Exits 1 if the file is over the
threshold (default 18000 chars) and prints the top 5 H2 sections by size as
trim candidates.

Options:
  --path <file>   Path to the CLAUDE.md to check (default: <repo-root>/CLAUDE.md)
  --max <N>       Maximum allowed character count (default: 18000)
  -h, --help      Show this help.

Environment:
  HYDRA_CLAUDEMD_MAX    Override threshold. Flag wins if both are set.
  NO_COLOR=1            Disable colored output.

Exit codes:
  0 = under budget · 1 = over budget · 2 = usage error / file unreadable

Spec: docs/specs/2026-04-17-claudemd-size-guard.md
EOF
}

# -----------------------------------------------------------------------------
# arg parsing
# -----------------------------------------------------------------------------
claude_md_path=""
max_chars=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --path)
      [[ $# -ge 2 ]] || { echo "check-claude-md-size: --path needs a value" >&2; usage >&2; exit 2; }
      claude_md_path="$2"; shift 2
      ;;
    --path=*)
      claude_md_path="${1#--path=}"; shift
      ;;
    --max)
      [[ $# -ge 2 ]] || { echo "check-claude-md-size: --max needs a value" >&2; usage >&2; exit 2; }
      max_chars="$2"; shift 2
      ;;
    --max=*)
      max_chars="${1#--max=}"; shift
      ;;
    -h|--help)
      usage; exit 0
      ;;
    --)
      shift; break
      ;;
    *)
      echo "check-claude-md-size: unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

# -----------------------------------------------------------------------------
# defaults
# -----------------------------------------------------------------------------
if [[ -z "$claude_md_path" ]]; then
  claude_md_path="$ROOT_DIR/CLAUDE.md"
fi

# Flag wins over env; env wins over built-in default.
if [[ -z "$max_chars" ]]; then
  if [[ -n "${HYDRA_CLAUDEMD_MAX:-}" ]]; then
    max_chars="$HYDRA_CLAUDEMD_MAX"
  else
    max_chars=18000
  fi
fi

# Validate --max is a non-negative integer.
if ! [[ "$max_chars" =~ ^[0-9]+$ ]]; then
  echo "check-claude-md-size: --max must be a non-negative integer (got: $max_chars)" >&2
  exit 2
fi

# -----------------------------------------------------------------------------
# file readability
# -----------------------------------------------------------------------------
if [[ ! -f "$claude_md_path" ]]; then
  echo "${C_RED}✗${C_RESET} CLAUDE.md not found: $claude_md_path" >&2
  exit 2
fi
if [[ ! -r "$claude_md_path" ]]; then
  echo "${C_RED}✗${C_RESET} CLAUDE.md not readable: $claude_md_path" >&2
  exit 2
fi

# -----------------------------------------------------------------------------
# size check — wc -c counts bytes; CLAUDE.md is ASCII so bytes == chars
# -----------------------------------------------------------------------------
size="$(wc -c < "$claude_md_path" | tr -d ' \n')"

# Under budget → single-line success and done.
if [[ "$size" -le "$max_chars" ]]; then
  printf "${C_GREEN}✓${C_RESET} check-claude-md-size: %s (%d / %d chars)\n" \
    "$claude_md_path" "$size" "$max_chars"
  exit 0
fi

# Over budget → fail loudly with trim candidates.
over=$((size - max_chars))
printf "${C_RED}✗${C_RESET} check-claude-md-size: ${C_BOLD}%s${C_RESET} is ${C_BOLD}%d / %d${C_RESET} chars (%d over)\n" \
  "$claude_md_path" "$size" "$max_chars" "$over" >&2
printf "  ${C_DIM}CLAUDE.md must hold only routing + hard rails + spec pointers.${C_RESET}\n" >&2
printf "  ${C_DIM}See docs/specs/2026-04-17-claudemd-size-guard.md and feedback_claudemd_bloat.md.${C_RESET}\n" >&2

# -----------------------------------------------------------------------------
# top 5 H2 sections by char count — awk splits on ^## and counts each section
# -----------------------------------------------------------------------------
printf "\n${C_YELLOW}top 5 H2 sections by char count (trim candidates):${C_RESET}\n" >&2

awk '
  BEGIN {
    section_name = "(preamble)"
    section_buf = ""
  }
  /^## / {
    # flush previous section
    printf "%d\t%s\n", length(section_buf), section_name
    # start new
    section_name = substr($0, 4)
    section_buf = $0 "\n"
    next
  }
  {
    section_buf = section_buf $0 "\n"
  }
  END {
    # flush the last section
    printf "%d\t%s\n", length(section_buf), section_name
  }
' "$claude_md_path" \
  | sort -rn \
  | head -5 \
  | awk -v red="$C_RED" -v dim="$C_DIM" -v reset="$C_RESET" '
      {
        chars = $1
        $1 = ""
        sub(/^ /, "", $0)
        printf "  %s%6d%s  %s\n", red, chars, reset, $0
      }
    ' >&2

exit 1

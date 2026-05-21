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
#
# Graduated bands (ticket #176, spec docs/specs/2026-05-20-claudemd-size-graduated-bands.md).
# Bands are a % of the ceiling; only the FAIL band changes the exit code:
#   - OK     (size <  notice_floor)        exit 0, one-line ✓ (silent on --quiet)
#   - NOTICE (notice_floor <= size < warn) exit 0, advisory line + top 3 trim candidates
#   - WARN   (warn_floor <= size <= max)   exit 0, prominent block + "trim first" call to action
#   - FAIL   (size > max)                  exit 1, ✗ + top 5 trim candidates (the hard rail)
# Cut points: notice_floor = max * NOTICE_PCT/100, warn_floor = max * WARN_PCT/100.
# Defaults NOTICE_PCT=85, WARN_PCT=95; tune via HYDRA_CLAUDEMD_NOTICE_PCT / _WARN_PCT.
# NOTICE/WARN inform but do NOT block preflight — only size > max blocks, exactly
# as the original binary guard did (so --max stays back-compatible / authoritative).
#
#   - Exit 0: OK / NOTICE / WARN (size <= max).
#   - Exit 1: FAIL (size > max).
#   - Exit 2: usage error / file unreadable / bad percentage.
#
# --quiet: silent at OK; one session-greeting "CLAUDE.md: …" line at NOTICE/WARN
# (and at FAIL, with exit 1). Mirrors scripts/hydra-connect.sh --status --quiet.
#
# Intended caller: scripts/validate-state-all.sh (last preflight item) + the
# Commander session-greeting one-liner. Also safe for pre-push / pre-commit / CI.
#
# Specs: docs/specs/2026-04-17-claudemd-size-guard.md (binary guard, original),
#        docs/specs/2026-05-20-claudemd-size-graduated-bands.md (NOTICE/WARN bands)

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

Enforces the CLAUDE.md character budget with graduated reaction bands. Exits 1
only when the file is over the ceiling (default 18000 chars). Below the ceiling
it emits advisory NOTICE / WARN bands (exit 0) as the file approaches the limit.

Options:
  --path <file>   Path to the CLAUDE.md to check (default: <repo-root>/CLAUDE.md)
  --max <N>       Maximum allowed character count / ceiling (default: 18000)
  --quiet         Session-greeting mode: silent at OK; one "CLAUDE.md: …" line
                  at NOTICE / WARN / FAIL. Mirrors hydra-connect --status --quiet.
  -h, --help      Show this help.

Bands (as % of the ceiling):
  OK     < NOTICE_PCT          exit 0, one-line ✓
  NOTICE NOTICE_PCT..<WARN_PCT exit 0, advisory + top 3 trim candidates
  WARN   WARN_PCT..100%        exit 0, prominent block + "trim first" call to action
  FAIL   > 100% (size > max)   exit 1, ✗ + top 5 trim candidates

Environment:
  HYDRA_CLAUDEMD_MAX         Override the ceiling. Flag wins if both are set.
  HYDRA_CLAUDEMD_NOTICE_PCT  NOTICE band floor as % of ceiling (default 85).
  HYDRA_CLAUDEMD_WARN_PCT    WARN band floor as % of ceiling (default 95).
                             Must satisfy NOTICE_PCT <= WARN_PCT <= 100.
  NO_COLOR=1                 Disable colored output.

Exit codes:
  0 = OK / NOTICE / WARN (size <= max) · 1 = FAIL (size > max)
  2 = usage error / file unreadable / bad percentage

Specs: docs/specs/2026-04-17-claudemd-size-guard.md,
       docs/specs/2026-05-20-claudemd-size-graduated-bands.md
EOF
}

# -----------------------------------------------------------------------------
# arg parsing
# -----------------------------------------------------------------------------
claude_md_path=""
max_chars=""
quiet=0

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
    --quiet)
      quiet=1; shift
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
# band cut points — % of the ceiling, env-overridable (no flags; tuning knobs)
# -----------------------------------------------------------------------------
notice_pct="${HYDRA_CLAUDEMD_NOTICE_PCT:-85}"
warn_pct="${HYDRA_CLAUDEMD_WARN_PCT:-95}"

for pair in "HYDRA_CLAUDEMD_NOTICE_PCT:$notice_pct" "HYDRA_CLAUDEMD_WARN_PCT:$warn_pct"; do
  name="${pair%%:*}"
  val="${pair#*:}"
  if ! [[ "$val" =~ ^[0-9]+$ ]]; then
    echo "check-claude-md-size: $name must be an integer 0..100 (got: $val)" >&2
    exit 2
  fi
  if [[ "$val" -gt 100 ]]; then
    echo "check-claude-md-size: $name must be <= 100 (got: $val)" >&2
    exit 2
  fi
done

# Bands must be ordered: NOTICE floor <= WARN floor (<= 100). An inverted pair
# would produce an empty/ambiguous band, so reject it loudly rather than guess.
if [[ "$notice_pct" -gt "$warn_pct" ]]; then
  echo "check-claude-md-size: HYDRA_CLAUDEMD_NOTICE_PCT ($notice_pct) must be <= HYDRA_CLAUDEMD_WARN_PCT ($warn_pct)" >&2
  exit 2
fi

# Integer-floor the cut points off the ceiling.
notice_floor=$(( max_chars * notice_pct / 100 ))
warn_floor=$(( max_chars * warn_pct / 100 ))

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
# top-N H2 sections by char count — awk splits on ^## and counts each section.
# Reused by NOTICE (top 3) and FAIL (top 5). Args: <count> <fd-color>; writes to
# the caller's chosen stream (caller redirects). Color arg is the accent color.
# -----------------------------------------------------------------------------
print_trim_candidates() {
  local count="$1" accent="$2"
  awk '
    BEGIN {
      section_name = "(preamble)"
      section_buf = ""
    }
    /^## / {
      printf "%d\t%s\n", length(section_buf), section_name
      section_name = substr($0, 4)
      section_buf = $0 "\n"
      next
    }
    {
      section_buf = section_buf $0 "\n"
    }
    END {
      printf "%d\t%s\n", length(section_buf), section_name
    }
  ' "$claude_md_path" \
    | sort -rn \
    | head -"$count" \
    | awk -v accent="$accent" -v dim="$C_DIM" -v reset="$C_RESET" '
        {
          chars = $1
          $1 = ""
          sub(/^ /, "", $0)
          # "spec exists?" hint: a pointer section already names a docs/specs/
          # file; a section with no such reference is the cheapest to externalize.
          printf "  %s%6d%s  %s\n", accent, chars, reset, $0
        }
      '
}

# -----------------------------------------------------------------------------
# size check — wc -c counts bytes; CLAUDE.md is ASCII so bytes == chars
# -----------------------------------------------------------------------------
size="$(wc -c < "$claude_md_path" | tr -d ' \n')"

# Percentage of the ceiling, integer-floored (max 0 ⇒ guard against /0).
if [[ "$max_chars" -gt 0 ]]; then
  pct=$(( size * 100 / max_chars ))
else
  pct=100
fi

# Classify into one of four bands. Boundaries (load-bearing):
#   FAIL   size >  max            (strictly over — preserves the original
#                                  `size <= max` ⇒ pass contract; size == max is WARN)
#   WARN   warn_floor   <= size <= max
#   NOTICE notice_floor <= size <  warn_floor
#   OK     size <  notice_floor
if [[ "$size" -gt "$max_chars" ]]; then
  band="FAIL"
elif [[ "$size" -ge "$warn_floor" ]]; then
  band="WARN"
elif [[ "$size" -ge "$notice_floor" ]]; then
  band="NOTICE"
else
  band="OK"
fi

# Chars remaining until the ceiling (0 if at/over).
if [[ "$size" -lt "$max_chars" ]]; then
  to_ceiling=$(( max_chars - size ))
else
  to_ceiling=0
fi

# -----------------------------------------------------------------------------
# --quiet: session-greeting one-liner. Silent at OK; one line otherwise.
# -----------------------------------------------------------------------------
if [[ "$quiet" -eq 1 ]]; then
  case "$band" in
    OK)
      : # silent — nothing to surface
      ;;
    NOTICE)
      printf "CLAUDE.md: %d/%d (%d%%) — approaching ceiling (%d to go); trim a section to a spec soon.\n" \
        "$size" "$max_chars" "$pct" "$to_ceiling"
      ;;
    WARN)
      printf "CLAUDE.md: %d/%d (%d%%) — WARN: the next routing addition breaches the gate; trim a section to a spec first.\n" \
        "$size" "$max_chars" "$pct"
      ;;
    FAIL)
      printf "CLAUDE.md: %d/%d (%d%%) — FAIL: over the ceiling; preflight is blocked until a section moves to a spec.\n" \
        "$size" "$max_chars" "$pct"
      ;;
  esac
  [[ "$band" == "FAIL" ]] && exit 1
  exit 0
fi

# -----------------------------------------------------------------------------
# verbose output, per band
# -----------------------------------------------------------------------------
case "$band" in
  OK)
    printf "${C_GREEN}✓${C_RESET} check-claude-md-size: %s (%d / %d chars)\n" \
      "$claude_md_path" "$size" "$max_chars"
    exit 0
    ;;

  NOTICE)
    # Advisory: exit 0, informs without blocking. Goes to stdout (not an error).
    printf "${C_YELLOW}●${C_RESET} check-claude-md-size: ${C_BOLD}NOTICE${C_RESET} — %s is %d/%d chars (%d%%), %d to ceiling.\n" \
      "$claude_md_path" "$size" "$max_chars" "$pct" "$to_ceiling"
    printf "  ${C_DIM}Approaching the ceiling. Move a section to a spec before adding routing.${C_RESET}\n"
    printf "${C_YELLOW}top 3 H2 sections by char count (trim candidates — prefer ones that already point to a spec):${C_RESET}\n"
    print_trim_candidates 3 "$C_YELLOW"
    exit 0
    ;;

  WARN)
    # Prominent advisory: exit 0, but loud. Still stdout (exit 0, not an error).
    printf "${C_BOLD}${C_YELLOW}▲ check-claude-md-size: WARN${C_RESET} — ${C_BOLD}%s${C_RESET} is ${C_BOLD}%d/%d${C_RESET} chars (${C_BOLD}%d%%${C_RESET}), only %d to ceiling.\n" \
      "$claude_md_path" "$size" "$max_chars" "$pct" "$to_ceiling"
    printf "  ${C_BOLD}The next routing addition will breach the gate.${C_RESET} Trim a section to a spec ${C_BOLD}before adding routing${C_RESET}.\n"
    printf "  ${C_DIM}CLAUDE.md must hold only routing + hard rails + spec pointers.${C_RESET}\n"
    printf "  ${C_DIM}See docs/specs/2026-05-20-claudemd-size-graduated-bands.md and feedback_claudemd_bloat.md.${C_RESET}\n"
    printf "${C_YELLOW}top 3 H2 sections by char count (trim candidates — prefer ones that already point to a spec):${C_RESET}\n"
    print_trim_candidates 3 "$C_YELLOW"
    exit 0
    ;;

  FAIL)
    # Hard rail: exit 1, error on stderr. Unchanged behavior.
    over=$((size - max_chars))
    printf "${C_RED}✗${C_RESET} check-claude-md-size: ${C_BOLD}%s${C_RESET} is ${C_BOLD}%d / %d${C_RESET} chars (%d over)\n" \
      "$claude_md_path" "$size" "$max_chars" "$over" >&2
    printf "  ${C_DIM}CLAUDE.md must hold only routing + hard rails + spec pointers.${C_RESET}\n" >&2
    printf "  ${C_DIM}See docs/specs/2026-04-17-claudemd-size-guard.md and feedback_claudemd_bloat.md.${C_RESET}\n" >&2
    printf "\n${C_YELLOW}top 5 H2 sections by char count (trim candidates):${C_RESET}\n" >&2
    print_trim_candidates 5 "$C_RED" >&2
    exit 1
    ;;
esac

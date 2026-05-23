#!/usr/bin/env bash
#
# validate-security-findings.sh — enforce the adversarial/consensus review gate
# for security-sensitive PRs (#199).
#
# A worker-review comment on a security-adjacent PR carries a FINDINGS TABLE: one
# row per security finding claim that the first reviewer (/review + /codex + /cso)
# raised, each annotated with the adversarial critic's verdict, the empirical
# oracle behind it, and the final disposition. This script is the machine-checkable
# load-bearing HARD RULE from the ticket:
#
#     Unanimity is NOT confidence. A finding is REPORTED (i.e. reaches the
#     operator as a SECURITY: blocker) only if it SURVIVED the critic's kill
#     mandate AND carries an empirical oracle (a PoC / failing test / repro).
#     A finding the critic REFUTED, or one with no oracle, must be DROPPED.
#
# It parses the findings table out of a review-comment body and exits non-zero
# when that invariant is violated, so the reviewer (and CI / future automation)
# can run it on the comment body BEFORE escalating a security finding.
#
# Spec: docs/specs/2026-05-21-adversarial-consensus-review.md
# Pattern: scripts/validate-evidence-table.sh (#196 sibling checker — same shape).
#
# Input:
#   - default:        read the comment body from stdin
#   - --file <path>:  read it from a file
#   - --body  <str>:  read it from a literal string argument
#
# Expected table (GitHub Markdown), embedded anywhere in the body:
#
#   | # | Finding | Critic verdict | Oracle | Disposition |
#   |---|---|---|---|---|
#   | 1 | SQL injection via `name` | SURVIVED | PoC `curl ...` -> 500 + stacktrace | REPORTED |
#   | 2 | Timing leak on compare   | REFUTED  | critic: timingSafeEqual, auth.ts:88 | DROPPED |
#   | 3 | Missing rate limit       | SURVIVED | (none) | DROPPED |
#
# Rules enforced:
#   - Header columns (case-insensitive): #, Finding, Critic verdict, Oracle,
#     Disposition. (Whitespace tolerant. "Critic verdict" / "Verdict" both ok.)
#   - Critic verdict in {SURVIVED, REFUTED} (case-insensitive). Else malformed.
#   - Disposition in {REPORTED, DROPPED} (case-insensitive). Else malformed.
#   - REPORTED => Critic verdict is SURVIVED  (a REFUTED-but-REPORTED finding
#     would page the operator on a disproven non-finding) -> violation.
#   - REPORTED => Oracle cell non-empty after stripping whitespace + placeholders
#     (a lone -, n/a, none, or backticks-only counts as EMPTY). "Opinion is not
#     confidence." -> violation.
#   - DROPPED rows are always legal (dropping is the safe direction; a finding
#     that survived critique but has no oracle is correctly DROPPED, not promoted).
#   - At least one finding (data) row must exist when the table is present.
#   - Oracle kinds are open: a PoC, a failing/added test + its line, a repro
#     command + output, a diff file:line. Any non-empty cell counts as an oracle.
#
# Pipes in cells: a pipe meant as literal content (a shell pipeline in an oracle)
# must be escaped as `\|` — exactly how GitHub renders a pipe inside a table cell.
# The splitter honors `\|` (protects it, restores it as a literal `|`), so an
# escaped pipe never shifts columns. (Borrowed verbatim from validate-evidence-table.sh.)
#
# Exit codes:
#   0 = valid (every REPORTED is SURVIVED + has an oracle; verdicts/dispositions
#       all legal; >=1 finding row).
#   1 = invariant violation (REPORTED w/o oracle, REPORTED+REFUTED, illegal
#       verdict/disposition, 0 rows).
#   2 = usage / parse error (no findings table found, bad header, unreadable file).

set -euo pipefail

# -----------------------------------------------------------------------------
# color / TTY
# -----------------------------------------------------------------------------
if [[ -t 2 ]] && [[ "${NO_COLOR:-}" != "1" ]]; then
  C_GREEN=$'\033[32m'
  C_RED=$'\033[31m'
  C_DIM=$'\033[2m'
  C_BOLD=$'\033[1m'
  C_RESET=$'\033[0m'
else
  C_GREEN=""
  C_RED=""
  C_DIM=""
  C_BOLD=""
  C_RESET=""
fi

usage() {
  cat <<'EOF'
Usage: validate-security-findings.sh [--file <path> | --body <str>]

Enforces the adversarial/consensus review gate (#199): a security finding is
REPORTED only when it SURVIVED the critic's kill mandate AND carries an empirical
oracle (PoC / failing test / reproduction). Unanimity is not confidence.

Input (one of):
  (default)        read the review-comment body from stdin
  --file <path>    read the body from a file
  --body  <str>    read the body from a literal string

Other:
  -h, --help       show this help.

Expected table (Markdown), anywhere in the body:
  | # | Finding | Critic verdict | Oracle | Disposition |
  |---|---|---|---|---|
  | 1 | SQL injection via name | SURVIVED | PoC `curl ...` -> 500 + stacktrace | REPORTED |
  | 2 | Timing leak on compare | REFUTED  | critic: timingSafeEqual, auth.ts:88 | DROPPED |
  | 3 | Missing rate limit     | SURVIVED | (none) | DROPPED |

Critic verdict: SURVIVED, REFUTED (case-insensitive).
Disposition:    REPORTED, DROPPED (case-insensitive).
Rule: REPORTED requires SURVIVED + a non-empty Oracle (a lone -, n/a, none, or
backticks-only counts as EMPTY). DROPPED rows are always legal.

Exit codes:
  0 = valid          1 = invariant violation (REPORTED w/o oracle, REPORTED+
                         REFUTED, bad verdict/disposition, zero findings)
  2 = usage / parse error (no table found, bad header, unreadable file)

Spec: docs/specs/2026-05-21-adversarial-consensus-review.md
EOF
}

# -----------------------------------------------------------------------------
# arg parsing
# -----------------------------------------------------------------------------
src_file=""
src_body=""
have_body=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --file)
      [[ $# -ge 2 ]] || { echo "validate-security-findings: --file needs a value" >&2; exit 2; }
      src_file="$2"; shift 2
      ;;
    --file=*)
      src_file="${1#--file=}"; shift
      ;;
    --body)
      [[ $# -ge 2 ]] || { echo "validate-security-findings: --body needs a value" >&2; exit 2; }
      src_body="$2"; have_body=1; shift 2
      ;;
    --body=*)
      src_body="${1#--body=}"; have_body=1; shift
      ;;
    -h|--help)
      usage; exit 0
      ;;
    --)
      shift; break
      ;;
    *)
      echo "validate-security-findings: unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

# -----------------------------------------------------------------------------
# read the body
# -----------------------------------------------------------------------------
if [[ -n "$src_file" ]]; then
  if [[ ! -r "$src_file" ]]; then
    echo "${C_RED}x${C_RESET} validate-security-findings: file not readable: $src_file" >&2
    exit 2
  fi
  body="$(cat -- "$src_file")"
elif [[ "$have_body" -eq 1 ]]; then
  body="$src_body"
else
  body="$(cat)"
fi

# -----------------------------------------------------------------------------
# trim helper — strip leading/trailing whitespace
# -----------------------------------------------------------------------------
trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"   # leading
  s="${s%"${s##*[![:space:]]}"}"   # trailing
  printf '%s' "$s"
}

# -----------------------------------------------------------------------------
# is_placeholder_oracle — true (0) if the oracle cell counts as EMPTY:
# blank, or a lone placeholder token (-, --, n/a, none, tbd), or backticks/
# punctuation only. Anything with real content is NOT a placeholder.
# -----------------------------------------------------------------------------
is_placeholder_oracle() {
  local cell
  cell="$(trim "$1")"
  local stripped="$cell"
  stripped="${stripped//\`/}"      # drop all backticks
  stripped="$(trim "$stripped")"
  [[ -z "$stripped" ]] && return 0
  case "$stripped" in
    "-"|"--"|"---"|"—"|"–") return 0 ;;
  esac
  local lower
  lower="$(printf '%s' "$stripped" | tr '[:upper:]' '[:lower:]')"
  case "$lower" in
    "n/a"|"na"|"none"|"tbd"|"todo"|"pending"|"?"|"(none)") return 0 ;;
  esac
  return 1
}

# -----------------------------------------------------------------------------
# split_row — normalize a table row into US-delimited (\x1f) cells, honoring
# escaped pipes (`\|`) as literal content. Borrowed verbatim from
# validate-evidence-table.sh so the two checkers parse tables identically.
# -----------------------------------------------------------------------------
split_row() {
  local row="$1"
  row="${row//\\|/$'\x1e'}"        # protect escaped pipes
  row="$(trim "$row")"
  row="${row#|}"
  row="${row%|}"
  local IFS='|'
  local -a cells=()
  read -r -a cells <<< "$row" || true
  local out="" first=1 c
  for c in "${cells[@]}"; do
    c="${c//$'\x1e'/|}"            # restore literal pipe
    if [[ "$first" -eq 1 ]]; then first=0; else out+=$'\x1f'; fi
    out+="$(trim "$c")"
  done
  printf '%s' "$out"
}

# -----------------------------------------------------------------------------
# read the body into a line array (bash 3.2 / macOS — no mapfile).
# -----------------------------------------------------------------------------
LINES=()
while IFS= read -r line || [[ -n "$line" ]]; do
  LINES+=("$line")
done <<< "$body"

# is_header_row — 0 if the line is the findings-table header:
# # | Finding | Critic verdict (or Verdict) | Oracle | Disposition.
is_header_row() {
  local line="$1"
  [[ "$line" == *"|"* ]] || return 1
  local cells c0 c1 c2 c3 c4
  cells="$(split_row "$line")"
  IFS=$'\x1f' read -r c0 c1 c2 c3 c4 _rest <<< "$cells"
  local l0 l1 l2 l3 l4
  l0="$(printf '%s' "$c0" | tr '[:upper:]' '[:lower:]')"
  l1="$(printf '%s' "$c1" | tr '[:upper:]' '[:lower:]')"
  l2="$(printf '%s' "$c2" | tr '[:upper:]' '[:lower:]')"
  l3="$(printf '%s' "$c3" | tr '[:upper:]' '[:lower:]')"
  l4="$(printf '%s' "$c4" | tr '[:upper:]' '[:lower:]')"
  [[ "$l0" == "#" \
     && "$l1" == "finding" \
     && ( "$l2" == "critic verdict" || "$l2" == "verdict" ) \
     && "$l3" == "oracle" \
     && "$l4" == "disposition" ]]
}

is_separator_row() {
  local line="$1"
  [[ "$line" == *"|"* && "$line" == *"-"* ]] || return 1
  local stripped="${line//[|: -]/}"
  [[ -z "$stripped" ]]
}

# -----------------------------------------------------------------------------
# locate the findings table (header followed immediately by a separator row).
# -----------------------------------------------------------------------------
header_line=0
sep_line=0
lineno=0

for i in "${!LINES[@]}"; do
  lineno=$((i + 1))
  line="${LINES[$i]}"
  if [[ "$header_line" -eq 0 ]]; then
    if is_header_row "$line"; then
      header_line="$lineno"
    fi
    continue
  fi
  if [[ "$sep_line" -eq 0 ]]; then
    if is_separator_row "$line"; then
      sep_line="$lineno"
      break
    else
      header_line=0
      if is_header_row "$line"; then
        header_line="$lineno"
      fi
      continue
    fi
  fi
done

if [[ "$header_line" -eq 0 || "$sep_line" -eq 0 ]]; then
  echo "${C_RED}x${C_RESET} validate-security-findings: no findings table found." >&2
  echo "${C_DIM}  Expected a header row: | # | Finding | Critic verdict | Oracle | Disposition |${C_RESET}" >&2
  echo "${C_DIM}  followed by a |---|---|---|---|---| separator. See spec docs/specs/2026-05-21-adversarial-consensus-review.md${C_RESET}" >&2
  exit 2
fi

# -----------------------------------------------------------------------------
# walk data rows and apply the invariant.
# -----------------------------------------------------------------------------
violations=0
row_count=0
data_start=$((sep_line + 1))

for ((ln = data_start; ln <= ${#LINES[@]}; ln++)); do
  idx=$((ln - 1))
  line="${LINES[$idx]}"
  trimmed="$(trim "$line")"
  [[ -z "$trimmed" ]] && break
  [[ "$trimmed" == *"|"* ]] || break

  cells="$(split_row "$line")"
  IFS=$'\x1f' read -r num finding verdict oracle disposition _rest <<< "$cells"
  row_count=$((row_count + 1))

  norm_verdict="$(printf '%s' "$(trim "$verdict")" | tr '[:lower:]' '[:upper:]')"
  norm_disp="$(printf '%s' "$(trim "$disposition")" | tr '[:lower:]' '[:upper:]')"

  # 1. legal critic verdict
  case "$norm_verdict" in
    SURVIVED|REFUTED) : ;;
    *)
      echo "${C_RED}x${C_RESET} validate-security-findings: row $row_count (finding $(trim "$num")) has illegal critic verdict '$(trim "$verdict")'." >&2
      echo "${C_DIM}    -> critic verdict must be SURVIVED or REFUTED.${C_RESET}" >&2
      violations=$((violations + 1))
      continue
      ;;
  esac

  # 2. legal disposition
  case "$norm_disp" in
    REPORTED|DROPPED) : ;;
    *)
      echo "${C_RED}x${C_RESET} validate-security-findings: row $row_count (finding $(trim "$num")) has illegal disposition '$(trim "$disposition")'." >&2
      echo "${C_DIM}    -> disposition must be REPORTED or DROPPED.${C_RESET}" >&2
      violations=$((violations + 1))
      continue
      ;;
  esac

  # 3. the load-bearing invariant: REPORTED => SURVIVED && non-empty oracle.
  if [[ "$norm_disp" == "REPORTED" ]]; then
    if [[ "$norm_verdict" == "REFUTED" ]]; then
      echo "${C_RED}x${C_RESET} validate-security-findings: row $row_count (finding $(trim "$num")) is REPORTED but the critic REFUTED it." >&2
      echo "${C_DIM}    finding: $(trim "$finding")${C_RESET}" >&2
      echo "${C_DIM}    -> a refuted finding must be DROPPED; reporting it pages the operator on a non-finding.${C_RESET}" >&2
      violations=$((violations + 1))
    elif is_placeholder_oracle "$oracle"; then
      echo "${C_RED}x${C_RESET} validate-security-findings: row $row_count (finding $(trim "$num")) is REPORTED with NO empirical oracle." >&2
      echo "${C_DIM}    finding: $(trim "$finding")${C_RESET}" >&2
      echo "${C_DIM}    -> a reported finding needs a PoC / failing test / reproduction; unanimity is not confidence. Drop it if you cannot demonstrate it.${C_RESET}" >&2
      violations=$((violations + 1))
    fi
  fi
  # DROPPED rows are always legal regardless of verdict/oracle.
done

# -----------------------------------------------------------------------------
# zero-findings check
# -----------------------------------------------------------------------------
if [[ "$row_count" -eq 0 ]]; then
  echo "${C_RED}x${C_RESET} validate-security-findings: the findings table has zero finding rows." >&2
  echo "${C_DIM}  -> if the first reviewer raised no security findings, OMIT the table entirely; do not emit an empty one.${C_RESET}" >&2
  exit 1
fi

# -----------------------------------------------------------------------------
# verdict
# -----------------------------------------------------------------------------
if [[ "$violations" -gt 0 ]]; then
  echo "${C_RED}${C_BOLD}validate-security-findings: FAIL${C_RESET} ($violations violation(s) across $row_count findings)" >&2
  exit 1
fi

echo "${C_GREEN}OK${C_RESET} validate-security-findings: $row_count findings, every REPORTED one survived the critic and carries an oracle."
exit 0

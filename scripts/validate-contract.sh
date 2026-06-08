#!/usr/bin/env bash
#
# validate-contract.sh — enforce the verify-first validation contract (#255).
#
# The implementation worker writes a `validation-contract.md` into its worktree
# BEFORE coding (each acceptance criterion -> the command that proves it), then
# fills each row with captured EVIDENCE (command + exit code + output snippet)
# before opening / finalizing the PR. This script is the machine-checkable HARD
# RULE — the completion gate:
#
#     Every assertion row MUST name a command (verify-first: the proof is named
#     up front), and a row marked PASS MUST carry non-empty evidence.
#     No PASS without evidence. An unproven assertion fails the gate.
#
# It parses the contract's table and exits non-zero when that invariant is
# violated, so the worker (and worker-review, and future automation) can run it
# on the artifact BEFORE the PR is finalized — "produce a file or exit code; never
# trust chat output."
#
# This EXTENDS the #196 evidence-based review gate
# (scripts/validate-evidence-table.sh), sharing its verdict + placeholder rules.
# The difference: this is the IMPLEMENTER-side, in-worktree, 6-column contract
# (Assertion + Command + Expected named first); #196 is the REVIEWER-side,
# in-PR-comment, 4-column evidence table. Same philosophy, distinct artifacts.
#
# Spec: docs/specs/2026-06-07-validation-contract.md
# Sibling checker (shared rules): scripts/validate-evidence-table.sh (#196).
#
# Input:
#   - default:         read the contract body from stdin
#   - --file <path>:   read it from a file
#   - --ticket <n>:    locate the contract by the #262 per-ticket convention
#                      (<worktree>/.hydra/contracts/<n>.md, via contract-path.sh)
#   - --body  <str>:   read it from a literal string argument
#
# Expected table (GitHub Markdown), embedded anywhere in the body:
#
#   | # | Assertion | Command | Expected | Verdict | Evidence |
#   |---|---|---|---|---|---|
#   | 1 | <criterion>  | `<cmd>` | exit 0 / `<out>` | PASS       | `<cmd>` -> exit 0; `<out>` |
#   | 2 | <criterion>  | `<cmd>` | `<expected>`     | FAIL       | observed: <what broke> |
#   | 3 | <criterion>  | `<cmd>` | `<expected>`     | UNVERIFIED | <why it couldn't run> |
#
# Rules enforced:
#   - The header row's six columns are (case-insensitive): #, Assertion, Command,
#     Expected, Verdict, Evidence. (Whitespace tolerant.)
#   - Every row's Assertion cell is non-empty.
#   - Every row's Command cell is non-empty + non-placeholder (regardless of
#     verdict) — verify-first means the proving command is always named.
#   - Verdict in {PASS, FAIL, UNVERIFIED} (case-insensitive). Else: malformed.
#   - PASS => Evidence cell non-empty after stripping whitespace + placeholders
#     (a lone -, n/a, none, tbd, or backticks-only counts as EMPTY).
#   - FAIL / UNVERIFIED may have empty evidence (a FAIL says what broke;
#     UNVERIFIED says why it could not be run in worker scope).
#   - At least one assertion (data) row must exist.
#
# Pipes in cells: a pipe meant as literal content (a shell pipeline in a Command
# or Evidence cell) must be escaped as `\|` — exactly how GitHub renders a pipe
# inside a table cell. The splitter honors `\|` (protects it, restores it as a
# literal `|`), so an escaped pipe never shifts columns. A RAW, unescaped `|`
# still splits the row at the first occurrence (truncating the tail into a
# discarded remainder) — but that can only make a cell SHORTER, never turn an
# empty cell into a non-empty one, so it cannot manufacture a false PASS.
#
# Exit codes:
#   0 = valid (every row has Assertion+Command; every PASS has evidence;
#       verdicts all legal; >=1 assertion).
#   1 = invariant violation (missing command/assertion, PASS without evidence,
#       illegal verdict, 0 rows).
#   2 = usage / parse error (no contract table found, bad header, unreadable file).

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
Usage: validate-contract.sh [--file <path> | --body <str>]

Enforces the verify-first validation contract completion gate (#255): the
worktree's validation-contract.md must name a Command for every assertion and
carry concrete Evidence for every PASS. No PASS without evidence; no assertion
without a proving command.

Input (one of):
  (default)        read the contract body from stdin
  --file <path>    read the body from a file
  --ticket <n>     locate the contract by the #262 per-ticket convention
                   (<worktree>/.hydra/contracts/<n>.md, via contract-path.sh)
  --body  <str>    read the body from a literal string

Other:
  --worktree <dir> worktree root for --ticket (default: git toplevel / cwd)
  -h, --help       show this help.

Expected table (Markdown), anywhere in the body:
  | # | Assertion | Command | Expected | Verdict | Evidence |
  |---|---|---|---|---|---|
  | 1 | ... | `cmd` | exit 0 / out | PASS       | `cmd` -> exit 0; out |
  | 2 | ... | `cmd` | expected     | FAIL       | what broke |
  | 3 | ... | `cmd` | expected     | UNVERIFIED | why it could not run |

Verdicts: PASS, FAIL, UNVERIFIED (case-insensitive).
Rules: every row needs a non-empty Command; PASS requires non-empty Evidence
(a lone -, n/a, none, tbd, or backticks-only is treated as EMPTY). FAIL /
UNVERIFIED may omit evidence.

Exit codes:
  0 = valid          1 = invariant violation (missing command/assertion, PASS
                         w/o evidence, bad verdict, zero assertions)
  2 = usage / parse error (no table found, bad header, unreadable file)

Spec: docs/specs/2026-06-07-validation-contract.md
EOF
}

# -----------------------------------------------------------------------------
# arg parsing
# -----------------------------------------------------------------------------
src_file=""
src_body=""
have_body=0
src_ticket=""
src_worktree=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --file)
      [[ $# -ge 2 ]] || { echo "validate-contract: --file needs a value" >&2; exit 2; }
      src_file="$2"; shift 2
      ;;
    --file=*)
      src_file="${1#--file=}"; shift
      ;;
    --ticket)
      [[ $# -ge 2 ]] || { echo "validate-contract: --ticket needs a value" >&2; exit 2; }
      src_ticket="$2"; shift 2
      ;;
    --ticket=*)
      src_ticket="${1#--ticket=}"; shift
      ;;
    --worktree)
      [[ $# -ge 2 ]] || { echo "validate-contract: --worktree needs a value" >&2; exit 2; }
      src_worktree="$2"; shift 2
      ;;
    --worktree=*)
      src_worktree="${1#--worktree=}"; shift
      ;;
    --body)
      [[ $# -ge 2 ]] || { echo "validate-contract: --body needs a value" >&2; exit 2; }
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
      echo "validate-contract: unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

# -----------------------------------------------------------------------------
# resolve --ticket into a file path (the #262 per-ticket convention). --ticket
# is mutually exclusive with --file / --body so the input source is unambiguous.
# -----------------------------------------------------------------------------
if [[ -n "$src_ticket" ]]; then
  if [[ -n "$src_file" || "$have_body" -eq 1 ]]; then
    echo "${C_RED}x${C_RESET} validate-contract: --ticket is mutually exclusive with --file / --body" >&2
    exit 2
  fi
  resolver="$(dirname -- "${BASH_SOURCE[0]}")/contract-path.sh"
  if [[ ! -x "$resolver" && ! -r "$resolver" ]]; then
    echo "${C_RED}x${C_RESET} validate-contract: contract-path.sh not found next to this script" >&2
    exit 2
  fi
  if [[ -n "$src_worktree" ]]; then
    src_file="$(bash "$resolver" "$src_ticket" --worktree "$src_worktree")" || exit 2
  else
    src_file="$(bash "$resolver" "$src_ticket")" || exit 2
  fi
fi

# -----------------------------------------------------------------------------
# read the body
# -----------------------------------------------------------------------------
if [[ -n "$src_file" ]]; then
  if [[ ! -r "$src_file" ]]; then
    echo "${C_RED}x${C_RESET} validate-contract: file not readable: $src_file" >&2
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
# is_placeholder — true (0) if a cell counts as EMPTY: blank, or a lone
# placeholder token (-, --, n/a, none, tbd, ...), or backticks/punctuation only.
# Shared rule with scripts/validate-evidence-table.sh (#196).
# -----------------------------------------------------------------------------
is_placeholder() {
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
    "n/a"|"na"|"none"|"tbd"|"todo"|"pending"|"?") return 0 ;;
  esac
  return 1
}

# -----------------------------------------------------------------------------
# split_row — normalize a Markdown table row into US-delimited (\x1f) trimmed
# cells. Escaped pipes (`\|`) are protected (RS \x1e) before splitting on `|`,
# then restored as literal `|`. Shared design with #196's checker.
# -----------------------------------------------------------------------------
split_row() {
  local row="$1"
  row="${row//\\|/$'\x1e'}"
  row="$(trim "$row")"
  row="${row#|}"
  row="${row%|}"
  local IFS='|'
  local -a cells=()
  read -r -a cells <<< "$row" || true
  local out="" first=1 c
  for c in "${cells[@]}"; do
    c="${c//$'\x1e'/|}"
    if [[ "$first" -eq 1 ]]; then first=0; else out+=$'\x1f'; fi
    out+="$(trim "$c")"
  done
  printf '%s' "$out"
}

# -----------------------------------------------------------------------------
# read all lines (preserve empties; bash 3.2 portable — no mapfile)
# -----------------------------------------------------------------------------
LINES=()
while IFS= read -r line || [[ -n "$line" ]]; do
  LINES+=("$line")
done <<< "$body"

is_header_row() {
  # $1 raw line; returns 0 if it's the contract-table header (6 columns).
  local line="$1"
  [[ "$line" == *"|"* ]] || return 1
  local cells c0 c1 c2 c3 c4 c5
  cells="$(split_row "$line")"
  IFS=$'\x1f' read -r c0 c1 c2 c3 c4 c5 _rest <<< "$cells"
  local l0 l1 l2 l3 l4 l5
  l0="$(printf '%s' "$c0" | tr '[:upper:]' '[:lower:]')"
  l1="$(printf '%s' "$c1" | tr '[:upper:]' '[:lower:]')"
  l2="$(printf '%s' "$c2" | tr '[:upper:]' '[:lower:]')"
  l3="$(printf '%s' "$c3" | tr '[:upper:]' '[:lower:]')"
  l4="$(printf '%s' "$c4" | tr '[:upper:]' '[:lower:]')"
  l5="$(printf '%s' "$c5" | tr '[:upper:]' '[:lower:]')"
  [[ "$l0" == "#" && "$l1" == "assertion" && "$l2" == "command" \
     && "$l3" == "expected" && "$l4" == "verdict" && "$l5" == "evidence" ]]
}

is_separator_row() {
  local line="$1"
  [[ "$line" == *"|"* && "$line" == *"-"* ]] || return 1
  local stripped="${line//[|: -]/}"
  [[ -z "$stripped" ]]
}

# -----------------------------------------------------------------------------
# locate the contract table (header followed by a separator)
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
  echo "${C_RED}x${C_RESET} validate-contract: no validation-contract table found." >&2
  echo "${C_DIM}  Expected a header row: | # | Assertion | Command | Expected | Verdict | Evidence |${C_RESET}" >&2
  echo "${C_DIM}  followed by a |---|---|---|---|---|---| separator. See docs/specs/2026-06-07-validation-contract.md${C_RESET}" >&2
  exit 2
fi

# -----------------------------------------------------------------------------
# walk data rows and apply the invariant
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
  IFS=$'\x1f' read -r num assertion command expected verdict evidence _rest <<< "$cells"
  row_count=$((row_count + 1))

  rownum="$(trim "$num")"
  [[ -n "$rownum" ]] || rownum="$row_count"

  # Assertion must be non-empty.
  if is_placeholder "$assertion"; then
    echo "${C_RED}x${C_RESET} validate-contract: row $row_count (assertion $rownum) has an EMPTY Assertion cell." >&2
    violations=$((violations + 1))
  fi

  # Command must be named for every row (verify-first).
  if is_placeholder "$command"; then
    echo "${C_RED}x${C_RESET} validate-contract: row $row_count (assertion $rownum) names NO command." >&2
    echo "${C_DIM}    assertion: $(trim "$assertion")${C_RESET}" >&2
    echo "${C_DIM}    -> verify-first: every assertion must name the command that proves it.${C_RESET}" >&2
    violations=$((violations + 1))
  fi

  norm_verdict="$(printf '%s' "$(trim "$verdict")" | tr '[:lower:]' '[:upper:]')"

  case "$norm_verdict" in
    PASS)
      if is_placeholder "$evidence"; then
        echo "${C_RED}x${C_RESET} validate-contract: row $row_count (assertion $rownum) is PASS with NO evidence." >&2
        echo "${C_DIM}    assertion: $(trim "$assertion")${C_RESET}" >&2
        echo "${C_DIM}    -> a PASS requires captured evidence (command + exit code + output); mark it UNVERIFIED if you could not run it.${C_RESET}" >&2
        violations=$((violations + 1))
      fi
      ;;
    FAIL|UNVERIFIED)
      : # evidence optional for these verdicts
      ;;
    *)
      echo "${C_RED}x${C_RESET} validate-contract: row $row_count (assertion $rownum) has illegal verdict '$(trim "$verdict")'." >&2
      echo "${C_DIM}    -> verdict must be one of PASS / FAIL / UNVERIFIED.${C_RESET}" >&2
      violations=$((violations + 1))
      ;;
  esac
done

# -----------------------------------------------------------------------------
# zero-assertion check
# -----------------------------------------------------------------------------
if [[ "$row_count" -eq 0 ]]; then
  echo "${C_RED}x${C_RESET} validate-contract: the contract table has zero assertion rows." >&2
  echo "${C_DIM}  -> derive at least one assertion from the ticket's acceptance criteria.${C_RESET}" >&2
  exit 1
fi

# -----------------------------------------------------------------------------
# verdict
# -----------------------------------------------------------------------------
if [[ "$violations" -gt 0 ]]; then
  echo "${C_RED}${C_BOLD}validate-contract: FAIL${C_RESET} ($violations violation(s) across $row_count assertion(s))" >&2
  exit 1
fi

echo "${C_GREEN}OK${C_RESET} validate-contract: $row_count assertion(s); every row names a command, every PASS carries evidence."
exit 0

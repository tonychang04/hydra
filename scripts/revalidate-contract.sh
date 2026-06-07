#!/usr/bin/env bash
#
# revalidate-contract.sh — the TRUTH gate for the verify-first validation
# contract (#256). Re-runs each contract assertion's Command and compares the
# ACTUAL exit/output to the contract's Expected + claimed Verdict.
#
# #255's validate-contract.sh checks evidence PRESENCE: every PASS row carries
# non-empty, non-placeholder text. It does NOT execute the command, so a worker
# can paste "works" as evidence for a command that, when actually run, FAILS —
# and the presence gate passes anyway (presence != truth). This script closes
# that gap, the Factory Missions "black-box validator / never trust chat output"
# lesson: it RE-RUNS the command itself and catches the lie.
#
#     A row claiming PASS whose re-run does NOT reproduce its Expected (wrong
#     exit, or the command errors) is a MISMATCH -> nonzero exit. The validator
#     trusts the re-run, NOT the worker's pasted Evidence cell.
#
# It SHARES validate-contract.sh's table splitter / placeholder / verdict rules
# (copied, not imported — bash has no clean import; validate-contract.sh is the
# reference the regression test pins parity against). It is a SEPARATE helper
# (not folded into validate-contract.sh) because re-execution is side-effecting:
# the presence gate is run liberally + must stay pure; this gate runs arbitrary
# commands and is the worker-validator's tool.
#
# Spec: docs/specs/2026-06-07-worker-validator.md
# Consumed by: .claude/agents/worker-validator.md (the after-review validator).
# Sibling (presence gate, shared rules): scripts/validate-contract.sh (#255).
#
# Input:
#   - default:        read the contract body from stdin
#   - --file <path>:  read it from a file
#   - --cwd  <dir>:   run each Command in this directory (default: current dir)
#   - --timeout <s>:  per-command kill bound in seconds (default: 120)
#
# Expected table (same 6 columns as #255):
#   | # | Assertion | Command | Expected | Verdict | Evidence |
#
# Re-run rules (per data row):
#   - UNVERIFIED rows are SKIPPED (the worker declared they could not be run;
#     re-running is out of scope) — reported SKIPPED, never fail the gate.
#   - Otherwise RE-RUN the Command in --cwd, bounded by a portable
#     `sleep N && kill` watchdog (macOS lacks `timeout`; never assume it),
#     capturing the ACTUAL exit code + an output snippet.
#   - Compare actual vs claimed (Expected parsing is lenient — it is human prose):
#       * Expected names `exit <N>`  -> require actual exit == N.
#       * else (no parseable exit)   -> claimed PASS requires actual exit 0;
#                                       claimed FAIL requires actual nonzero.
#       * Expected ALSO quotes an output substring (backtick/quote-wrapped) ->
#         require it in the captured output; a missing substring on an otherwise
#         exit-matching row is a WARN (snippets drift; exit code is the hard
#         signal), not a hard fail.
#   - A claimed-PASS row that does NOT reproduce -> MISMATCH (the lying-evidence
#     catch). FAIL rows are informational (a FAIL says what broke); they do not
#     fail the gate.
#
# Exit codes:
#   0 = every re-runnable claimed-PASS row reproduced its expectation
#       (UNVERIFIED/SKIPPED + WARN-only rows do not fail the gate).
#   1 = at least one claimed-PASS row did NOT reproduce (lying / stale evidence).
#   2 = usage / parse error (no contract table, unreadable file, bad header).

set -euo pipefail

# -----------------------------------------------------------------------------
# color / TTY
# -----------------------------------------------------------------------------
if [[ -t 2 ]] && [[ "${NO_COLOR:-}" != "1" ]]; then
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
Usage: revalidate-contract.sh [--file <path>] [--cwd <dir>] [--timeout <s>]

The TRUTH gate (#256): re-runs each validation-contract.md assertion's Command
and compares the ACTUAL exit/output to the contract's Expected + claimed Verdict.
Catches a contract whose pasted Evidence LIES (a PASS for a command that, when
re-run, actually fails). Never trust chat output — run it yourself.

Input (one of):
  (default)        read the contract body from stdin
  --file <path>    read the body from a file

Options:
  --cwd <dir>      run each Command in this directory (default: current dir)
  --timeout <s>    per-command kill bound in seconds (default: 120)
  -h, --help       show this help.

Re-run rules:
  - UNVERIFIED rows are SKIPPED (not run).
  - PASS rows are re-run; the row reproduces if actual exit matches Expected
    `exit <N>`, else (no parseable exit) PASS requires exit 0 / FAIL nonzero.
  - An Expected output substring that is missing (but exit matches) is a WARN.
  - A claimed-PASS row that does not reproduce is a MISMATCH.

Exit codes:
  0 = all claimed-PASS rows reproduced   1 = a claimed-PASS row did not reproduce
  2 = usage / parse error (no table found, bad header, unreadable file)

Spec: docs/specs/2026-06-07-worker-validator.md
Sibling (presence gate): scripts/validate-contract.sh (#255).
EOF
}

# -----------------------------------------------------------------------------
# arg parsing
# -----------------------------------------------------------------------------
src_file=""
run_cwd="."
timeout_s=120

while [[ $# -gt 0 ]]; do
  case "$1" in
    --file)
      [[ $# -ge 2 ]] || { echo "revalidate-contract: --file needs a value" >&2; exit 2; }
      src_file="$2"; shift 2
      ;;
    --file=*)
      src_file="${1#--file=}"; shift
      ;;
    --cwd)
      [[ $# -ge 2 ]] || { echo "revalidate-contract: --cwd needs a value" >&2; exit 2; }
      run_cwd="$2"; shift 2
      ;;
    --cwd=*)
      run_cwd="${1#--cwd=}"; shift
      ;;
    --timeout)
      [[ $# -ge 2 ]] || { echo "revalidate-contract: --timeout needs a value" >&2; exit 2; }
      timeout_s="$2"; shift 2
      ;;
    --timeout=*)
      timeout_s="${1#--timeout=}"; shift
      ;;
    -h|--help)
      usage; exit 0
      ;;
    --)
      shift; break
      ;;
    *)
      echo "revalidate-contract: unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ ! "$timeout_s" =~ ^[0-9]+$ ]] || [[ "$timeout_s" -le 0 ]]; then
  echo "revalidate-contract: --timeout must be a positive integer (seconds)" >&2
  exit 2
fi

# -----------------------------------------------------------------------------
# read the body
# -----------------------------------------------------------------------------
if [[ -n "$src_file" ]]; then
  if [[ ! -r "$src_file" ]]; then
    echo "${C_RED}x${C_RESET} revalidate-contract: file not readable: $src_file" >&2
    exit 2
  fi
  body="$(cat -- "$src_file")"
else
  body="$(cat)"
fi

if [[ ! -d "$run_cwd" ]]; then
  echo "${C_RED}x${C_RESET} revalidate-contract: --cwd is not a directory: $run_cwd" >&2
  exit 2
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
# is_placeholder — true (0) if a cell counts as EMPTY. Shared rule with
# scripts/validate-contract.sh (#255).
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
# then restored as literal `|`. Shared design with #255's checker.
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
# unwrap_code — strip a single surrounding pair of backticks from a cell so the
# command is runnable shell. `cmd` -> cmd. Leaves bare cells unchanged.
# -----------------------------------------------------------------------------
unwrap_code() {
  local s
  s="$(trim "$1")"
  if [[ "$s" == \`*\` ]]; then
    s="${s#\`}"
    s="${s%\`}"
  fi
  printf '%s' "$s"
}

# -----------------------------------------------------------------------------
# read all lines (preserve empties; bash 3.2 portable — no mapfile)
# -----------------------------------------------------------------------------
LINES=()
while IFS= read -r line || [[ -n "$line" ]]; do
  LINES+=("$line")
done <<< "$body"

is_header_row() {
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
  echo "${C_RED}x${C_RESET} revalidate-contract: no validation-contract table found." >&2
  echo "${C_DIM}  Expected a header row: | # | Assertion | Command | Expected | Verdict | Evidence |${C_RESET}" >&2
  echo "${C_DIM}  followed by a |---|---|---|---|---|---| separator. See docs/specs/2026-06-07-worker-validator.md${C_RESET}" >&2
  exit 2
fi

# -----------------------------------------------------------------------------
# run_bounded — run a shell command string in $run_cwd, bounded by a portable
# sleep+kill watchdog (macOS has no `timeout`). Captures combined output to a
# temp file; echoes the actual exit code. Does NOT inherit set -e for the cmd.
# -----------------------------------------------------------------------------
run_bounded() {
  # NOTE: the CALLER wraps this in `set +e` / `set -e`. Do NOT toggle `set -e`
  # inside here — re-enabling it before `return $rc` would make a nonzero return
  # propagate as a script-fatal error at the call site (caught: bash -x showed
  # the script exiting straight to the EXIT trap on the first failing command).
  local cmd="$1" outfile="$2"
  local rc=0
  (
    cd "$run_cwd" || exit 127
    bash -c "$cmd"
  ) >"$outfile" 2>&1 &
  local cmd_pid=$!
  ( sleep "$timeout_s" && kill -9 "$cmd_pid" 2>/dev/null ) &
  local watch_pid=$!
  wait "$cmd_pid"; rc=$?
  kill "$watch_pid" 2>/dev/null || true
  wait "$watch_pid" 2>/dev/null || true
  return "$rc"
}

# -----------------------------------------------------------------------------
# expected_exit — parse an `exit <N>` token from the Expected cell. Echoes N, or
# empty if none. Recognizes "exit 0", "exit 1", "exits 0", "-> exit 2", etc.
# -----------------------------------------------------------------------------
expected_exit() {
  local exp lower
  exp="$(trim "$1")"
  lower="$(printf '%s' "$exp" | tr '[:upper:]' '[:lower:]')"
  if [[ "$lower" =~ exit[s]?[[:space:]]+([0-9]+) ]]; then
    printf '%s' "${BASH_REMATCH[1]}"
  fi
}

# -----------------------------------------------------------------------------
# expected_says_nonzero — true (0) if Expected indicates a nonzero/failure
# outcome without a specific number ("nonzero", "non-zero", "fails", "error").
# -----------------------------------------------------------------------------
expected_says_nonzero() {
  local lower
  lower="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
  case "$lower" in
    *nonzero*|*non-zero*|*"fails"*|*"failure"*|*"rejects"*) return 0 ;;
  esac
  return 1
}

# -----------------------------------------------------------------------------
# expected_substring — extract a quoted output substring from Expected (the part
# after a `/` separator, or any backtick-wrapped token). Echoes it, or empty.
# Skips a bare `exit <N>` token (that is the exit clause, not output).
# -----------------------------------------------------------------------------
expected_substring() {
  local exp tail
  exp="$(trim "$1")"
  # take the part after the last " / " if present (Expected is "exit 0 / `OUT`")
  if [[ "$exp" == */* ]]; then
    tail="${exp##*/}"
  else
    tail="$exp"
  fi
  tail="$(trim "$tail")"
  # backtick-wrapped token wins
  if [[ "$tail" == *\`*\`* ]]; then
    local inner="${tail#*\`}"
    inner="${inner%%\`*}"
    printf '%s' "$(trim "$inner")"
    return 0
  fi
  # double-quote wrapped token
  if [[ "$tail" == *\"*\"* ]]; then
    local inner="${tail#*\"}"
    inner="${inner%%\"*}"
    printf '%s' "$(trim "$inner")"
    return 0
  fi
  # otherwise no machine-checkable substring (it is prose like "exit 0")
  printf '%s'
}

# -----------------------------------------------------------------------------
# walk data rows: re-run + compare
# -----------------------------------------------------------------------------
mismatches=0
warns=0
ran=0
skipped=0
row_count=0
data_start=$((sep_line + 1))
tmp_out="$(mktemp)"
trap 'rm -f "$tmp_out"' EXIT

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

  norm_verdict="$(printf '%s' "$(trim "$verdict")" | tr '[:lower:]' '[:upper:]')"
  cmd_str="$(unwrap_code "$command")"
  exp_cell="$(trim "$expected")"

  # UNVERIFIED -> SKIP (do not run). Also skip an empty/placeholder command
  # (the #255 presence gate already rejects those; here we just don't execute).
  if [[ "$norm_verdict" == "UNVERIFIED" ]] || is_placeholder "$command"; then
    echo "${C_YELLOW}SKIP${C_RESET} row $rownum (${norm_verdict:-?}): $(trim "$assertion")"
    skipped=$((skipped + 1))
    continue
  fi

  # Re-run the command.
  ran=$((ran + 1))
  set +e
  run_bounded "$cmd_str" "$tmp_out"
  actual_rc=$?
  set -e
  snippet="$(head -c 200 "$tmp_out" | tr '\n' ' ')"

  want_exit="$(expected_exit "$exp_cell")"
  want_sub="$(expected_substring "$exp_cell")"

  # Determine pass/fail of the re-run against the expectation.
  reproduced=1   # 1 = reproduced, 0 = mismatch
  reason=""

  if [[ -n "$want_exit" ]]; then
    if [[ "$actual_rc" -ne "$want_exit" ]]; then
      reproduced=0
      reason="expected exit $want_exit, got exit $actual_rc"
    fi
  elif expected_says_nonzero "$exp_cell"; then
    if [[ "$actual_rc" -eq 0 ]]; then
      reproduced=0
      reason="expected nonzero exit, got exit 0"
    fi
  else
    # No parseable exit in Expected -> verdict-driven fallback.
    case "$norm_verdict" in
      PASS)
        if [[ "$actual_rc" -ne 0 ]]; then
          reproduced=0
          reason="claimed PASS but command exited $actual_rc"
        fi
        ;;
      FAIL)
        # A FAIL row is informational; do not gate on it. Treat as reproduced.
        : ;;
    esac
  fi

  case "$norm_verdict" in
    PASS)
      if [[ "$reproduced" -eq 0 ]]; then
        echo "${C_RED}MISMATCH${C_RESET} row $rownum: $(trim "$assertion")" >&2
        echo "${C_DIM}    command : $cmd_str${C_RESET}" >&2
        echo "${C_DIM}    $reason${C_RESET}" >&2
        echo "${C_DIM}    output  : $snippet${C_RESET}" >&2
        echo "${C_DIM}    -> the contract's pasted evidence claims PASS, but the re-run disagrees.${C_RESET}" >&2
        mismatches=$((mismatches + 1))
      else
        # exit reproduced; check output substring as a soft signal.
        if [[ -n "$want_sub" ]] && ! grep -qF -- "$want_sub" "$tmp_out"; then
          echo "${C_YELLOW}WARN${C_RESET} row $rownum: exit reproduced (exit $actual_rc) but expected output \`$want_sub\` not found"
          echo "${C_DIM}    output  : $snippet${C_RESET}"
          warns=$((warns + 1))
        else
          echo "${C_GREEN}OK${C_RESET}   row $rownum (PASS reproduced, exit $actual_rc): $(trim "$assertion")"
        fi
      fi
      ;;
    FAIL)
      echo "${C_DIM}INFO row $rownum (FAIL, informational, exit $actual_rc): $(trim "$assertion")${C_RESET}"
      ;;
    *)
      # Illegal verdict — the presence gate (#255) catches this; here, surface it
      # but do not gate (truth gate's job is re-running, not verdict legality).
      echo "${C_YELLOW}WARN${C_RESET} row $rownum: unexpected verdict '$(trim "$verdict")' (run validate-contract.sh for verdict legality)"
      warns=$((warns + 1))
      ;;
  esac
done

# -----------------------------------------------------------------------------
# zero-row guard (the presence gate also catches this; mirror its contract)
# -----------------------------------------------------------------------------
if [[ "$row_count" -eq 0 ]]; then
  echo "${C_RED}x${C_RESET} revalidate-contract: the contract table has zero assertion rows." >&2
  exit 1
fi

# -----------------------------------------------------------------------------
# verdict
# -----------------------------------------------------------------------------
echo ""
if [[ "$mismatches" -gt 0 ]]; then
  echo "${C_RED}${C_BOLD}revalidate-contract: FAIL${C_RESET} ($mismatches mismatch(es); $ran re-run, $skipped skipped, $warns warn) over $row_count row(s)" >&2
  echo "${C_DIM}  A claimed-PASS assertion did not reproduce when re-run — the pasted evidence is stale or false.${C_RESET}" >&2
  exit 1
fi

echo "${C_GREEN}${C_BOLD}revalidate-contract: OK${C_RESET} ($ran re-run reproduced, $skipped skipped, $warns warn) over $row_count row(s)"
exit 0

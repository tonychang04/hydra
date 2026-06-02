#!/usr/bin/env bash
#
# validate-evidence-table.sh — enforce the evidence-bound review gate (#196).
#
# The worker-review comment must contain an EVIDENCE TABLE: one row per ticket
# acceptance criterion, each with a verdict (PASS / FAIL / UNVERIFIED) and the
# concrete evidence behind it. This script is the machine-checkable HARD RULE:
#
#     A criterion marked PASS MUST carry non-empty evidence.
#     No clean pass without evidence. Lacking evidence => UNVERIFIED, never PASS.
#
# It parses the table out of a review-comment body and exits non-zero when that
# invariant is violated, so the reviewer (and CI / future automation) can run it
# on the comment body BEFORE posting.
#
# Spec: docs/specs/2026-05-21-evidence-based-review-gate.md
# Pattern: docs/specs/2026-04-17-claudemd-size-guard.md (sibling checker shape).
#
# Input:
#   - default:        read the comment body from stdin
#   - --file <path>:  read it from a file
#   - --body  <str>:  read it from a literal string argument
#
# Expected table (GitHub Markdown), embedded anywhere in the body:
#
#   | # | Criterion | Verdict | Evidence |
#   |---|---|---|---|
#   | 1 | <criterion>  | PASS       | <command + output / test + pass line / file:line> |
#   | 2 | <criterion>  | FAIL       | <what's wrong> |
#   | 3 | <criterion>  | UNVERIFIED | <why it could not be verified> |
#
# Rules enforced:
#   - The header row's four columns are (case-insensitive): #, Criterion,
#     Verdict, Evidence. (Whitespace tolerant.)
#   - Verdict in {PASS, FAIL, UNVERIFIED} (case-insensitive). Else: malformed.
#   - PASS => Evidence cell non-empty after stripping whitespace + placeholders
#     (a lone -, n/a, none, or backticks-only counts as EMPTY).
#   - PASS => Evidence cell carries a POSITIVE behavioral-assertion signal
#     (#191 redesign — amendment 2). A PASS whose evidence is a screenshot ALONE,
#     or a bare prose claim ("it works"), carries no assertion signal and is
#     rejected exactly like an empty cell. The signal set is the documented
#     ASSERTION_SIGNALS allowlist (exit codes / HTTP status / test+assert
#     constructs / comparison operators / file:line + trace: refs / observed
#     REST-DOM-SDK state). This INVERTS the prior screenshot denylist, which
#     failed open; the allowlist fails closed (an unenumerated screenshot word
#     has no signal -> FAIL by construction). It also makes bare-claim-only FAIL,
#     incidentally closing #196/#209. See docs/specs/2026-05-21-evidence-based-
#     review-gate.md (amendment 2).
#   - FAIL / UNVERIFIED may have empty evidence (a FAIL says what's wrong;
#     UNVERIFIED says why it couldn't be checked).
#   - At least one criterion (data) row must exist.
#   - The #197 session trace's `trace:<id>` evidence kind is already a recognized
#     assertion signal (the `trace:` pattern in ASSERTION_SIGNALS), so it works
#     with NO change here. (#197 extension point.)
#
# Pipes in cells: a pipe meant as literal content (a shell pipeline in evidence,
# table text in a criterion) must be escaped as `\|` — exactly how GitHub renders
# a pipe inside a table cell. The splitter honors `\|` (protects it, restores it
# as a literal `|`), so an escaped pipe never shifts columns. A RAW, unescaped `|`
# still splits the row at the first occurrence (truncating the tail into a
# discarded remainder) — but that can only make a cell SHORTER, never turn an
# empty cell into a non-empty one, so it cannot manufacture a false PASS.
#
# Exit codes:
#   0 = valid (every PASS has evidence; verdicts all legal; >=1 criterion).
#   1 = invariant violation (PASS without evidence / illegal verdict / 0 rows).
#   2 = usage / parse error (no evidence table found, bad header, unreadable file).

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
Usage: validate-evidence-table.sh [--file <path> | --body <str>]

Enforces the evidence-bound review gate (#196): the review comment's EVIDENCE
TABLE must mark a criterion PASS only when it carries concrete evidence. No
clean pass without evidence.

Input (one of):
  (default)        read the review-comment body from stdin
  --file <path>    read the body from a file
  --body  <str>    read the body from a literal string

Other:
  -h, --help       show this help.

Expected table (Markdown), anywhere in the body:
  | # | Criterion | Verdict | Evidence |
  |---|---|---|---|
  | 1 | ... | PASS       | `cmd` -> output / test -> pass line / file:line |
  | 2 | ... | FAIL       | what is wrong |
  | 3 | ... | UNVERIFIED | why it could not be verified |

Verdicts: PASS, FAIL, UNVERIFIED (case-insensitive).
Rule: PASS requires evidence carrying a behavioral-assertion signal — an exit
code, an HTTP status, a test/assert construct, a comparison on observed state, a
file:line or trace: reference, or observed REST/DOM/SDK state. A lone -, n/a,
none, or backticks-only is EMPTY; a screenshot ALONE or a bare claim ("it works")
carries no assertion signal and is rejected like EMPTY. FAIL / UNVERIFIED may
omit evidence.

Exit codes:
  0 = valid          1 = invariant violation (PASS w/o evidence, bad verdict,
                         zero criteria)
  2 = usage / parse error (no table found, bad header, unreadable file)

Spec: docs/specs/2026-05-21-evidence-based-review-gate.md
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
      [[ $# -ge 2 ]] || { echo "validate-evidence-table: --file needs a value" >&2; exit 2; }
      src_file="$2"; shift 2
      ;;
    --file=*)
      src_file="${1#--file=}"; shift
      ;;
    --body)
      [[ $# -ge 2 ]] || { echo "validate-evidence-table: --body needs a value" >&2; exit 2; }
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
      echo "validate-evidence-table: unknown argument: $1" >&2
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
    echo "${C_RED}x${C_RESET} validate-evidence-table: file not readable: $src_file" >&2
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
# is_placeholder_evidence — true (0) if the evidence cell counts as EMPTY:
# blank, or a lone placeholder token (-, --, n/a, none, tbd), or backticks/
# punctuation only. Anything with real content (incl. trace:<id>) is NOT a
# placeholder.
# -----------------------------------------------------------------------------
is_placeholder_evidence() {
  local cell
  cell="$(trim "$1")"
  # Strip surrounding backticks and stray markdown emphasis to look at content.
  local stripped="$cell"
  stripped="${stripped//\`/}"      # drop all backticks
  stripped="$(trim "$stripped")"
  [[ -z "$stripped" ]] && return 0
  # Lone dashes / em-dash.
  case "$stripped" in
    "-"|"--"|"---"|"—"|"–") return 0 ;;
  esac
  # Lone placeholder words (case-insensitive).
  local lower
  lower="$(printf '%s' "$stripped" | tr '[:upper:]' '[:lower:]')"
  case "$lower" in
    "n/a"|"na"|"none"|"tbd"|"todo"|"pending"|"?") return 0 ;;
  esac
  return 1
}

# =============================================================================
# POSITIVE ASSERTION-SIGNAL DETECTION (#191 redesign — amendment 2).
#
# The previous design was a DENYLIST: strip every KNOWN screenshot/filler token
# and reject the cell only if nothing was left. That fails OPEN — any screenshot
# word the denylist did not anticipate survives the strip and is mistaken for an
# assertion. Three review cycles found three leak classes that way.
#
# The INVERSION: a PASS cell is valid ONLY if, after stripping image references,
# it carries at least one POSITIVE behavioral-assertion signal. No signal -> the
# cell is treated as EMPTY (rejected like a blank or placeholder cell), no matter
# what filler/screenshot words are present. This fails CLOSED: an unenumerated
# screenshot word has no assertion signal, so it fails by construction —
# `Screen Shot 2026-06-01 at 3.04.55 PM.png` alone fails with zero special-casing.
# It also makes bare prose ("it works") fail — the desirable #196/#209 side effect.
#
# Spec: docs/specs/2026-05-21-evidence-based-review-gate.md (amendment 2).
# =============================================================================

# -----------------------------------------------------------------------------
# ASSERTION_SIGNALS — the documented allowlist of behavioral-assertion patterns.
# A cell carries an assertion iff it matches ANY of these (case-insensitive; we
# match against a lowercased copy of the cell with image refs already stripped).
#
# Patterns are POSIX ERE (used with `grep -Eiq`). To extend the gate, add one
# line here — that is the single source of truth. Each entry names its category.
#
# Categories (mirrors the spec + the SKILL.md prose):
#   - exit codes:      exit 0 / exit=0 / EXIT=0 / exit code 0 / exit code: 0
#   - HTTP status:     HTTP 2xx-5xx / "200 OK" etc / "-> 200" / "status 204" /
#                      a bare 3-digit 2xx-5xx adjacent to an arrow or "status"
#   - test/assert:     assert / expect( / toBe / toEqual / "N passed" /
#                      "N failed" / PASS|FAIL as a result token
#   - comparisons:     == / === / >= / <= / != / returned / equals
#   - source/trace:    file.ext:NN (file:line) / trace:<id> (+ session/req/resp/sha/commit)
#   - DOM/SDK/REST:    rows / .ok / verify_chain / a JSON object/array literal
# -----------------------------------------------------------------------------
ASSERTION_SIGNALS=(
  # --- exit codes ---
  'exit[ =:]*(code)?[ =:]*-?[0-9]+'        # exit 0 / exit=0 / exit code 0 / exit code: 1
  # --- HTTP status ---
  'http/?[0-9.]* +[1-5][0-9][0-9]'         # HTTP 200 / HTTP/1.1 204
  'http +[1-5][0-9][0-9]'                  # HTTP 200 (explicit)
  '[1-5][0-9][0-9] +(ok|created|accepted|no content|moved|found|bad request|unauthorized|forbidden|not found|conflict|gone|unprocessable|too many|internal|not implemented|bad gateway|service unavailable|gateway timeout)' # 200 OK / 404 Not Found
  '(->|→|=>) *[1-5][0-9][0-9]\b'           # -> 200 / → 204
  '(status|code|returned|got|->|→) *[1-5][0-9][0-9]\b' # status 204 / got 500
  '\bhttp +[1-5][0-9][0-9]\b'
  '\b[1-5][0-9][0-9] +(on|from|for|at) +/' # 204 on /x  (status + path)
  # --- test / assert constructs ---
  '\bassert(s|ed|ion|ions)?\b'             # assert / asserted / assertion
  'expect\('                               # expect(
  '\.to(be|equal|match|contain|throw|havelength|havebeencalled)' # toBe / toEqual / toMatch ...
  '[0-9]+ +(passed|passing|pass\b)'        # 3 passed / 12 passing
  '[0-9]+ +(failed|failing|fail\b)'        # 0 failed
  '\b(all +)?(tests? +)?(passed|passing)\b' # tests passed / all passing
  # --- comparison / operators on observed state ---
  '(==|===|!=|!==|>=|<=)'                  # == / === / != / >= / <=
  '\breturn(s|ed)\b'                       # returned / returns
  '\bequals?\b'                            # equals / equal
  '\b(count|len|length|size|total|rows?) *(==|===|=|:|>=|<=|>|<) *[0-9]' # count == 3 / rows: 5
  # --- source / trace references ---
  '[a-z0-9_./-]+\.[a-z0-9]+:[0-9]+'        # file.ext:NN  (file:line)
  '\b(trace|session|req|request|resp|response|sha|commit):[a-z0-9_./-]' # trace:abc / sha:deadbee
  # --- DOM / SDK / REST observed state ---
  '\b[0-9]+ +rows?\b'                      # 5 rows / 1 row
  '\brows? +(returned|affected|matched)\b' # rows returned
  '(^|[^a-z0-9])\.ok\b'                    # .ok  (res.ok / .ok === true)
  '\bres(ponse)?\.ok\b'                    # res.ok / response.ok
  '\bverify_chain\b'                       # verify_chain (andb)
  '\{[^}]*:[^}]*\}'                        # a JSON-ish object literal {"k":v}
  '\[\s*\{'                                # a JSON array of objects [{...
)

# -----------------------------------------------------------------------------
# cell_has_assertion_signal — true (0) if the evidence cell carries at least one
# behavioral-assertion signal. This is the POSITIVE test that replaced the
# screenshot denylist. A cell with no signal (a screenshot alone, a bare prose
# claim, filler) returns false (1) and is rejected like an empty cell.
#
# We scan the signal patterns against the WHOLE cell (lowercased, backticks
# dropped) — no image-stripping needed. This is deliberate and is what makes the
# `assertion + screenshot` case work AND keeps a `trace:`/`file:line` whose path
# contains an image ext valid:
#
#   - `curl /x -> 200; shot.png`  -> the `-> 200` HTTP signal matches; the
#                                    adjacent `shot.png` matches NO signal, so it
#                                    neither helps nor hurts. PASS.
#   - `trace:shot.png`            -> matches the trace: signal directly (the image
#                                    ext in the path is irrelevant to the scan).
#                                    PASS — no special pre-stripping required.
#   - `Screen Shot ... PM.png`    -> a screenshot filename matches NO assertion
#                                    signal (its digits are a date/time, not an
#                                    HTTP/exit/comparison context). FAIL.
#
# So a screenshot filename can never manufacture a false signal: it only fails to
# add one. Image references are inert to this scan by construction — which is why
# the whole screenshot denylist (and its leak classes) is gone.
# -----------------------------------------------------------------------------
cell_has_assertion_signal() {
  local cell lower pat
  cell="$(trim "$1")"
  cell="${cell//\`/}"                       # drop backticks for content inspection
  lower="$(printf '%s' "$cell" | tr '[:upper:]' '[:lower:]')"
  [[ -z "$(trim "$lower")" ]] && return 1   # empty -> no signal
  for pat in "${ASSERTION_SIGNALS[@]}"; do
    if printf '%s' "$lower" | grep -Eiq -- "$pat"; then
      return 0
    fi
  done
  return 1
}

# -----------------------------------------------------------------------------
# locate the evidence table.
#   1. Find the header row whose 4 columns are #, Criterion, Verdict, Evidence.
#   2. The next line must be a separator (|---|---|...).
#   3. Subsequent | ... | lines are data rows, until a blank line or a
#      non-table line.
# Markdown table rows are pipe-delimited; cells are the fields between pipes.
# -----------------------------------------------------------------------------

# Normalize a table row into US-delimited cells (skip the leading/trailing
# empties produced by the bordering pipes). US (\x1f) is not table content and
# survives empty middle cells (unlike collapsing on whitespace).
#
# Escaped pipes (`\|`) inside a cell are LITERAL content (that's how GitHub
# renders a pipe in a table cell), NOT column separators. We protect them with a
# placeholder (RS, \x1e) before splitting on `|`, then restore them as a literal
# `|` in each cell. Without this, a criterion or evidence cell containing a shell
# pipeline (`grep x \| wc -l`) would shift every later column and the validator
# would reject a correctly-rendered table.
split_row() {
  # echoes cell0 \x1f cell1 \x1f ... for the row passed as $1
  local row="$1"
  # Protect escaped pipes: `\|` -> RS placeholder so the split skips them.
  row="${row//\\|/$'\x1e'}"
  # strip one leading and one trailing pipe (with surrounding spaces) if present
  row="$(trim "$row")"
  row="${row#|}"
  row="${row%|}"
  local IFS='|'
  local -a cells=()
  read -r -a cells <<< "$row" || true
  # `read -a` with IFS='|' splits but trims nothing; emit US-joined trimmed cells.
  # Restore each protected pipe as a literal `|` (GitHub-rendered form).
  local out="" first=1 c
  for c in "${cells[@]}"; do
    c="${c//$'\x1e'/|}"
    if [[ "$first" -eq 1 ]]; then first=0; else out+=$'\x1f'; fi
    out+="$(trim "$c")"
  done
  printf '%s' "$out"
}

# Find header line number (1-based) of the evidence table.
header_line=0
sep_line=0
lineno=0

# Read all lines into an array (preserve empties). bash 3.2 (macOS default) has
# no `mapfile`/`readarray`, so use a portable read loop. The `[[ -n $line ... ]]`
# guard captures a final line that lacks a trailing newline.
LINES=()
while IFS= read -r line || [[ -n "$line" ]]; do
  LINES+=("$line")
done <<< "$body"

is_header_row() {
  # $1 is a raw line; returns 0 if it's the evidence-table header.
  local line="$1"
  [[ "$line" == *"|"* ]] || return 1
  local cells c0 c1 c2 c3
  cells="$(split_row "$line")"
  IFS=$'\x1f' read -r c0 c1 c2 c3 _rest <<< "$cells"
  # lowercase compare
  local l0 l1 l2 l3
  l0="$(printf '%s' "$c0" | tr '[:upper:]' '[:lower:]')"
  l1="$(printf '%s' "$c1" | tr '[:upper:]' '[:lower:]')"
  l2="$(printf '%s' "$c2" | tr '[:upper:]' '[:lower:]')"
  l3="$(printf '%s' "$c3" | tr '[:upper:]' '[:lower:]')"
  [[ "$l0" == "#" && "$l1" == "criterion" && "$l2" == "verdict" && "$l3" == "evidence" ]]
}

is_separator_row() {
  # | --- | --- | --- | --- |  (cells are only dashes/colons/spaces)
  local line="$1"
  [[ "$line" == *"|"* && "$line" == *"-"* ]] || return 1
  local stripped="${line//[|: -]/}"
  [[ -z "$stripped" ]]
}

for i in "${!LINES[@]}"; do
  lineno=$((i + 1))
  line="${LINES[$i]}"
  if [[ "$header_line" -eq 0 ]]; then
    if is_header_row "$line"; then
      header_line="$lineno"
    fi
    continue
  fi
  # We have a header; the immediately next line must be the separator.
  if [[ "$sep_line" -eq 0 ]]; then
    if is_separator_row "$line"; then
      sep_line="$lineno"
      break
    else
      # Header not followed by a separator -> not a real table; keep looking.
      header_line=0
      # Re-test this line as a potential new header.
      if is_header_row "$line"; then
        header_line="$lineno"
      fi
      continue
    fi
  fi
done

if [[ "$header_line" -eq 0 || "$sep_line" -eq 0 ]]; then
  echo "${C_RED}x${C_RESET} validate-evidence-table: no evidence table found." >&2
  echo "${C_DIM}  Expected a header row: | # | Criterion | Verdict | Evidence |${C_RESET}" >&2
  echo "${C_DIM}  followed by a |---|---|---|---| separator. See spec docs/specs/2026-05-21-evidence-based-review-gate.md${C_RESET}" >&2
  exit 2
fi

# -----------------------------------------------------------------------------
# walk data rows (after the separator) and apply the invariant.
# -----------------------------------------------------------------------------
violations=0
row_count=0
data_start=$((sep_line + 1))

for ((ln = data_start; ln <= ${#LINES[@]}; ln++)); do
  idx=$((ln - 1))
  line="${LINES[$idx]}"
  trimmed="$(trim "$line")"
  # Stop at a blank line or a non-pipe line — the table has ended.
  [[ -z "$trimmed" ]] && break
  [[ "$trimmed" == *"|"* ]] || break

  cells="$(split_row "$line")"
  IFS=$'\x1f' read -r num crit verdict evidence _rest <<< "$cells"
  row_count=$((row_count + 1))

  norm_verdict="$(printf '%s' "$(trim "$verdict")" | tr '[:lower:]' '[:upper:]')"

  case "$norm_verdict" in
    PASS)
      if is_placeholder_evidence "$evidence"; then
        echo "${C_RED}x${C_RESET} validate-evidence-table: row $row_count (criterion $(trim "$num")) is PASS with NO evidence." >&2
        echo "${C_DIM}    criterion: $(trim "$crit")${C_RESET}" >&2
        echo "${C_DIM}    -> a clean PASS requires concrete evidence; mark it UNVERIFIED if you could not verify it.${C_RESET}" >&2
        violations=$((violations + 1))
      elif ! cell_has_assertion_signal "$evidence"; then
        # #191 redesign (amendment 2): a PASS requires a POSITIVE behavioral-
        # assertion signal. A screenshot alone, or a bare prose claim, carries
        # none and is rejected exactly like an empty cell — failing CLOSED so no
        # unenumerated screenshot word (or claim) can pose as an assertion.
        echo "${C_RED}x${C_RESET} validate-evidence-table: row $row_count (criterion $(trim "$num")) is PASS with NO BEHAVIORAL ASSERTION — a screenshot or a bare claim is not an assertion." >&2
        echo "${C_DIM}    criterion: $(trim "$crit")${C_RESET}" >&2
        echo "${C_DIM}    -> cite a behavioral assertion signal: exit code (exit 0) / HTTP status (HTTP 204) / test+assert (3 passed, expect(x).toBe) / comparison (count == 3) / file:line (src/x.ts:42) / trace:<id> / observed REST/DOM/SDK state (rows, .ok, JSON body). A screenshot or 'it works' corroborates but cannot be the sole PASS evidence. See docs/specs/2026-05-21-evidence-based-review-gate.md (#191).${C_RESET}" >&2
        violations=$((violations + 1))
      fi
      ;;
    FAIL|UNVERIFIED)
      : # evidence optional for these verdicts
      ;;
    *)
      echo "${C_RED}x${C_RESET} validate-evidence-table: row $row_count (criterion $(trim "$num")) has illegal verdict '$(trim "$verdict")'." >&2
      echo "${C_DIM}    -> verdict must be one of PASS / FAIL / UNVERIFIED.${C_RESET}" >&2
      violations=$((violations + 1))
      ;;
  esac
done

# -----------------------------------------------------------------------------
# zero-criteria check (approval gate produced nothing)
# -----------------------------------------------------------------------------
if [[ "$row_count" -eq 0 ]]; then
  echo "${C_RED}x${C_RESET} validate-evidence-table: the evidence table has zero criterion rows." >&2
  echo "${C_DIM}  -> extract the ticket's acceptance criteria (approval gate) before reviewing.${C_RESET}" >&2
  exit 1
fi

# -----------------------------------------------------------------------------
# verdict
# -----------------------------------------------------------------------------
if [[ "$violations" -gt 0 ]]; then
  echo "${C_RED}${C_BOLD}validate-evidence-table: FAIL${C_RESET} ($violations violation(s) across $row_count criteria)" >&2
  exit 1
fi

echo "${C_GREEN}OK${C_RESET} validate-evidence-table: $row_count criteria, every PASS carries evidence."
exit 0

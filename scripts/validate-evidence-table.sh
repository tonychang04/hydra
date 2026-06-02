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
#   - FAIL / UNVERIFIED may have empty evidence (a FAIL says what's wrong;
#     UNVERIFIED says why it couldn't be checked).
#   - At least one criterion (data) row must exist.
#   - The #197 session trace will add a `trace:<id>` evidence kind later; any
#     non-empty cell counts as evidence regardless of kind, so trace: works
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
Rule: PASS requires non-empty evidence (a lone -, n/a, none, or backticks-only
is treated as EMPTY). FAIL / UNVERIFIED may omit evidence.

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

# -----------------------------------------------------------------------------
# IMAGE_EXT_GLOB — the ONE shared image-extension set, used by BOTH the fast-path
# hint and the per-token image-reference test below. Keeping a single source of
# truth is the whole point of the #191 re-work FINAL fix: the previous code had a
# `*.png*` SUBSTRING rule (too broad -> false-rejected real `app.png.ts:42`
# assertions) layered over a 5-extension allow-list `png|jpg|jpeg|gif|webp` (too
# narrow -> false-accepted `capture.bmp` screenshots). Both halves were wrong in
# opposite directions. This set is the broad, correct one; the matching is now
# "token ENDS in one of these" (see token_is_image_ref), never substring.
IMAGE_EXT_GLOB='png|jpg|jpeg|gif|webp|bmp|svg|heic|tif|tiff|avif'

# -----------------------------------------------------------------------------
# token_is_image_ref — true (0) if a SINGLE whitespace-delimited token is an
# image reference, i.e. it ENDS in a known image extension after stripping a
# trailing query string (`?...`) / fragment (`#...`) and trailing punctuation.
# Case-insensitive. This is the principled rule that fixes both blockers:
#
#   `app.png.ts`      -> ends in `ts`  -> NOT an image (real source ref, kept)
#   `shot.png`        -> ends in `png` -> image (dropped)
#   `x.png?raw=1`     -> strip `?raw=1` -> ends in `png` -> image (dropped)
#   `https://h/x.jpeg`-> ends in `jpeg` -> image (dropped)
#   `a.png,`          -> strip trailing `,` -> ends in `png` -> image (dropped)
#   `diagram.SVG.`    -> strip trailing `.` -> ends in `svg` -> image (dropped)
#
# Pure bash + `tr` — no GNU-only sed escapes; BSD/macOS-portable.
# -----------------------------------------------------------------------------
token_is_image_ref() {
  local t="$1"
  # Strip a trailing query string / fragment: everything from the first ? or #.
  t="${t%%[?#]*}"
  # Lowercase for case-insensitive extension match.
  t="$(printf '%s' "$t" | tr '[:upper:]' '[:lower:]')"
  # Strip trailing punctuation (commas, periods, parens, quotes, etc.) so a glued
  # `a.png,` or `diagram.svg.` still ends in its extension. Loop until stable.
  local prev=""
  while [[ "$t" != "$prev" ]]; do
    prev="$t"
    case "$t" in
      *[\).,\;\:\!\?\"\'\]\}\>\*\`]) t="${t%?}" ;;
    esac
  done
  # The extension is the substring after the LAST dot; no dot -> not an image.
  case "$t" in
    *.*) : ;;
    *) return 1 ;;
  esac
  local ext="${t##*.}"
  # Compare ext against the shared set (anchored: the WHOLE ext must match).
  case "|$IMAGE_EXT_GLOB|" in
    *"|$ext|"*) return 0 ;;
    *) return 1 ;;
  esac
}

# -----------------------------------------------------------------------------
# is_screenshot_only_evidence — true (0) if the evidence cell is NOTHING BUT a
# screenshot reference: a picture with no asserted state. (#191 amendment,
# docs/specs/2026-05-21-evidence-based-review-gate.md.)
#
# The #191 policy is "behavioral assertion + ONE screenshot": the behavioral
# assertion (exit code / DOM / SDK / REST body / HTTP status / command output /
# file:line / trace:<id>) is the load-bearing evidence; a screenshot only
# corroborates. A screenshot proves a render happened, not that the state is
# correct — so a PASS backed by a screenshot ALONE is rejected exactly like an
# empty cell. Any real assertion anywhere in the cell keeps the PASS valid.
#
# Method (token-based, robust to surrounding whitespace/punctuation/URLs):
#   1. Preserve markdown alt-text: `![alt](url)` -> keep `alt`, drop the link.
#      An assertion can live ONLY in alt-text (`![HTTP 200](x.png)`); stripping
#      it wholesale was a false-reject bug (#191 re-work BLOCKER 2).
#   2. Tokenize on whitespace. For each token, DROP it if it is an image
#      reference per token_is_image_ref (token ENDS in a known image extension
#      after stripping query/fragment + trailing punct — the principled rule that
#      replaced the broken `*.png*` SUBSTRING test, #191 re-work FINAL), or a
#      screenshot keyword, or a date/time fragment, or pure connective filler.
#      A token like `app.png.ts:42` does NOT end in an image ext, so it survives
#      as a real assertion (BLOCKER B fix); `capture.bmp` DOES, so it is dropped
#      (BLOCKER A fix). Tokenizing first means a space/quote/paren/comma/`*`/`@`/
#      `?` adjacent to the filename can no longer strand a bare token.
#   3. If anything substantive remains -> NOT screenshot-only (an assertion is
#      present). If nothing remains -> screenshot-only.
#
# Portability: pure bash + `tr` (no GNU-only `sed` `\b`/`\s`/`\d`; BSD/macOS sed
# lacks them). CI runs Linux; the dev host is macOS — this works on both.
# -----------------------------------------------------------------------------
is_screenshot_only_evidence() {
  local cell lower residue
  cell="$(trim "$1")"
  cell="${cell//\`/}"              # drop backticks for content inspection
  lower="$(printf '%s' "$cell" | tr '[:upper:]' '[:lower:]')"
  # Fast path: a cell with no screenshot/image hint at all is never
  # screenshot-only — leave it to the assertion checks. The image-extension hint
  # here is a SUBSTRING (cheap over-trigger): it only decides whether to run the
  # precise per-token analysis below, which is authoritative. So a `.png`
  # anywhere (even mid-path in `app.png.ts`) routes into the token loop, where
  # token_is_image_ref then correctly KEEPS the real assertion. Built from the
  # shared IMAGE_EXT_GLOB so the fast-path and the token-drop can never drift.
  local ext_hint=0 e
  local _ifs="$IFS"; IFS='|'
  for e in $IMAGE_EXT_GLOB; do
    if [[ "$lower" == *".$e"* ]]; then ext_hint=1; break; fi
  done
  IFS="$_ifs"
  case "$lower" in
    *screenshot*|*screencap*|*screen-grab*|*screen\ grab*|*"!["*) ext_hint=1 ;;
  esac
  [[ "$ext_hint" -eq 1 ]] || return 1

  # Step 1: replace each markdown image `![alt](url)` with ` alt ` — preserve the
  # alt-text (it may be the assertion), drop the link target. Loop handles
  # multiple images. Non-greedy by construction: %%/## cut at the FIRST/LAST
  # delimiter, so we slice exactly one `![ ... ]( ... )` per iteration.
  residue="$lower"
  while [[ "$residue" == *"!["*"]("*")"* ]]; do
    local before rest alt after
    before="${residue%%"!["*}"        # text before the image
    rest="${residue#*"!["}"           # everything after the leading ![
    alt="${rest%%"]("*}"              # alt-text: between ![ and ](
    after="${rest#*")"}"             # everything after the closing )
    residue="$before $alt $after"
  done

  # Step 2: tokenize on whitespace, classify each token.
  local tok bare out=""
  for tok in $residue; do
    # `bare`: token with all surrounding/embedded punctuation removed, used to
    # decide if what remains is a real word. Keep `tok` to test for an image ext.
    bare="$(printf '%s' "$tok" | tr -d '[:punct:]')"
    [[ -z "$bare" ]] && continue       # pure punctuation -> nothing
    # KEEP assertion-marker tokens BEFORE the image-ref drop. The spec enumerates
    # `file:line` and `trace:<id>` as first-class evidence kinds. Such a token can
    # legitimately carry an image extension in its PATH (`trace:shot.png`,
    # `src/app.png.ts:42`) yet still be a behavioral/source reference, not a
    # screenshot. We recognize two marker shapes (case-insensitive, on `lower`):
    #   - a `<scheme>:` prefix from the assertion vocab (trace:/session:/req:/...)
    #   - a `:<digits>` file:line suffix (`foo.ts:42`)
    # This guard is why BLOCKER B passes: these are PRESERVED as assertions.
    case "$tok" in
      trace:*|session:*|req:*|request:*|resp:*|response:*|sha:*|commit:*) out+="x"; continue ;;
    esac
    case "$tok" in
      *:[0-9]) out+="x"; continue ;;       # file:line (single digit)
      *:[0-9]*[0-9]) out+="x"; continue ;; # file:line (multi-digit)
    esac
    # Drop image references via the principled per-token test: a token that ENDS
    # in a known image ext (after stripping query/fragment + trailing punct) is a
    # screenshot ref and is removed whole. `foo@2x.png`, `*.png`, `x.png?raw=1`,
    # `https://h/x.png`, `capture.bmp`, `diagram.svg`, `a.png,` all match here. A
    # token like `app.png.ts:42` ends in `ts` (not an image), so it is KEPT as a
    # real assertion — fixing both #191 re-work FINAL blockers in one rule.
    if token_is_image_ref "$tok"; then continue; fi
    # For a PATH-shaped token (no image ext, no assertion marker — e.g. the
    # directory part `~/Desktop/Screen` that precedes a glued `Shot.png`), judge
    # it by its final path segment, the meaningful leaf. `~/Desktop/Screen` ->
    # `screen`, which the filler table below recognizes as a screenshot-path word.
    # This cannot swallow a real assertion: `src/app.png.ts:42` is kept earlier by
    # the file:line marker guard, never reaching here.
    case "$tok" in
      */*) bare="$(printf '%s' "${tok##*/}" | tr -d '[:punct:]')"
           [[ -z "$bare" ]] && continue ;;
    esac
    # Drop screenshot keywords.
    case "$bare" in
      screenshot|screenshots|screencap|screencaps|screengrab|screengrabs) continue ;;
    esac
    # Drop a date / time / clock / RESOLUTION fragment. The macOS default
    # screenshot name embeds a date + time (`Screenshot 2026-06-01 at 1.23.45
    # PM.png`); `2026-06-01` and `1.23.45` collapse to all-digit `bare`. A
    # resolution string (`1920x1080`) collapses to digits plus a lone `x`/`X`
    # separator. None is a behavioral assertion — a real assertion always pairs
    # its number with an anchor WORD or symbol (`HTTP 200`, `exit 0`, `count = 3`),
    # and those anchors survive as their own tokens, so dropping these numeric
    # fragments cannot erase an assertion.
    case "$bare" in
      *[!0-9]*) : ;;                  # has a non-digit -> keep evaluating
      *) continue ;;                  # all digits -> date/time fragment, drop
    esac
    # Resolution: digits separated by a single x/X (e.g. 1920x1080, 800X600).
    case "$bare" in
      [0-9]*[xX][0-9]*)
        case "${bare//[0-9]/}" in
          x|X) continue ;;            # only an x/X between the digit runs -> drop
        esac ;;
    esac
    # Drop pure connective filler — articles, prepositions, screenshot verbs, and
    # the descriptive UI nouns that label a screenshot ("dashboard", "login")
    # without asserting any state. Alt-text labels of this kind must NOT keep a
    # screenshot-only PASS alive.
    case "$bare" in
      see|of|the|a|an|and|in|at|to|on|for|with|attached|below|above|here|this|\
      that|representative|one|single|page|pages|result|results|view|views|is|\
      its|shows|showing|show|rendered|render|renders|displayed|displays|display|\
      captured|capture|pm|am|grab|\
      dashboard|login|logout|signup|signin|home|homepage|screen|panel|modal|\
      dialog|form|list|table|chart|graph|map|menu|nav|navbar|sidebar|header|\
      footer|button|tab|tabs|card|cards|item|items|ui|app) continue ;;
    esac
    out+="$bare"
  done
  [[ -z "$out" ]]
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
      elif is_screenshot_only_evidence "$evidence"; then
        # #191: a screenshot corroborates a behavioral assertion; it is not one.
        echo "${C_RED}x${C_RESET} validate-evidence-table: row $row_count (criterion $(trim "$num")) is PASS with a SCREENSHOT ONLY — that is not a behavioral assertion." >&2
        echo "${C_DIM}    criterion: $(trim "$crit")${C_RESET}" >&2
        echo "${C_DIM}    -> add a behavioral assertion (exit code / DOM / SDK / REST body / HTTP status / command output / file:line); a screenshot corroborates but cannot be the sole PASS evidence. See docs/specs/2026-05-21-evidence-based-review-gate.md (#191).${C_RESET}" >&2
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

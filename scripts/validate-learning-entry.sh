#!/usr/bin/env bash
#
# validate-learning-entry.sh — schema-check a learnings-<repo>.md file.
#
# Required schema (see memory/MEMORY.md, memory/memory-lifecycle.md):
#   - Frontmatter --- block at the top with keys: name, description, type
#   - At least one of the expected section headings:
#       ## Conventions, ## Test commands, ## Known gotchas
#   - No line longer than 500 chars
#   - Any inline dates of the form YYYY-MM-DD are valid (month 01-12, day 01-31)
#
# Exit 0 on pass. On fail, exit 1 and print all errors to stderr so an
# operator / commander can see every problem in one shot, not just the first.

set -euo pipefail

MEMORY_DIR_DEFAULT="./memory"
MAX_LINE_LEN=500
EXPECTED_SECTIONS_REGEX='^## (Conventions|Test commands|Known gotchas)[[:space:]]*$'
REQUIRED_FRONTMATTER_KEYS=(name description type)

usage() {
  cat <<'EOF'
Usage: validate-learning-entry.sh [--memory-dir <path>] <learnings-file.md>

Validates a learnings-<repo>.md file against the commander memory schema.

Options:
  --memory-dir <path>   Override memory directory (default: $HYDRA_EXTERNAL_MEMORY_DIR,
                        falls back to ./memory). If the file path is relative,
                        it is resolved against --memory-dir.
  -h, --help            Show this help.

Checks:
  1. File exists and is readable.
  2. Starts with a frontmatter --- block.
  3. Frontmatter contains keys: name, description, type.
  4. At least one section heading from:
       ## Conventions, ## Test commands, ## Known gotchas.
  5. No line exceeds 500 characters.
  6. Any YYYY-MM-DD date is valid (month 01-12, day 01-31).

Exit codes:
  0   valid
  1   one or more validation errors (all printed to stderr)
  2   usage error / file not found
EOF
}

memory_dir=""
target=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --memory-dir)
      [[ $# -ge 2 ]] || { echo "validate-learning-entry: --memory-dir needs a value" >&2; usage >&2; exit 2; }
      memory_dir="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --)
      shift
      break
      ;;
    -*)
      echo "validate-learning-entry: unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
    *)
      if [[ -n "$target" ]]; then
        echo "validate-learning-entry: only one file argument allowed" >&2
        exit 2
      fi
      target="$1"
      shift
      ;;
  esac
done

if [[ -z "$target" ]]; then
  echo "validate-learning-entry: missing <learnings-file.md>" >&2
  usage >&2
  exit 2
fi

if [[ -z "$memory_dir" ]]; then
  memory_dir="${HYDRA_EXTERNAL_MEMORY_DIR:-$MEMORY_DIR_DEFAULT}"
fi

# Resolve relative paths against --memory-dir.
if [[ "$target" != /* ]] && [[ ! -f "$target" ]]; then
  candidate="$memory_dir/$target"
  if [[ -f "$candidate" ]]; then
    target="$candidate"
  fi
fi

if [[ ! -f "$target" ]]; then
  echo "validate-learning-entry: file not found: $target" >&2
  exit 2
fi
if [[ ! -r "$target" ]]; then
  echo "validate-learning-entry: file not readable: $target" >&2
  exit 2
fi

errors=()

# -- Check 1: frontmatter block --
# Must have --- on line 1 and a closing --- somewhere before EOF.
first_line="$(sed -n '1p' "$target")"
if [[ "$first_line" != "---" ]]; then
  errors+=("missing frontmatter: first line is not '---'")
  frontmatter_ok=0
else
  # Find the line number of the closing '---' (starting from line 2).
  close_lineno="$(awk 'NR>1 && /^---[[:space:]]*$/ {print NR; exit}' "$target")"
  if [[ -z "$close_lineno" ]]; then
    errors+=("missing frontmatter: no closing '---' found")
    frontmatter_ok=0
  else
    frontmatter_ok=1
    frontmatter_body="$(sed -n "2,$((close_lineno-1))p" "$target")"
    for key in "${REQUIRED_FRONTMATTER_KEYS[@]}"; do
      if ! printf '%s\n' "$frontmatter_body" | grep -Eq "^${key}:[[:space:]]*.+"; then
        errors+=("frontmatter missing required key: '${key}'")
      fi
    done
  fi
fi

# -- Check 2: at least one expected section heading --
if ! grep -Eq "$EXPECTED_SECTIONS_REGEX" "$target"; then
  errors+=("no expected section heading found (need at least one of: ## Conventions, ## Test commands, ## Known gotchas)")
fi

# -- Check 3: line length --
# awk prints NR for any line longer than MAX_LINE_LEN.
long_lines="$(awk -v max="$MAX_LINE_LEN" 'length($0) > max {print NR}' "$target")"
if [[ -n "$long_lines" ]]; then
  while IFS= read -r lno; do
    errors+=("line $lno exceeds $MAX_LINE_LEN characters")
  done <<<"$long_lines"
fi

# -- Check 4: any YYYY-MM-DD dates are valid --
# Extract candidate dates (context-free; may catch version-like strings,
# but those are usually not 4-2-2 digits so false positives are rare).
while IFS=$'\t' read -r lno date_str; do
  [[ -z "$date_str" ]] && continue
  y="${date_str:0:4}"
  m="${date_str:5:2}"
  d="${date_str:8:2}"
  # strip leading zeros for arithmetic comparison
  m_num=$((10#$m))
  d_num=$((10#$d))
  if (( m_num < 1 || m_num > 12 )); then
    errors+=("line $lno: invalid month in date '$date_str'")
  fi
  if (( d_num < 1 || d_num > 31 )); then
    errors+=("line $lno: invalid day in date '$date_str'")
  fi
  # Reject years clearly outside a plausible range.
  if (( 10#$y < 2000 || 10#$y > 2100 )); then
    errors+=("line $lno: implausible year in date '$date_str'")
  fi
done < <(grep -En -o '[0-9]{4}-[0-9]{2}-[0-9]{2}' "$target" \
         | awk -F: '{printf "%s\t%s\n", $1, $2}')

if [[ ${#errors[@]} -eq 0 ]]; then
  # --- S3 sync hook -------------------------------------------------------
  # Entry validated OK → a write is either imminent or just happened. If
  # HYDRA_MEMORY_BACKEND=s3 or s3-strict, push the memory dir to S3.
  # Spec: docs/specs/2026-04-17-dual-mode-memory.md
  if [[ "${HYDRA_MEMORY_BACKEND:-local}" =~ ^s3(-strict)?$ ]]; then
    sync_script="$(dirname "${BASH_SOURCE[0]}")/hydra-memory-sync.sh"
    if [[ -x "$sync_script" ]]; then
      if ! "$sync_script" --push --memory-dir "$memory_dir" >&2; then
        if [[ "${HYDRA_MEMORY_BACKEND}" == "s3-strict" ]]; then
          echo "validate-learning-entry: S3 push failed and backend=s3-strict; exiting" >&2
          exit 1
        fi
        echo "validate-learning-entry: warning — S3 push failed, continuing (backend=s3)" >&2
      fi
    fi
  fi
  exit 0
fi

echo "validate-learning-entry: FAIL ($target)" >&2
for e in "${errors[@]}"; do
  echo "  - $e" >&2
done
exit 1

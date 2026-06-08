#!/usr/bin/env bash
#
# test-validate-learning-entry.sh — regression test for
# scripts/validate-learning-entry.sh.
#
# Pins the validator's contract (see its header + memory/memory-lifecycle.md):
#   - frontmatter --- block with keys: name, description, type
#   - at least one of: ## Conventions, ## Test commands, ## Known gotchas
#   - no line longer than 1500 chars
#   - any inline YYYY-MM-DD date is valid (month 01-12, day 01-31)
#   - on failure, exit 1 and print ALL errors (not just the first)
#   - usage / file-not-found → exit 2
#
# Style: matches scripts/test-promote-citations.sh — plain bash, colored
# output, pass/fail counter, mktemp fixtures, no external test harness.
#
# Spec: docs/specs/2026-06-08-test-validate-learning-entry.md (ticket #299)

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
VALIDATE="$SCRIPT_DIR/validate-learning-entry.sh"

if [[ ! -x "$VALIDATE" ]]; then
  echo "test-validate-learning-entry: $VALIDATE not found or not executable" >&2
  exit 2
fi

if [[ -t 1 ]] && [[ "${NO_COLOR:-}" != "1" ]]; then
  C_GREEN=$'\033[32m'
  C_RED=$'\033[31m'
  C_BOLD=$'\033[1m'
  C_RESET=$'\033[0m'
else
  C_GREEN=""
  C_RED=""
  C_BOLD=""
  C_RESET=""
fi

passed=0
failed=0
tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

say()  { printf "\n${C_BOLD}▸ %s${C_RESET}\n" "$*"; }
ok()   { printf "  ${C_GREEN}✓${C_RESET} %s\n" "$*"; passed=$((passed + 1)); }
bad()  { printf "  ${C_RED}✗${C_RESET} %s\n" "$*"; failed=$((failed + 1)); }

# --- Runner ----------------------------------------------------------------
# run_validate <file> <stdout_capture> <stderr_capture> [extra args...]
# Echoes the exit code; never aborts the test on a non-zero exit.
run_validate() {
  local file="$1" out="$2" err="$3"
  shift 3
  set +e
  NO_COLOR=1 "$VALIDATE" "$@" "$file" > "$out" 2> "$err"
  local ec=$?
  set -e
  echo "$ec"
}

# A reusable valid entry body (frontmatter + one expected section + a date).
write_valid() {
  cat > "$1" <<'EOF'
---
name: hydra learnings
description: a valid fixture for the regression test
type: repo-learnings
---

## Known gotchas

- On 2026-06-08 we learned that the validator reports every error in one
  shot. Lines here stay well under the 1500-char sanity bound.
EOF
}

# --- Test 1: a fully valid entry → exit 0 ---------------------------------
say "Test 1: valid entry → exit 0"
f="$tmpdir/valid.md"; write_valid "$f"
ec=$(run_validate "$f" "$tmpdir/1.out" "$tmpdir/1.err")
if [[ "$ec" -eq 0 ]]; then
  ok "exit 0 on a schema-valid entry"
else
  bad "expected exit 0, got $ec; stderr:"; sed 's/^/    /' "$tmpdir/1.err"
fi

# --- Test 2: first line not '---' → exit 1, missing frontmatter -----------
say "Test 2: no leading '---' → exit 1 (missing frontmatter)"
f="$tmpdir/nofm.md"
cat > "$f" <<'EOF'
not frontmatter

## Known gotchas

- body
EOF
ec=$(run_validate "$f" "$tmpdir/2.out" "$tmpdir/2.err")
if [[ "$ec" -eq 1 ]]; then ok "exit 1"; else bad "expected exit 1, got $ec"; fi
if grep -q "missing frontmatter" "$tmpdir/2.err"; then
  ok "stderr names the missing-frontmatter check"
else
  bad "expected 'missing frontmatter' in stderr:"; sed 's/^/    /' "$tmpdir/2.err"
fi

# --- Test 3: frontmatter opens but never closes → exit 1 ------------------
say "Test 3: unclosed frontmatter → exit 1 (no closing ---)"
f="$tmpdir/unclosed.md"
cat > "$f" <<'EOF'
---
name: x
description: y
type: z

## Known gotchas

- body, but the frontmatter block was never closed.
EOF
ec=$(run_validate "$f" "$tmpdir/3.out" "$tmpdir/3.err")
if [[ "$ec" -eq 1 ]]; then ok "exit 1"; else bad "expected exit 1, got $ec"; fi
if grep -q "no closing" "$tmpdir/3.err"; then
  ok "stderr names the no-closing-delimiter check"
else
  bad "expected 'no closing' in stderr:"; sed 's/^/    /' "$tmpdir/3.err"
fi

# --- Tests 4-6: each missing required frontmatter key → exit 1 ------------
for key in name description type; do
  say "Test (missing key): '$key' absent → exit 1"
  f="$tmpdir/nokey-$key.md"
  {
    echo "---"
    [[ "$key" != "name" ]]        && echo "name: present-name"
    [[ "$key" != "description" ]] && echo "description: present-desc"
    [[ "$key" != "type" ]]        && echo "type: present-type"
    echo "---"
    echo ""
    echo "## Known gotchas"
    echo ""
    echo "- body"
  } > "$f"
  ec=$(run_validate "$f" "$tmpdir/k-$key.out" "$tmpdir/k-$key.err")
  if [[ "$ec" -eq 1 ]]; then ok "exit 1 when '$key' missing"; else bad "expected exit 1, got $ec"; fi
  if grep -q "missing required key: '$key'" "$tmpdir/k-$key.err"; then
    ok "stderr names the missing key '$key'"
  else
    bad "expected \"missing required key: '$key'\" in stderr:"; sed 's/^/    /' "$tmpdir/k-$key.err"
  fi
done

# --- Test 7: no expected section heading → exit 1 -------------------------
say "Test 7: no expected section heading → exit 1"
f="$tmpdir/nosection.md"
cat > "$f" <<'EOF'
---
name: x
description: y
type: z
---

## Some Other Heading

- body with valid frontmatter but no Conventions/Test commands/Known gotchas.
EOF
ec=$(run_validate "$f" "$tmpdir/7.out" "$tmpdir/7.err")
if [[ "$ec" -eq 1 ]]; then ok "exit 1"; else bad "expected exit 1, got $ec"; fi
if grep -q "no expected section heading" "$tmpdir/7.err"; then
  ok "stderr names the missing-section check"
else
  bad "expected 'no expected section heading' in stderr:"; sed 's/^/    /' "$tmpdir/7.err"
fi

# --- Test 8: a line > 1500 chars → exit 1 --------------------------------
say "Test 8: an over-long line → exit 1 (exceeds 1500 chars)"
f="$tmpdir/longline.md"
{
  echo "---"
  echo "name: x"; echo "description: y"; echo "type: z"
  echo "---"
  echo ""
  echo "## Known gotchas"
  echo ""
  printf -- '- '; printf 'a%.0s' $(seq 1 1600); echo ""
} > "$f"
ec=$(run_validate "$f" "$tmpdir/8.out" "$tmpdir/8.err")
if [[ "$ec" -eq 1 ]]; then ok "exit 1"; else bad "expected exit 1, got $ec"; fi
if grep -q "exceeds 1500 characters" "$tmpdir/8.err"; then
  ok "stderr names the line-length check"
else
  bad "expected 'exceeds 1500 characters' in stderr:"; sed 's/^/    /' "$tmpdir/8.err"
fi

# --- Test 9: invalid month → exit 1 --------------------------------------
say "Test 9: invalid month (2026-13-01) → exit 1"
f="$tmpdir/badmonth.md"
cat > "$f" <<'EOF'
---
name: x
description: y
type: z
---

## Known gotchas

- recorded on 2026-13-01 which is not a real month.
EOF
ec=$(run_validate "$f" "$tmpdir/9.out" "$tmpdir/9.err")
if [[ "$ec" -eq 1 ]]; then ok "exit 1"; else bad "expected exit 1, got $ec"; fi
if grep -q "invalid month" "$tmpdir/9.err"; then
  ok "stderr names the invalid-month check"
else
  bad "expected 'invalid month' in stderr:"; sed 's/^/    /' "$tmpdir/9.err"
fi

# --- Test 10: invalid day → exit 1 ---------------------------------------
say "Test 10: invalid day (2026-06-32) → exit 1"
f="$tmpdir/badday.md"
cat > "$f" <<'EOF'
---
name: x
description: y
type: z
---

## Known gotchas

- recorded on 2026-06-32 which is not a real day.
EOF
ec=$(run_validate "$f" "$tmpdir/10.out" "$tmpdir/10.err")
if [[ "$ec" -eq 1 ]]; then ok "exit 1"; else bad "expected exit 1, got $ec"; fi
if grep -q "invalid day" "$tmpdir/10.err"; then
  ok "stderr names the invalid-day check"
else
  bad "expected 'invalid day' in stderr:"; sed 's/^/    /' "$tmpdir/10.err"
fi

# --- Test 11: multiple defects reported in ONE shot ----------------------
# Contract: exit 1 AND every problem printed, not just the first. This file
# has THREE distinct defects: missing 'type' key, no expected section, and an
# invalid month. We assert >= 2 distinct "  - " error lines on stderr.
say "Test 11: multiple defects → all reported at once"
f="$tmpdir/multi.md"
cat > "$f" <<'EOF'
---
name: x
description: y
---

## Some Other Heading

- recorded on 2026-13-05 (bad month) with no expected section and no type key.
EOF
ec=$(run_validate "$f" "$tmpdir/11.out" "$tmpdir/11.err")
if [[ "$ec" -eq 1 ]]; then ok "exit 1"; else bad "expected exit 1, got $ec"; fi
err_lines=$(grep -c '^  - ' "$tmpdir/11.err" || true)
if [[ "$err_lines" -ge 2 ]]; then
  ok "reported $err_lines distinct errors in one invocation (>=2)"
else
  bad "expected >=2 error lines, got $err_lines; stderr:"; sed 's/^/    /' "$tmpdir/11.err"
fi

# --- Test 12: --memory-dir resolves a relative file argument -------------
say "Test 12: --memory-dir resolves a relative file path"
mdir="$tmpdir/mem"; mkdir -p "$mdir"
write_valid "$mdir/learnings-foo.md"
set +e
NO_COLOR=1 "$VALIDATE" --memory-dir "$mdir" learnings-foo.md \
  > "$tmpdir/12.out" 2> "$tmpdir/12.err"
ec=$?
set -e
if [[ "$ec" -eq 0 ]]; then
  ok "exit 0 — relative arg resolved under --memory-dir"
else
  bad "expected exit 0, got $ec; stderr:"; sed 's/^/    /' "$tmpdir/12.err"
fi

# --- Test 13: missing file → exit 2 --------------------------------------
say "Test 13: nonexistent file → exit 2 (not 1)"
set +e
NO_COLOR=1 "$VALIDATE" "$tmpdir/does-not-exist.md" \
  > "$tmpdir/13.out" 2> "$tmpdir/13.err"
ec=$?
set -e
if [[ "$ec" -eq 2 ]]; then
  ok "exit 2 on missing file"
else
  bad "expected exit 2, got $ec; stderr:"; sed 's/^/    /' "$tmpdir/13.err"
fi

# --- Test 14: unknown flag → exit 2 --------------------------------------
say "Test 14: unknown flag → exit 2"
set +e
NO_COLOR=1 "$VALIDATE" --bogus-flag "$tmpdir/valid.md" \
  > "$tmpdir/14.out" 2> "$tmpdir/14.err"
ec=$?
set -e
if [[ "$ec" -eq 2 ]]; then ok "exit 2 on unknown flag"; else bad "expected exit 2, got $ec"; fi

# --- Test 15: no file argument → exit 2 ----------------------------------
say "Test 15: no file argument → exit 2"
set +e
NO_COLOR=1 "$VALIDATE" > "$tmpdir/15.out" 2> "$tmpdir/15.err"
ec=$?
set -e
if [[ "$ec" -eq 2 ]]; then ok "exit 2 when no file given"; else bad "expected exit 2, got $ec"; fi
if grep -q "missing <learnings-file" "$tmpdir/15.err"; then
  ok "stderr names the missing-argument error"
else
  bad "expected 'missing <learnings-file' in stderr:"; sed 's/^/    /' "$tmpdir/15.err"
fi

# --- Test 16: --help → exit 0 --------------------------------------------
say "Test 16: --help → exit 0"
set +e
NO_COLOR=1 "$VALIDATE" --help > "$tmpdir/16.out" 2> "$tmpdir/16.err"
ec=$?
set -e
if [[ "$ec" -eq 0 ]]; then ok "exit 0 on --help"; else bad "expected exit 0, got $ec"; fi
if grep -q "Usage:" "$tmpdir/16.out"; then
  ok "--help prints usage to stdout"
else
  bad "expected 'Usage:' on stdout:"; sed 's/^/    /' "$tmpdir/16.out"
fi

# --- Summary -------------------------------------------------------------
echo ""
echo "${C_BOLD}Total: $((passed + failed))  passed: ${C_GREEN}${passed}${C_RESET}  failed: ${C_RED}${failed}${C_RESET}"
if [[ "$failed" -gt 0 ]]; then
  exit 1
fi
exit 0

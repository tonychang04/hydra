#!/usr/bin/env bash
#
# test-validate-evidence-table.sh — regression test for
# scripts/validate-evidence-table.sh (ticket #196, evidence-based review gate).
#
# Proves the EVIDENCE TABLE template enforces the hard rule: no criterion gets a
# clean PASS without concrete evidence. The headline assertion (Test 2) is that a
# review marking a criterion PASS with an empty Evidence cell is REJECTED.
#
# Exercises:
#   - Valid table (every PASS has evidence)                 -> exit 0
#   - PASS with empty Evidence cell                          -> exit 1  (core rule)
#   - PASS with placeholder evidence (-, n/a, none, ``)      -> exit 1
#   - UNVERIFIED with no evidence                            -> exit 0  (allowed)
#   - FAIL with no evidence                                  -> exit 0  (allowed)
#   - Illegal verdict (MAYBE)                                -> exit 1
#   - Zero criterion rows                                    -> exit 1
#   - No / garbled table header                              -> exit 2
#   - Reads a full review-comment body (table embedded)      -> exit 0
#   - --file <path> path                                     -> exit 0
#   - trace:<id> evidence (forward-compat for #197)          -> exit 0
#   - --help                                                 -> exit 0
#
# Style: matches scripts/test-check-claude-md-size.sh (bash, colored output,
# pass/fail counter, no external test harness). Spec:
# docs/specs/2026-05-21-evidence-based-review-gate.md

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CHECK="$SCRIPT_DIR/validate-evidence-table.sh"

if [[ ! -f "$CHECK" ]]; then
  echo "test-validate-evidence-table: $CHECK not found" >&2
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

say() { printf "\n${C_BOLD}> %s${C_RESET}\n" "$*"; }
ok()  { printf "  ${C_GREEN}OK${C_RESET}  %s\n" "$*"; passed=$((passed + 1)); }
bad() { printf "  ${C_RED}XX${C_RESET}  %s\n" "$*"; failed=$((failed + 1)); }

# run_stdin <fixture-file>  -> sets global EC to the checker's exit code,
# captures stdout+stderr in $tmpdir/out.
run_stdin() {
  local fixture="$1"
  set +e
  NO_COLOR=1 bash "$CHECK" < "$fixture" > "$tmpdir/out" 2>&1
  EC=$?
  set -e
}

# A valid evidence table body (used as the baseline + edited per test).
valid_table() {
  cat <<'EOF'
Commander review of PR #42

**Acceptance criteria — evidence**

| # | Criterion | Verdict | Evidence |
|---|---|---|---|
| 1 | Endpoint returns 200 on health | PASS | `curl localhost:3000/health` -> `{"ok":true}` 200 |
| 2 | New flag parses | PASS | test `parses --flag` -> `1 passed`; diff `scripts/x.sh:42` |
| 3 | Migration is reversible | UNVERIFIED | needs a live DB; no fixture in this PR |

**Blockers** (must fix before merge)
- (none)
EOF
}

# ---------- Test 1: valid table -> exit 0 ----------
say "Test 1: valid table (every PASS has evidence) -> exit 0"
valid_table > "$tmpdir/t1.md"
run_stdin "$tmpdir/t1.md"
if [[ "$EC" -eq 0 ]]; then ok "exit 0"; else bad "expected 0, got $EC; out: $(cat "$tmpdir/out")"; fi

# ---------- Test 2: PASS without evidence -> exit 1 (THE core rule) ----------
say "Test 2: a criterion marked PASS with an EMPTY Evidence cell -> exit 1 (rejected)"
cat > "$tmpdir/t2.md" <<'EOF'
Commander review of PR #42

| # | Criterion | Verdict | Evidence |
|---|---|---|---|
| 1 | Endpoint returns 200 on health | PASS |  |
| 2 | New flag parses | PASS | test `parses --flag` -> `1 passed` |
EOF
run_stdin "$tmpdir/t2.md"
if [[ "$EC" -eq 1 ]]; then
  ok "PASS-without-evidence is rejected (exit 1)"
else
  bad "expected exit 1 for PASS without evidence, got $EC; out: $(cat "$tmpdir/out")"
fi
if grep -qiE "row 1|criterion 1|PASS.*evidence|evidence.*PASS" "$tmpdir/out"; then
  ok "stderr names the offending PASS row"
else
  bad "expected the offending row named in output; got: $(cat "$tmpdir/out")"
fi
# The well-formed row 2 must NOT be flagged.
if grep -qiE "row 2" "$tmpdir/out"; then
  bad "row 2 (valid PASS w/ evidence) should not be flagged; got: $(cat "$tmpdir/out")"
else
  ok "valid PASS row is not flagged"
fi

# ---------- Test 3: PASS with placeholder evidence -> exit 1 ----------
say "Test 3: PASS rows with placeholder evidence (-, n/a, none, backticks) -> exit 1"
for ph in "-" "n/a" "N/A" "none" "None" '``' "   "; do
  cat > "$tmpdir/t3.md" <<EOF
Commander review of PR #42

| # | Criterion | Verdict | Evidence |
|---|---|---|---|
| 1 | Some criterion | PASS | $ph |
EOF
  run_stdin "$tmpdir/t3.md"
  if [[ "$EC" -eq 1 ]]; then
    ok "placeholder evidence '$ph' rejected (exit 1)"
  else
    bad "expected exit 1 for placeholder '$ph', got $EC; out: $(cat "$tmpdir/out")"
  fi
done

# ---------- Test 4: UNVERIFIED with no evidence -> exit 0 ----------
say "Test 4: UNVERIFIED row with an empty Evidence cell -> exit 0 (allowed)"
cat > "$tmpdir/t4.md" <<'EOF'
Commander review of PR #42

| # | Criterion | Verdict | Evidence |
|---|---|---|---|
| 1 | Needs production data | UNVERIFIED |  |
EOF
run_stdin "$tmpdir/t4.md"
if [[ "$EC" -eq 0 ]]; then ok "UNVERIFIED without evidence allowed"; else bad "expected 0, got $EC; out: $(cat "$tmpdir/out")"; fi

# ---------- Test 5: FAIL with no evidence -> exit 0 ----------
say "Test 5: FAIL row with an empty Evidence cell -> exit 0 (allowed)"
cat > "$tmpdir/t5.md" <<'EOF'
Commander review of PR #42

| # | Criterion | Verdict | Evidence |
|---|---|---|---|
| 1 | Returns 200 | FAIL |  |
EOF
run_stdin "$tmpdir/t5.md"
if [[ "$EC" -eq 0 ]]; then ok "FAIL without evidence allowed"; else bad "expected 0, got $EC; out: $(cat "$tmpdir/out")"; fi

# ---------- Test 6: illegal verdict -> exit 1 ----------
say "Test 6: illegal verdict (MAYBE) -> exit 1"
cat > "$tmpdir/t6.md" <<'EOF'
Commander review of PR #42

| # | Criterion | Verdict | Evidence |
|---|---|---|---|
| 1 | Something | MAYBE | some evidence here |
EOF
run_stdin "$tmpdir/t6.md"
if [[ "$EC" -eq 1 ]]; then ok "illegal verdict rejected"; else bad "expected 1, got $EC; out: $(cat "$tmpdir/out")"; fi
if grep -qiE "MAYBE|verdict" "$tmpdir/out"; then ok "names the bad verdict"; else bad "expected verdict named; got: $(cat "$tmpdir/out")"; fi

# ---------- Test 7: zero criterion rows -> exit 1 ----------
say "Test 7: header present but zero data rows -> exit 1"
cat > "$tmpdir/t7.md" <<'EOF'
Commander review of PR #42

| # | Criterion | Verdict | Evidence |
|---|---|---|---|

**Blockers**
- (none)
EOF
run_stdin "$tmpdir/t7.md"
if [[ "$EC" -eq 1 ]]; then ok "zero-criteria table rejected"; else bad "expected 1, got $EC; out: $(cat "$tmpdir/out")"; fi

# ---------- Test 8: no/garbled table header -> exit 2 ----------
say "Test 8: body with NO evidence table -> exit 2 (parse error)"
cat > "$tmpdir/t8.md" <<'EOF'
Commander review of PR #42

**Blockers**
- (none)

Just a free-form review, no evidence table at all.
EOF
run_stdin "$tmpdir/t8.md"
if [[ "$EC" -eq 2 ]]; then ok "missing table -> exit 2"; else bad "expected 2, got $EC; out: $(cat "$tmpdir/out")"; fi

# ---------- Test 9: full review-comment body with the table embedded -> exit 0 ----------
say "Test 9: realistic full comment (header + table + Blockers/Concerns/Nits) -> exit 0"
cat > "$tmpdir/t9.md" <<'EOF'
Commander review of PR #42

**Acceptance criteria — evidence**

| # | Criterion | Verdict | Evidence |
|---|---|---|---|
| 1 | digest command added | PASS | test `digest channel` -> `4 passed`; diff `scripts/build-daily-digest.sh:1` |
| 2 | composer renders sections | PASS | `bash scripts/build-daily-digest.sh --dry-run` -> non-empty digest |
| 3 | autopickup step-1.6 hook fires | UNVERIFIED | scheduler not exercised in CI |

**Blockers** (must fix before merge)
- (none)

**Concerns** (should address)
- (none)

**Nits** (optional polish)
- (none)

**Signed-off by** commander-review · skills run: /review, /codex review
EOF
run_stdin "$tmpdir/t9.md"
if [[ "$EC" -eq 0 ]]; then ok "full comment with valid table -> exit 0"; else bad "expected 0, got $EC; out: $(cat "$tmpdir/out")"; fi

# ---------- Test 10: --file <path> path ----------
say "Test 10: --file <path> reads the body from a file -> exit 0"
set +e
NO_COLOR=1 bash "$CHECK" --file "$tmpdir/t9.md" > "$tmpdir/out" 2>&1
EC=$?
set -e
if [[ "$EC" -eq 0 ]]; then ok "--file path works"; else bad "expected 0, got $EC; out: $(cat "$tmpdir/out")"; fi

# ---------- Test 11: trace:<id> evidence (forward-compat for #197) ----------
say "Test 11: a PASS whose ONLY evidence is trace:<id> -> exit 0 (#197 forward-compat)"
cat > "$tmpdir/t11.md" <<'EOF'
Commander review of PR #42

| # | Criterion | Verdict | Evidence |
|---|---|---|---|
| 1 | session does the thing | PASS | trace:abc123 |
EOF
run_stdin "$tmpdir/t11.md"
if [[ "$EC" -eq 0 ]]; then
  ok "trace:<id> counts as evidence -> no checker change needed for #197"
else
  bad "expected 0 for trace: evidence, got $EC; out: $(cat "$tmpdir/out")"
fi

# ---------- Test 12: --help -> exit 0 ----------
say "Test 12: --help -> exit 0"
set +e
NO_COLOR=1 bash "$CHECK" --help > "$tmpdir/out" 2>&1
EC=$?
set -e
if [[ "$EC" -eq 0 ]] && grep -qi "usage" "$tmpdir/out"; then ok "--help exits 0 with usage"; else bad "expected 0 + usage, got $EC; out: $(cat "$tmpdir/out")"; fi

# ---------- Test 13: case-insensitive verdicts ----------
say "Test 13: lowercase verdicts (pass/fail/unverified) accepted"
cat > "$tmpdir/t13.md" <<'EOF'
Commander review of PR #42

| # | Criterion | Verdict | Evidence |
|---|---|---|---|
| 1 | a | pass | `cmd` -> ok |
| 2 | b | fail |  |
| 3 | c | unverified |  |
EOF
run_stdin "$tmpdir/t13.md"
if [[ "$EC" -eq 0 ]]; then ok "lowercase verdicts accepted"; else bad "expected 0, got $EC; out: $(cat "$tmpdir/out")"; fi

# ---------- Test 14: escaped pipe (\|) inside a cell does NOT shift columns ----------
# A criterion or evidence cell with a shell pipeline must escape the pipe as \|
# (GitHub renders it literally). The splitter must treat \| as content, so the
# verdict column stays PASS and the row validates. Regression for the codex P2.
say "Test 14: escaped pipe \\| in Criterion AND Evidence cells -> exit 0 (no column shift)"
cat > "$tmpdir/t14.md" <<'EOF'
Commander review of PR #42

| # | Criterion | Verdict | Evidence |
|---|---|---|---|
| 1 | counts matching lines with `grep x \| wc -l` | PASS | ran `grep x f \| wc -l` -> `3` |
EOF
run_stdin "$tmpdir/t14.md"
if [[ "$EC" -eq 0 ]]; then
  ok "escaped pipes kept as content; verdict column not shifted (exit 0)"
else
  bad "expected exit 0 for escaped-pipe row, got $EC; out: $(cat "$tmpdir/out")"
fi

# ---------- Test 15: escaped pipe must NOT smuggle empty evidence past the gate ----------
# `\|` is restored as a literal pipe, which is NOT a placeholder, so a PASS whose
# evidence is only an escaped pipe is still treated as having content. But a PASS
# with a genuinely empty evidence cell that merely has \| in the CRITERION must
# still be caught.
say "Test 15: \\| in Criterion but EMPTY Evidence on a PASS row -> exit 1 (still caught)"
cat > "$tmpdir/t15.md" <<'EOF'
Commander review of PR #42

| # | Criterion | Verdict | Evidence |
|---|---|---|---|
| 1 | pipeline `a \| b` works | PASS |  |
EOF
run_stdin "$tmpdir/t15.md"
if [[ "$EC" -eq 1 ]]; then
  ok "empty evidence still caught even when criterion has an escaped pipe"
else
  bad "expected exit 1 (empty evidence), got $EC; out: $(cat "$tmpdir/out")"
fi

# ---------- Test 16: screenshot-ONLY PASS -> exit 1 (#191 meaningful-bar rule) ----------
# A screenshot is corroboration, not an assertion. A PASS whose ONLY evidence is
# a screenshot reference (a picture with no asserted state) is rejected exactly
# like an empty cell — this keeps the #191 flexibility from re-opening the
# "tests claimed not run" hole (#118). The behavioral assertion is load-bearing.
say "Test 16: a PASS whose ONLY evidence is a screenshot -> exit 1 (screenshot is not an assertion)"
for shot in \
  "screenshot" \
  "screenshot dashboard.png" \
  "see screenshot" \
  "screencap of the page" \
  "![dashboard](./shots/dash.png)" \
  "shots/login.png" \
  "evidence.jpg"; do
  cat > "$tmpdir/t16.md" <<EOF
Commander review of PR #42

| # | Criterion | Verdict | Evidence |
|---|---|---|---|
| 1 | Dashboard renders the items list | PASS | $shot |
EOF
  run_stdin "$tmpdir/t16.md"
  if [[ "$EC" -eq 1 ]]; then
    ok "screenshot-only evidence '$shot' rejected (exit 1)"
  else
    bad "expected exit 1 for screenshot-only '$shot', got $EC; out: $(cat "$tmpdir/out")"
  fi
done
# stderr should explain a screenshot is not a behavioral assertion.
cat > "$tmpdir/t16b.md" <<'EOF'
Commander review of PR #42

| # | Criterion | Verdict | Evidence |
|---|---|---|---|
| 1 | Dashboard renders the items list | PASS | screenshot dashboard.png |
EOF
run_stdin "$tmpdir/t16b.md"
if grep -qiE "screenshot|assertion|behaviou?ral" "$tmpdir/out"; then
  ok "stderr explains a screenshot alone is not an assertion"
else
  bad "expected screenshot/assertion guidance; got: $(cat "$tmpdir/out")"
fi

# ---------- Test 17: behavioral assertion + ONE screenshot -> exit 0 (#191 happy path) ----------
# The #191 policy: behavioral assertion (REST/DOM/SDK/exit-code/HTTP state) is the
# evidence; a single representative screenshot rides along. This PASSES.
say "Test 17: behavioral assertion + one screenshot -> exit 0 (assertion carries it)"
for ev in \
  "\`curl localhost:3000/items\` -> \`[{\"id\":1}]\` 200; screenshot dashboard.png" \
  "REST GET /items -> 200 \`[{\"id\":1}]\`; ![dash](shots/dash.png)" \
  "exit 0 from \`andb query\`; screenshot of result.png" \
  "DOM \`.items li\` count = 3 (asserted); see screenshot login.png"; do
  cat > "$tmpdir/t17.md" <<EOF
Commander review of PR #42

| # | Criterion | Verdict | Evidence |
|---|---|---|---|
| 1 | Items list loads | PASS | $ev |
EOF
  run_stdin "$tmpdir/t17.md"
  if [[ "$EC" -eq 0 ]]; then
    ok "assertion + screenshot accepted (exit 0): '$ev'"
  else
    bad "expected exit 0 for assertion+screenshot, got $EC; out: $(cat "$tmpdir/out")"
  fi
done

# ---------- Test 18: behavioral assertion ALONE -> exit 0 (screenshots optional) ----------
# Non-goal: screenshots are NOT mandatory. An assertion-only PASS stays valid.
say "Test 18: behavioral assertion alone, no screenshot -> exit 0 (screenshots optional)"
cat > "$tmpdir/t18.md" <<'EOF'
Commander review of PR #42

| # | Criterion | Verdict | Evidence |
|---|---|---|---|
| 1 | Health endpoint returns 200 | PASS | `curl localhost:3000/health` -> `{"ok":true}` 200 |
| 2 | exit code is 0 | PASS | `andb migrate` -> exit 0 |
EOF
run_stdin "$tmpdir/t18.md"
if [[ "$EC" -eq 0 ]]; then ok "assertion-only PASS still valid (screenshots optional)"; else bad "expected 0, got $EC; out: $(cat "$tmpdir/out")"; fi

# ---------- Test 19: messy screenshot-ONLY forms -> exit 1 (the leak fix) ----------
# Tests 16-18 only covered clean single-filename screenshot refs. The #191 fix
# shipped a leak: any space / quote / paren / comma / *, @, ?, or URL adjacent to
# the image filename left a bare token (png/jpg, a URL scheme, a query string)
# that survived the strip and was mistaken for a behavioral assertion -> a
# screenshot-ONLY PASS was WRONGLY accepted. These forms MUST be rejected (exit 1)
# exactly like an empty cell, preserving the #118 "tests claimed not run" guard.
# The most important case is the literal default macOS screenshot filename, which
# carries spaces.
say "Test 19: messy screenshot-only forms (spaces / punctuation / URL / query) -> exit 1"
for shot in \
  "Screenshot 2026-06-01 at 1.23.45 PM.png" \
  "foo@2x.png" \
  "screenshots: a.png" \
  "*.png" \
  "https://example.com/x.png" \
  "x.png?raw=1" \
  '"a.png"' \
  "(a.png)" \
  "screenshot, a.png" \
  "see Screenshot 2026-06-01 at 1.23.45 PM.png attached"; do
  cat > "$tmpdir/t19.md" <<EOF
Commander review of PR #42

| # | Criterion | Verdict | Evidence |
|---|---|---|---|
| 1 | Dashboard renders the items list | PASS | $shot |
EOF
  run_stdin "$tmpdir/t19.md"
  if [[ "$EC" -eq 1 ]]; then
    ok "messy screenshot-only '$shot' rejected (exit 1)"
  else
    bad "expected exit 1 for messy screenshot-only '$shot', got $EC; out: $(cat "$tmpdir/out")"
  fi
done

# ---------- Test 20: markdown image ALT-TEXT carries a real assertion -> exit 0 ----------
# An assertion can live ONLY in the alt-text of a markdown image: ![HTTP 200](x.png).
# The previous code stripped the whole `![alt](url)` construct INCLUDING the
# alt-text, wrongly REJECTING a real assertion. The alt-text must be PRESERVED
# (keep `alt`, drop the link) so a PASS asserting state via alt-text passes.
say "Test 20: assertion in markdown image alt-text -> exit 0 (alt-text preserved)"
for alt in \
  "![HTTP 200](x.png)" \
  "![exit 0](run.png)" \
  "![curl /items -> 200 \`[{\"id\":1}]\`](shots/items.png)"; do
  cat > "$tmpdir/t20.md" <<EOF
Commander review of PR #42

| # | Criterion | Verdict | Evidence |
|---|---|---|---|
| 1 | Items list loads | PASS | $alt |
EOF
  run_stdin "$tmpdir/t20.md"
  if [[ "$EC" -eq 0 ]]; then
    ok "alt-text assertion '$alt' preserved -> exit 0"
  else
    bad "expected exit 0 for alt-text assertion '$alt', got $EC; out: $(cat "$tmpdir/out")"
  fi
done

# A markdown image whose alt-text is ITSELF just a screenshot label (no assertion)
# must still be rejected — preserving alt-text must not become a new leak.
say "Test 20b: markdown image with screenshot-only alt-text -> exit 1 (still no assertion)"
for alt in \
  "![dashboard screenshot](shots/dash.png)" \
  "![screenshot](x.png)" \
  "![login page](login.png)"; do
  cat > "$tmpdir/t20b.md" <<EOF
Commander review of PR #42

| # | Criterion | Verdict | Evidence |
|---|---|---|---|
| 1 | Dashboard renders | PASS | $alt |
EOF
  run_stdin "$tmpdir/t20b.md"
  if [[ "$EC" -eq 1 ]]; then
    ok "screenshot-only alt-text '$alt' rejected (exit 1)"
  else
    bad "expected exit 1 for screenshot-only alt-text '$alt', got $EC; out: $(cat "$tmpdir/out")"
  fi
done

# ---------- Test 21: image types BEYOND png/jpg + adjacency forms -> exit 1 ----------
# #191 re-work FINAL, BLOCKER A. The first leak fix hard-coded a 5-extension set
# (png|jpg|jpeg|gif|webp) layered under a `*.png*` SUBSTRING rule. Image types
# outside that set (bmp, svg, heic, tif, tiff, avif) were never recognized as
# screenshots, so a screenshot-ONLY PASS using them was WRONGLY accepted. A couple
# of adjacency forms (a trailing resolution string, a path glued to "Screen Shot")
# also leaked. All of these are screenshots with NO behavioral assertion and MUST
# be rejected (exit 1), exactly like an empty cell.
say "Test 21: screenshot-only with broader image types + adjacency -> exit 1 (BLOCKER A)"
for shot in \
  "capture.bmp" \
  "diagram.svg" \
  "photo.heic" \
  "grab.tif" \
  "grab.tiff" \
  "screenshots/login.avif" \
  "shot.png (1920x1080)" \
  "~/Desktop/Screen Shot.png"; do
  cat > "$tmpdir/t21.md" <<EOF
Commander review of PR #42

| # | Criterion | Verdict | Evidence |
|---|---|---|---|
| 1 | Dashboard renders the items list | PASS | $shot |
EOF
  run_stdin "$tmpdir/t21.md"
  if [[ "$EC" -eq 1 ]]; then
    ok "screenshot-only (broad ext / adjacency) '$shot' rejected (exit 1)"
  else
    bad "expected exit 1 for screenshot-only '$shot', got $EC; out: $(cat "$tmpdir/out")"
  fi
done

# ---------- Test 22: file:line / trace: assertion whose PATH contains an image ext -> exit 0 ----------
# #191 re-work FINAL, BLOCKER B (NEW false-reject introduced by the `*.png*`
# SUBSTRING rule). A genuine `file:line` source reference or a `trace:` id can have
# a path component that merely CONTAINS an image extension (`app.png.ts`,
# `logo.png.tsx`, `shot.png` inside a trace id). The SUBSTRING rule dropped these
# real assertions. The principled rule — a token is an image reference only when it
# ENDS in a known image extension after stripping query/fragment + trailing punct —
# keeps `app.png.ts` (ends in `.ts`, not an image) as a real assertion. These MUST
# PASS (exit 0).
say "Test 22: real assertion whose path CONTAINS (but does not end in) an image ext -> exit 0 (BLOCKER B)"
for ev in \
  "src/app.png.ts:42" \
  "src/icons/logo.png.tsx:42" \
  "trace:shot.png"; do
  cat > "$tmpdir/t22.md" <<EOF
Commander review of PR #42

| # | Criterion | Verdict | Evidence |
|---|---|---|---|
| 1 | Behavior asserted at source | PASS | $ev |
EOF
  run_stdin "$tmpdir/t22.md"
  if [[ "$EC" -eq 0 ]]; then
    ok "assertion with image-ext-in-path '$ev' preserved (exit 0)"
  else
    bad "expected exit 0 for assertion '$ev', got $EC; out: $(cat "$tmpdir/out")"
  fi
done

# ---------- Test 23: adversarial messy forms (uppercase ext / trailing comma / bare URL) ----------
# Stress the principled "ends in a known image ext after stripping query/fragment +
# trailing punctuation" rule with case + punctuation noise, so a reviewer cannot
# find a 3rd leak class. Each of these is a screenshot-ONLY reference -> exit 1.
say "Test 23: adversarial screenshot-only forms (uppercase / trailing comma / bare URL) -> exit 1"
for shot in \
  "evidence.PNG" \
  "a.png," \
  "https://example.com/path/to/shot.jpeg" \
  "Capture.HEIC" \
  "render.WEBP" \
  "diagram.SVG." \
  "shot.tiff?raw=1"; do
  cat > "$tmpdir/t23.md" <<EOF
Commander review of PR #42

| # | Criterion | Verdict | Evidence |
|---|---|---|---|
| 1 | Dashboard renders the items list | PASS | $shot |
EOF
  run_stdin "$tmpdir/t23.md"
  if [[ "$EC" -eq 1 ]]; then
    ok "adversarial screenshot-only '$shot' rejected (exit 1)"
  else
    bad "expected exit 1 for adversarial screenshot-only '$shot', got $EC; out: $(cat "$tmpdir/out")"
  fi
done

# ---------- summary ----------
echo ""
echo "============================================================"
if [[ "$failed" -eq 0 ]]; then
  printf "${C_GREEN}${C_BOLD}test-validate-evidence-table: OK${C_RESET} (%d passed)\n" "$passed"
  exit 0
fi
printf "${C_RED}${C_BOLD}test-validate-evidence-table: FAIL${C_RESET} (%d passed, %d failed)\n" \
  "$passed" "$failed" >&2
exit 1

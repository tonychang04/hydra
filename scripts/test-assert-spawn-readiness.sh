#!/usr/bin/env bash
#
# test-assert-spawn-readiness.sh — regression test for
# scripts/assert-spawn-readiness.sh (ticket #308, pre-spawn readiness gate).
#
# Proves the helper deterministically reports whether a checkout's base is
# current (not behind origin) and clean (no dirty tracked changes) before a
# worktree is cut from it. Each test builds a throwaway git repo + a bare-ish
# origin clone in a mktemp dir and runs the helper OFFLINE (--no-fetch).
#
# Style: matches scripts/test-plan-parallel-batch.sh (bash, colored output,
# pass/fail counter, no external harness).
# Spec: docs/specs/2026-06-18-pre-spawn-readiness-gate.md

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
HELPER="$SCRIPT_DIR/assert-spawn-readiness.sh"

if [[ ! -f "$HELPER" ]]; then
  echo "test-assert-spawn-readiness: $HELPER not found" >&2
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
tmproot="$(mktemp -d)"
trap 'rm -rf "$tmproot"' EXIT

say() { printf "\n${C_BOLD}> %s${C_RESET}\n" "$*"; }
ok()  { printf "  ${C_GREEN}OK${C_RESET}  %s\n" "$*"; passed=$((passed + 1)); }
bad() { printf "  ${C_RED}XX${C_RESET}  %s\n" "$*"; failed=$((failed + 1)); }

# new_pair <name> -> echoes "<origin-dir> <clone-dir>" with one commit on main.
# The origin is a normal (non-bare) repo so we can add commits to it later to
# simulate the clone falling behind.
new_pair() {
  local name="$1"
  local base="$tmproot/$name"
  local origin="$base/origin"
  local clone="$base/clone"
  mkdir -p "$origin"
  # git 2.23 has no `init -b`; init then rename the default branch to main.
  git init -q "$origin"
  git -C "$origin" config user.email t@t
  git -C "$origin" config user.name t
  echo a > "$origin/a"
  git -C "$origin" add -A
  git -C "$origin" commit -qm a
  git -C "$origin" branch -M main
  git clone -q "$origin" "$clone"
  git -C "$clone" config user.email t@t
  git -C "$clone" config user.name t
  git -C "$clone" checkout -q main
  printf '%s %s\n' "$origin" "$clone"
}

# run_json <clone-dir> -> sets EC + writes JSON to $tmproot/out
run_json() {
  local clone="$1"
  set +e
  NO_COLOR=1 bash "$HELPER" --repo-dir "$clone" --base main --no-fetch --json \
    > "$tmproot/out" 2>"$tmproot/err"
  EC=$?
  set -e
}

jq_get() { jq -rc "$1" "$tmproot/out" 2>/dev/null; }

# ---------- Test 1: clean, up-to-date base -> ready:true, exit 0 ----------
say "Test 1: clean, up-to-date base -> ready:true behind:0 dirty:false, exit 0"
read -r _o1 c1 <<<"$(new_pair t1)"
run_json "$c1"
if [[ "$EC" -eq 0 ]]; then ok "exit 0"; else bad "expected 0, got $EC; err: $(cat "$tmproot/err")"; fi
if [[ "$(jq_get '.ready')" == "true" ]]; then ok "ready:true"; else bad "ready was $(jq_get '.ready')"; fi
if [[ "$(jq_get '.behind')" == "0" ]]; then ok "behind:0"; else bad "behind was $(jq_get '.behind')"; fi
if [[ "$(jq_get '.dirty')" == "false" ]]; then ok "dirty:false"; else bad "dirty was $(jq_get '.dirty')"; fi
if [[ "$(jq_get '.remediation')" == "null" ]]; then ok "remediation:null"; else bad "remediation was $(jq_get '.remediation')"; fi

# ---------- Test 2: base N behind origin -> ready:false, remediation, exit 1 ----------
say "Test 2: base 2 behind origin -> ready:false behind:2 remediation present, exit 1"
read -r o2 c2 <<<"$(new_pair t2)"
# advance origin by 2 commits, fetch into clone (so origin/main is ahead, local main behind)
echo b > "$o2/b"; git -C "$o2" add -A; git -C "$o2" commit -qm b
echo c > "$o2/c"; git -C "$o2" add -A; git -C "$o2" commit -qm c
git -C "$c2" fetch -q origin main
run_json "$c2"
if [[ "$EC" -eq 1 ]]; then ok "exit 1"; else bad "expected 1, got $EC; err: $(cat "$tmproot/err")"; fi
if [[ "$(jq_get '.ready')" == "false" ]]; then ok "ready:false"; else bad "ready was $(jq_get '.ready')"; fi
if [[ "$(jq_get '.behind')" == "2" ]]; then ok "behind:2"; else bad "behind was $(jq_get '.behind')"; fi
if [[ "$(jq_get '.remediation')" == "git merge --ff-only origin/main" ]]; then ok "remediation is ff-only command"; else bad "remediation was $(jq_get '.remediation')"; fi

# ---------- Test 3: dirty tracked change on base -> ready:false dirty:true, exit 1 ----------
say "Test 3: dirty tracked change -> ready:false dirty:true, exit 1"
read -r _o3 c3 <<<"$(new_pair t3)"
echo changed > "$c3/a"   # modify a tracked file
run_json "$c3"
if [[ "$EC" -eq 1 ]]; then ok "exit 1"; else bad "expected 1, got $EC; err: $(cat "$tmproot/err")"; fi
if [[ "$(jq_get '.ready')" == "false" ]]; then ok "ready:false"; else bad "ready was $(jq_get '.ready')"; fi
if [[ "$(jq_get '.dirty')" == "true" ]]; then ok "dirty:true"; else bad "dirty was $(jq_get '.dirty')"; fi

# ---------- Test 4: untracked-only -> ready:true, exit 0, listed ----------
say "Test 4: untracked-only files -> ready:true, exit 0, listed in untracked[]"
read -r _o4 c4 <<<"$(new_pair t4)"
echo scratch > "$c4/untracked.txt"   # untracked file, NOT a blocker
run_json "$c4"
if [[ "$EC" -eq 0 ]]; then ok "exit 0"; else bad "expected 0, got $EC; err: $(cat "$tmproot/err")"; fi
if [[ "$(jq_get '.ready')" == "true" ]]; then ok "ready:true"; else bad "ready was $(jq_get '.ready')"; fi
if [[ "$(jq_get '.dirty')" == "false" ]]; then ok "dirty:false (untracked is not dirty)"; else bad "dirty was $(jq_get '.dirty')"; fi
if jq -e '.untracked | index("untracked.txt")' "$tmproot/out" >/dev/null 2>&1; then ok "untracked.txt listed"; else bad "untracked was $(jq_get '.untracked')"; fi

# ---------- Test 5: --json is valid JSON in every case ----------
say "Test 5: --json output is valid JSON across cases"
all_json_ok=1
for c in "$c1" "$c2" "$c3" "$c4"; do
  run_json "$c"
  if ! jq empty "$tmproot/out" >/dev/null 2>&1; then all_json_ok=0; fi
done
if [[ "$all_json_ok" -eq 1 ]]; then ok "all four cases emit valid JSON"; else bad "a case emitted invalid JSON"; fi

# ---------- Test 6: usage errors ----------
say "Test 6: not-a-git-repo -> exit 2; unknown flag -> exit 2; --help -> exit 0"
notgit="$tmproot/notgit"; mkdir -p "$notgit"
set +e
NO_COLOR=1 bash "$HELPER" --repo-dir "$notgit" --no-fetch --json >/dev/null 2>&1; NG=$?
NO_COLOR=1 bash "$HELPER" --bogus-flag >/dev/null 2>&1; UF=$?
NO_COLOR=1 bash "$HELPER" --help >/dev/null 2>&1; HC=$?
set -e
if [[ "$NG" -eq 2 ]]; then ok "not-a-git-repo -> exit 2"; else bad "expected 2, got $NG"; fi
if [[ "$UF" -eq 2 ]]; then ok "unknown flag -> exit 2"; else bad "expected 2, got $UF"; fi
if [[ "$HC" -eq 0 ]]; then ok "--help -> exit 0"; else bad "expected 0, got $HC"; fi

# ---------- Test 7: determinism (byte-identical JSON modulo generated_at) ----------
say "Test 7: same state twice -> byte-identical JSON (ignoring generated_at)"
run_json "$c1"; jq 'del(.generated_at)' "$tmproot/out" > "$tmproot/det1.json"
run_json "$c1"; jq 'del(.generated_at)' "$tmproot/out" > "$tmproot/det2.json"
if diff -q "$tmproot/det1.json" "$tmproot/det2.json" >/dev/null; then ok "deterministic output"; else bad "output differs: $(diff "$tmproot/det1.json" "$tmproot/det2.json")"; fi

# ---------- Test 8: human (non-JSON) report renders a verdict ----------
say "Test 8: human report prints READY / NOT READY verdict + remediation"
set +e
NO_COLOR=1 bash "$HELPER" --repo-dir "$c1" --base main --no-fetch > "$tmproot/human1" 2>&1; H1=$?
NO_COLOR=1 bash "$HELPER" --repo-dir "$c2" --base main --no-fetch > "$tmproot/human2" 2>&1; H2=$?
set -e
if [[ "$H1" -eq 0 ]] && grep -qi "READY" "$tmproot/human1"; then ok "ready case prints READY (exit 0)"; else bad "human1 exit $H1: $(cat "$tmproot/human1")"; fi
if [[ "$H2" -eq 1 ]] && grep -qi "NOT READY" "$tmproot/human2" && grep -q "ff-only" "$tmproot/human2"; then ok "behind case prints NOT READY + ff-only remediation (exit 1)"; else bad "human2 exit $H2: $(cat "$tmproot/human2")"; fi

# -----------------------------------------------------------------------------
printf "\n${C_BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${C_RESET}\n"
printf "${C_BOLD}%d passed · %d failed${C_RESET}\n" "$passed" "$failed"
[[ "$failed" -gt 0 ]] && exit 1
exit 0

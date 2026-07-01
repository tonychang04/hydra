#!/usr/bin/env bash
#
# test-apply-review-verdict.sh — regression test for scripts/apply-review-verdict.sh (#322).
#
# apply-review-verdict.sh actuates review-gate labels on a PR. Commander runs it
# on a worker's *_VERDICT: marker (workers are classifier-blocked from the PR
# write themselves). This test pins the verdict -> label mapping, the supersede
# (superseded-label removal) logic, idempotency, and --dry-run's no-mutation
# guarantee.
#
# Hermetic: a stub `gh` is placed FIRST on PATH; it records every REST call to
# $GH_MOCK_LOG (CREATE / ADD / DELETE lines) and never touches the network.
#
# Style matches scripts/test-contract-path.sh (bash, NO_COLOR-aware, pass/fail
# counter, no external harness).
# Spec: docs/specs/2026-07-01-commander-owns-review-verdict-actuation.md

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
APPLY="$SCRIPT_DIR/apply-review-verdict.sh"

if [[ ! -f "$APPLY" ]]; then
  echo "test-apply-review-verdict: $APPLY not found" >&2
  exit 2
fi

if [[ -t 1 ]] && [[ "${NO_COLOR:-}" != "1" ]]; then
  C_GREEN=$'\033[32m'; C_RED=$'\033[31m'; C_BOLD=$'\033[1m'; C_RESET=$'\033[0m'
else
  C_GREEN=""; C_RED=""; C_BOLD=""; C_RESET=""
fi

passed=0
failed=0
tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

say() { printf "\n${C_BOLD}> %s${C_RESET}\n" "$*"; }
ok()  { printf "  ${C_GREEN}OK${C_RESET}  %s\n" "$*"; passed=$((passed + 1)); }
bad() { printf "  ${C_RED}XX${C_RESET}  %s\n" "$*"; failed=$((failed + 1)); }

# --- gh stub: FIRST on PATH, records normalized actions to $GH_MOCK_LOG -------
stubdir="$tmpdir/bin"
mkdir -p "$stubdir"
cat > "$stubdir/gh" <<'STUB'
#!/usr/bin/env bash
# Hermetic gh stub. Normalizes label ops into the mock log:
#   CREATE <label>   for `gh label create <label> ...`
#   ADD <label>      for `gh api --method POST .../labels -f labels[]=<label>`
#   DELETE <label>   for `gh api --method DELETE .../labels/<label>`
# Any other invocation is ignored (exit 0). Honors GH_MOCK_FAIL_ADD to force an
# add failure (exit 1) for the REST-error path.
set -euo pipefail
log="${GH_MOCK_LOG:-/dev/null}"
args=("$@")

if [[ "${args[0]:-}" == "label" && "${args[1]:-}" == "create" ]]; then
  echo "CREATE ${args[2]:-}" >> "$log"
  exit 0
fi

if [[ "${args[0]:-}" == "api" ]]; then
  method=""; path=""; label=""
  i=1
  while [[ $i -lt ${#args[@]} ]]; do
    case "${args[$i]}" in
      --method) method="${args[$((i+1))]}"; i=$((i+2)); continue ;;
      -f) # labels[]=<label>
          if [[ "${args[$((i+1))]}" == labels\[\]=* ]]; then
            label="${args[$((i+1))]#labels[]=}"
          fi
          i=$((i+2)); continue ;;
      /*) path="${args[$i]}"; i=$((i+1)); continue ;;
      *) i=$((i+1)); continue ;;
    esac
  done
  if [[ "$method" == "POST" ]]; then
    if [[ "${GH_MOCK_FAIL_ADD:-}" == "$label" ]]; then
      echo "gh-stub: forced POST failure for $label" >&2
      exit 1
    fi
    echo "ADD $label" >> "$log"
    exit 0
  fi
  if [[ "$method" == "DELETE" ]]; then
    # path tail after /labels/ is the label name
    echo "DELETE ${path##*/labels/}" >> "$log"
    exit 0
  fi
fi
exit 0
STUB
chmod +x "$stubdir/gh"

# run <verdict-args...> : resets the mock log, runs the actuator with the stub
# gh first on PATH. Sets EC (exit code), OUT (stdout+stderr), LOG (mock log path).
LOG="$tmpdir/gh.log"
run() {
  : > "$LOG"
  set +e
  OUT="$(PATH="$stubdir:$PATH" GH_MOCK_LOG="$LOG" NO_COLOR=1 bash "$APPLY" "$@" 2>&1)"
  EC=$?
  set -e
}

# assert the mock log contains an exact action line
log_has() { grep -qxF "$1" "$LOG"; }
# assert the mock log does NOT contain an action line
log_lacks() { ! grep -qxF "$1" "$LOG"; }

# ---------------------------------------------------------------------------
say "verdict=reviewed -> add commander-reviewed, remove commander-review + needs-fix"
run tonychang04/hydra 501 reviewed
[[ $EC -eq 0 ]] && ok "exit 0" || bad "expected exit 0, got $EC ($OUT)"
log_has "ADD commander-reviewed"   && ok "adds commander-reviewed"   || bad "missing ADD commander-reviewed"
log_has "DELETE commander-review"  && ok "removes commander-review"  || bad "missing DELETE commander-review"
log_has "DELETE commander-needs-fix" && ok "removes commander-needs-fix" || bad "missing DELETE commander-needs-fix"
log_lacks "ADD commander-review-clean" && ok "does NOT add review-clean" || bad "unexpectedly added review-clean"

say "verdict=review-clean -> add reviewed + review-clean (superset of reviewed)"
run tonychang04/hydra 501 review-clean
[[ $EC -eq 0 ]] && ok "exit 0" || bad "expected exit 0, got $EC"
log_has "ADD commander-reviewed"      && ok "adds commander-reviewed"      || bad "missing ADD commander-reviewed"
log_has "ADD commander-review-clean"  && ok "adds commander-review-clean"  || bad "missing ADD commander-review-clean"
log_has "DELETE commander-review"     && ok "removes interim commander-review" || bad "missing DELETE commander-review"

say "verdict=validated -> add commander-validated, no removals"
run tonychang04/hydra 501 validated
[[ $EC -eq 0 ]] && ok "exit 0" || bad "expected exit 0, got $EC"
log_has "ADD commander-validated" && ok "adds commander-validated" || bad "missing ADD commander-validated"
{ ! grep -q '^DELETE' "$LOG"; } && ok "no DELETE lines" || bad "unexpected DELETE for validated"

say "verdict=needs-fix -> add needs-fix, remove reviewed/review-clean/validated"
run tonychang04/hydra 501 needs-fix
[[ $EC -eq 0 ]] && ok "exit 0" || bad "expected exit 0, got $EC"
log_has "ADD commander-needs-fix"        && ok "adds commander-needs-fix"        || bad "missing ADD commander-needs-fix"
log_has "DELETE commander-reviewed"      && ok "removes commander-reviewed"      || bad "missing DELETE commander-reviewed"
log_has "DELETE commander-review-clean"  && ok "removes commander-review-clean"  || bad "missing DELETE commander-review-clean"
log_has "DELETE commander-validated"     && ok "removes commander-validated"     || bad "missing DELETE commander-validated"

say "verdict=needs-fix lazily CREATEs the new commander-needs-fix label before ADD"
log_has "CREATE commander-needs-fix" && ok "creates commander-needs-fix" || bad "missing CREATE commander-needs-fix"

say "verdict=stuck -> add commander-stuck, no removals"
run tonychang04/hydra 501 stuck
[[ $EC -eq 0 ]] && ok "exit 0" || bad "expected exit 0, got $EC"
log_has "ADD commander-stuck" && ok "adds commander-stuck" || bad "missing ADD commander-stuck"

say "verdict=rejected -> add rejected, remove review/reviewed/review-clean"
run tonychang04/hydra 501 rejected
[[ $EC -eq 0 ]] && ok "exit 0" || bad "expected exit 0, got $EC"
log_has "ADD commander-rejected"        && ok "adds commander-rejected"        || bad "missing ADD commander-rejected"
log_has "DELETE commander-review"       && ok "removes commander-review"       || bad "missing DELETE commander-review"
log_has "DELETE commander-reviewed"     && ok "removes commander-reviewed"     || bad "missing DELETE commander-reviewed"
log_has "DELETE commander-review-clean" && ok "removes commander-review-clean" || bad "missing DELETE commander-review-clean"

say "idempotency: re-applying reviewed issues the same ADD and exits 0"
run tonychang04/hydra 501 reviewed
first_ec=$EC
run tonychang04/hydra 501 reviewed
[[ $EC -eq 0 && $first_ec -eq 0 ]] && ok "both runs exit 0" || bad "idempotent re-run not clean ($first_ec,$EC)"
log_has "ADD commander-reviewed" && ok "re-run still adds commander-reviewed (POST is a no-op server-side)" || bad "re-run missing ADD"

say "--dry-run mutates nothing (gh never invoked) and prints the plan"
run tonychang04/hydra 999 reviewed --dry-run
[[ $EC -eq 0 ]] && ok "exit 0" || bad "expected exit 0, got $EC"
[[ ! -s "$LOG" ]] && ok "mock log empty — gh NOT invoked" || bad "dry-run invoked gh: $(cat "$LOG")"
grep -qi 'dry-run' <<<"$OUT"           && ok "output notes dry-run"            || bad "no dry-run note in output"
grep -q 'commander-reviewed' <<<"$OUT" && ok "output names commander-reviewed" || bad "plan omits commander-reviewed"
grep -q 'commander-review' <<<"$OUT"   && ok "output names the removed label"  || bad "plan omits removed label"

say "REST failure on a required ADD -> exit 1"
: > "$LOG"
set +e
OUT="$(PATH="$stubdir:$PATH" GH_MOCK_LOG="$LOG" GH_MOCK_FAIL_ADD="commander-reviewed" NO_COLOR=1 bash "$APPLY" tonychang04/hydra 501 reviewed 2>&1)"
EC=$?
set -e
[[ $EC -eq 1 ]] && ok "exit 1 on REST failure" || bad "expected exit 1, got $EC"

say "usage errors -> exit 2"
run                                   ; [[ $EC -eq 2 ]] && ok "no args -> 2"        || bad "no args expected 2, got $EC"
run tonychang04/hydra 501             ; [[ $EC -eq 2 ]] && ok "missing verdict -> 2" || bad "missing verdict expected 2, got $EC"
run tonychang04/hydra 501 bogus       ; [[ $EC -eq 2 ]] && ok "bad verdict -> 2"     || bad "bad verdict expected 2, got $EC"
run nogit-slug 501 reviewed           ; [[ $EC -eq 2 ]] && ok "bad slug -> 2"        || bad "bad slug expected 2, got $EC"
run tonychang04/hydra notanumber reviewed ; [[ $EC -eq 2 ]] && ok "non-numeric pr -> 2" || bad "non-numeric pr expected 2, got $EC"

say "--help -> exit 0"
run --help ; [[ $EC -eq 0 ]] && ok "--help exits 0" || bad "--help expected 0, got $EC"

# ---------------------------------------------------------------------------
printf "\n${C_BOLD}apply-review-verdict: %d passed, %d failed${C_RESET}\n" "$passed" "$failed"
[[ $failed -eq 0 ]] || exit 1

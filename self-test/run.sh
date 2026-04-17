#!/usr/bin/env bash
#
# run.sh — execute golden-case regression harness for Hydra commander.
#
# Reads self-test/golden-cases.json if present, else self-test/golden-cases.example.json.
# Dispatches per case "kind":
#   - script:                 execute steps[].cmd; assert exit + optional stdout/stderr
#   - worker-implementation:  SKIP (requires Claude auth; future ticket)
#   - commander-inline:       SKIP (requires commander orchestration)
#   - commander-self:         SKIP (requires commander orchestration)
#
# Runs from worktree root — does NOT require cd. Always resolves paths relative to
# the repo that contains this script.
#
# Spec: docs/specs/2026-04-16-self-test-runner.md

set -euo pipefail

# -----------------------------------------------------------------------------
# resolve worktree root (script lives at <root>/self-test/run.sh)
# -----------------------------------------------------------------------------
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"

SELF_TEST_DIR="$ROOT_DIR/self-test"
GOLDEN_JSON="$SELF_TEST_DIR/golden-cases.json"
EXAMPLE_JSON="$SELF_TEST_DIR/golden-cases.example.json"
BUDGET_JSON="$ROOT_DIR/budget.json"

# -----------------------------------------------------------------------------
# color / TTY
# -----------------------------------------------------------------------------
if [[ -t 1 ]] && [[ "${NO_COLOR:-}" != "1" ]]; then
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
Usage: self-test/run.sh [options]

Executes golden-case regression harness. Reads self-test/golden-cases.json if
present, else self-test/golden-cases.example.json.

Options:
  --kind <k>          Filter by kind: script | commander-inline |
                      commander-self | worker-implementation |
                      worker-subagent | all (default: all)
  --case <id>         Run a single case by id (bypasses --kind filter)
  --cases-file <f>    Override cases JSON path (useful for meta-tests)
  --parallel          Run cases concurrently via xargs -P, bounded by
                      budget.json:phase1_subscription_caps.max_concurrent_workers
  --verbose           Print command stdout/stderr even on success
  -h, --help          Show this help

Exit codes:
  0   all cases passed or skipped
  1   one or more cases failed
  2   usage error / malformed input
EOF
}

# -----------------------------------------------------------------------------
# arg parsing
# -----------------------------------------------------------------------------
kind_filter="all"
case_id=""
parallel=0
verbose=0
cases_file=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --kind)
      [[ $# -ge 2 ]] || { echo "run.sh: --kind needs a value" >&2; usage >&2; exit 2; }
      kind_filter="$2"; shift 2
      ;;
    --kind=*)
      kind_filter="${1#--kind=}"; shift
      ;;
    --case)
      [[ $# -ge 2 ]] || { echo "run.sh: --case needs a value" >&2; usage >&2; exit 2; }
      case_id="$2"; shift 2
      ;;
    --case=*)
      case_id="${1#--case=}"; shift
      ;;
    --cases-file)
      [[ $# -ge 2 ]] || { echo "run.sh: --cases-file needs a value" >&2; usage >&2; exit 2; }
      cases_file="$2"; shift 2
      ;;
    --cases-file=*)
      cases_file="${1#--cases-file=}"; shift
      ;;
    --parallel)
      parallel=1; shift
      ;;
    --verbose)
      verbose=1; shift
      ;;
    -h|--help)
      usage; exit 0
      ;;
    --)
      shift; break
      ;;
    *)
      echo "run.sh: unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

case "$kind_filter" in
  all|script|commander-inline|commander-self|worker-implementation|worker-subagent) ;;
  *)
    echo "run.sh: invalid --kind: $kind_filter" >&2
    usage >&2
    exit 2
    ;;
esac

# -----------------------------------------------------------------------------
# select cases file
# -----------------------------------------------------------------------------
if [[ -n "$cases_file" ]]; then
  if [[ "$cases_file" != /* ]]; then
    cases_file="$ROOT_DIR/$cases_file"
  fi
  if [[ ! -f "$cases_file" ]]; then
    echo "run.sh: --cases-file not found: $cases_file" >&2
    exit 2
  fi
elif [[ -f "$GOLDEN_JSON" ]]; then
  cases_file="$GOLDEN_JSON"
else
  cases_file="$EXAMPLE_JSON"
fi

if [[ ! -f "$cases_file" ]]; then
  echo "run.sh: cases file not found: $cases_file" >&2
  exit 2
fi

if ! jq empty "$cases_file" 2>/dev/null; then
  echo "run.sh: malformed JSON: $cases_file" >&2
  exit 2
fi

# -----------------------------------------------------------------------------
# build the list of case ids (filtered by --kind / --case), skipping any
# that have id starting with "_" (comment rows) or no id at all. Kind is
# inferred from:
#   - explicit .kind field (wins)
#   - else .worker_type mapping: worker-implementation / commander-inline / commander-self
#   - else "script" if .steps is a non-empty array
#   - else "unknown"
# -----------------------------------------------------------------------------
all_ids=()
while IFS= read -r line; do
  [[ -z "$line" ]] && continue
  all_ids+=("$line")
done < <(
  jq -r \
    --arg kind "$kind_filter" \
    --arg case_id "$case_id" \
    '
    .cases // []
    | map(select(.id != null))
    | map(select((.id | startswith("_")) | not))
    | map(
        . + {
          _kind: (
            if .kind then .kind
            elif (.worker_type // null) == "worker-implementation" then "worker-implementation"
            elif (.worker_type // null) == "commander-inline" then "commander-inline"
            elif (.worker_type // null) == "commander-self" then "commander-self"
            elif ((.steps // []) | type == "array" and length > 0) then "script"
            else "unknown"
            end
          )
        }
      )
    | map(select(
        ($case_id == "" or .id == $case_id)
        and ($kind == "all" or ._kind == $kind)
      ))
    | .[] | .id
    ' "$cases_file"
)

if [[ ${#all_ids[@]} -eq 0 ]]; then
  if [[ -n "$case_id" ]]; then
    echo "run.sh: no case matching id=$case_id in $cases_file" >&2
    exit 2
  fi
  echo "run.sh: no cases matched kind=$kind_filter in $cases_file" >&2
  exit 2
fi

# -----------------------------------------------------------------------------
# parallel dispatch — spawn a fresh run.sh per case-id with bounded concurrency
# -----------------------------------------------------------------------------
if [[ "$parallel" -eq 1 ]] && [[ -z "$case_id" ]]; then
  max_workers=3
  if [[ -f "$BUDGET_JSON" ]]; then
    mw="$(jq -r '.phase1_subscription_caps.max_concurrent_workers // 3' "$BUDGET_JSON" 2>/dev/null || echo 3)"
    if [[ "$mw" =~ ^[0-9]+$ ]] && [[ "$mw" -ge 1 ]]; then
      max_workers="$mw"
    fi
  fi

  extra_args=()
  [[ "$kind_filter" != "all" ]] && extra_args+=("--kind=$kind_filter")
  [[ "$verbose" -eq 1 ]] && extra_args+=(--verbose)
  [[ -n "$cases_file" ]] && extra_args+=("--cases-file=$cases_file")

  echo "${C_BOLD}▸ Running self-test (${#all_ids[@]} cases, kind=$kind_filter, parallel=$max_workers)${C_RESET}"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

  tmpdir="$(mktemp -d)"
  trap 'rm -rf "$tmpdir"' EXIT

  start_epoch="$(date +%s)"

  # Launch each case in parallel, writing stdout + exit to tmpfiles.
  printf '%s\n' "${all_ids[@]}" \
    | xargs -P "$max_workers" -I {} bash -c '
        id="$1"; shift
        out="$1"; shift
        "$0" "$@" --case="$id" >"$out.stdout" 2>"$out.stderr"
        echo $? > "$out.exit"
      ' "$0" {} "$tmpdir/{}" "${extra_args[@]}"

  end_epoch="$(date +%s)"
  elapsed=$((end_epoch - start_epoch))

  passed=0; failed=0; skipped=0
  for id in "${all_ids[@]}"; do
    if [[ -f "$tmpdir/$id.stdout" ]]; then
      # Strip the header/footer lines each child emits — keep the per-case line.
      grep -E '^(✓|✗|∅) ' "$tmpdir/$id.stdout" || true
    fi
    ec="$(cat "$tmpdir/$id.exit" 2>/dev/null || echo 99)"
    case "$ec" in
      0)
        # Determine pass vs skip by scanning the child's output.
        if grep -q '^∅ ' "$tmpdir/$id.stdout" 2>/dev/null; then
          skipped=$((skipped + 1))
        else
          passed=$((passed + 1))
        fi
        ;;
      *)
        failed=$((failed + 1))
        if [[ -s "$tmpdir/$id.stderr" ]]; then
          echo "${C_DIM}--- stderr for $id ---${C_RESET}"
          cat "$tmpdir/$id.stderr"
        fi
        ;;
    esac
  done

  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "${passed} passed · ${failed} failed · ${skipped} skipped    (total ${elapsed}s)"

  [[ "$failed" -gt 0 ]] && exit 1
  exit 0
fi

# -----------------------------------------------------------------------------
# sequential (or single-case) execution
# -----------------------------------------------------------------------------
print_header=1
if [[ -n "$case_id" ]]; then
  # Single-case invocation: still print header/footer so the format is uniform,
  # but only if this is a top-level invocation, not a parallel child.
  # We detect parallel-child via the SELF_TEST_PARALLEL_CHILD env var.
  if [[ -n "${SELF_TEST_PARALLEL_CHILD:-}" ]]; then
    print_header=0
  fi
fi

if [[ "$print_header" -eq 1 ]]; then
  echo "${C_BOLD}▸ Running self-test (${#all_ids[@]} case$([[ ${#all_ids[@]} -ne 1 ]] && echo s), kind=$kind_filter)${C_RESET}"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
fi

passed=0; failed=0; skipped=0
overall_start="$(date +%s)"

# -----------------------------------------------------------------------------
# per-case runners
# -----------------------------------------------------------------------------
run_script_case() {
  # $1 = case-id, $2 = jq-extracted case JSON
  local id="$1" case_json="$2"
  local n_steps
  n_steps="$(jq -r '(.steps // []) | length' <<<"$case_json")"
  local case_start case_end elapsed
  case_start="$(date +%s)"

  local i=0
  local failed_step_idx="" failed_reason=""
  local step_stdout_all="" step_stderr_all=""

  local step_json
  while IFS= read -r step_json; do
    i=$((i + 1))
    local cmd expected_exit expected_stdout_jq expected_stderr_contains step_name
    cmd="$(jq -r '.cmd // empty' <<<"$step_json")"
    step_name="$(jq -r '.name // ""' <<<"$step_json")"
    expected_exit="$(jq -r '.expected_exit // 0' <<<"$step_json")"
    expected_stdout_jq="$(jq -r '.expected_stdout_jq // empty' <<<"$step_json")"
    expected_stderr_contains="$(jq -r '.expected_stderr_contains // empty' <<<"$step_json")"

    if [[ -z "$cmd" ]]; then
      failed_step_idx="$i"
      failed_reason="step $i missing 'cmd'"
      break
    fi

    # Execute from worktree root.
    local stdout_tmp stderr_tmp actual_exit
    stdout_tmp="$(mktemp)"
    stderr_tmp="$(mktemp)"
    set +e
    ( cd "$ROOT_DIR" && bash -c "$cmd" ) >"$stdout_tmp" 2>"$stderr_tmp"
    actual_exit=$?
    set -e

    if [[ "$verbose" -eq 1 ]]; then
      echo "  ${C_DIM}[$id #$i] $step_name${C_RESET}"
      echo "  ${C_DIM}\$ $cmd${C_RESET}"
      [[ -s "$stdout_tmp" ]] && sed 's/^/    /' "$stdout_tmp"
      [[ -s "$stderr_tmp" ]] && sed 's/^/    [stderr] /' "$stderr_tmp"
    fi

    # Check exit code.
    if [[ "$actual_exit" -ne "$expected_exit" ]]; then
      failed_step_idx="$i"
      failed_reason="step $i ($step_name): expected_exit=$expected_exit got $actual_exit"
      step_stdout_all="$(cat "$stdout_tmp")"
      step_stderr_all="$(cat "$stderr_tmp")"
      rm -f "$stdout_tmp" "$stderr_tmp"
      break
    fi

    # Check expected_stdout_jq.
    if [[ -n "$expected_stdout_jq" ]]; then
      if ! jq -e "$expected_stdout_jq" <"$stdout_tmp" >/dev/null 2>&1; then
        failed_step_idx="$i"
        failed_reason="step $i ($step_name): expected_stdout_jq '$expected_stdout_jq' did not hold"
        step_stdout_all="$(cat "$stdout_tmp")"
        step_stderr_all="$(cat "$stderr_tmp")"
        rm -f "$stdout_tmp" "$stderr_tmp"
        break
      fi
    fi

    # Check expected_stderr_contains.
    if [[ -n "$expected_stderr_contains" ]]; then
      if ! grep -Fq -- "$expected_stderr_contains" "$stderr_tmp"; then
        failed_step_idx="$i"
        failed_reason="step $i ($step_name): stderr did not contain '$expected_stderr_contains'"
        step_stdout_all="$(cat "$stdout_tmp")"
        step_stderr_all="$(cat "$stderr_tmp")"
        rm -f "$stdout_tmp" "$stderr_tmp"
        break
      fi
    fi

    rm -f "$stdout_tmp" "$stderr_tmp"
  done < <(jq -c '(.steps // [])[]' <<<"$case_json")

  case_end="$(date +%s)"
  elapsed=$((case_end - case_start))

  if [[ -z "$failed_step_idx" ]]; then
    echo "${C_GREEN}✓${C_RESET} ${id} (${n_steps} steps, ${elapsed}s)"
    return 0
  fi

  echo "${C_RED}✗${C_RESET} ${id} ${C_RED}FAIL${C_RESET} — ${failed_reason} (${elapsed}s)"
  if [[ "$verbose" -eq 1 ]] || [[ -n "$step_stdout_all$step_stderr_all" ]]; then
    if [[ -n "$step_stdout_all" ]]; then
      echo "  ${C_DIM}--- stdout ---${C_RESET}"
      sed 's/^/  /' <<<"$step_stdout_all"
    fi
    if [[ -n "$step_stderr_all" ]]; then
      echo "  ${C_DIM}--- stderr ---${C_RESET}"
      sed 's/^/  /' <<<"$step_stderr_all"
    fi
  fi
  return 1
}

run_skip_case() {
  # $1 = id, $2 = kind, $3 = reason
  local id="$1" _kind="$2" reason="$3"
  echo "${C_YELLOW}∅${C_RESET} ${id}  ${C_DIM}(SKIP: ${reason})${C_RESET}"
  return 0
}

# check_requires — returns 0 if all requires flags satisfied, else prints a
# reason on stdout and returns 1. Supported tokens:
#   requires_docker  — docker CLI + reachable daemon
#   requires_aws     — aws CLI available
# Unknown tokens are treated as satisfied (forward-compat — a case can declare
# a new requires token before the runner knows about it, without breaking CI).
check_requires() {
  local case_json="$1"
  local tokens
  tokens="$(jq -r '(.requires // []) | .[]' <<<"$case_json" 2>/dev/null || true)"
  [[ -z "$tokens" ]] && return 0

  local t
  while IFS= read -r t; do
    [[ -z "$t" ]] && continue
    case "$t" in
      requires_docker)
        if [[ "${HYDRA_CI_SKIP_DOCKER:-0}" == "1" ]]; then
          echo "requires_docker: HYDRA_CI_SKIP_DOCKER=1 set (CI fast-path)"
          return 1
        fi
        if ! command -v docker >/dev/null 2>&1; then
          echo "requires_docker: docker not on PATH"
          return 1
        fi
        if ! docker info >/dev/null 2>&1; then
          echo "requires_docker: docker daemon not reachable"
          return 1
        fi
        ;;
      requires_aws)
        if ! command -v aws >/dev/null 2>&1; then
          echo "requires_aws: aws CLI not on PATH"
          return 1
        fi
        ;;
      *)
        # Unknown token — assume satisfied (forward-compat).
        ;;
    esac
  done <<<"$tokens"
  return 0
}

# -----------------------------------------------------------------------------
# iterate cases (sequential)
# -----------------------------------------------------------------------------
for id in "${all_ids[@]}"; do
  case_json="$(
    jq -c --arg id "$id" '
      .cases // []
      | map(select(.id == $id))
      | .[0]
      | . + {
          _kind: (
            if .kind then .kind
            elif (.worker_type // null) == "worker-implementation" then "worker-implementation"
            elif (.worker_type // null) == "commander-inline" then "commander-inline"
            elif (.worker_type // null) == "commander-self" then "commander-self"
            elif ((.steps // []) | type == "array" and length > 0) then "script"
            else "unknown"
            end
          )
        }
    ' "$cases_file"
  )"

  case_kind="$(jq -r '._kind' <<<"$case_json")"

  case "$case_kind" in
    script)
      skip_reason="$(check_requires "$case_json" || true)"
      if [[ -n "$skip_reason" ]]; then
        run_skip_case "$id" "$case_kind" "$skip_reason"
        skipped=$((skipped + 1))
      elif run_script_case "$id" "$case_json"; then
        passed=$((passed + 1))
      else
        failed=$((failed + 1))
      fi
      ;;
    worker-implementation)
      run_skip_case "$id" "$case_kind" "requires Claude auth, not implemented in shell runner"
      skipped=$((skipped + 1))
      ;;
    worker-subagent)
      run_skip_case "$id" "$case_kind" "requires worker-test-discovery spawn; implement when worker-implementation SKIP path lands"
      skipped=$((skipped + 1))
      ;;
    commander-inline)
      run_skip_case "$id" "$case_kind" "requires commander orchestration"
      skipped=$((skipped + 1))
      ;;
    commander-self)
      run_skip_case "$id" "$case_kind" "requires commander orchestration"
      skipped=$((skipped + 1))
      ;;
    unknown|*)
      echo "${C_RED}✗${C_RESET} ${id} ${C_RED}FAIL${C_RESET} — could not infer kind (need .kind or .worker_type or .steps)"
      failed=$((failed + 1))
      ;;
  esac
done

overall_end="$(date +%s)"
total_elapsed=$((overall_end - overall_start))

if [[ "$print_header" -eq 1 ]]; then
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "${passed} passed · ${failed} failed · ${skipped} skipped    (total ${total_elapsed}s)"
fi

[[ "$failed" -gt 0 ]] && exit 1
exit 0

#!/usr/bin/env bash
#
# validate-state-all.sh — bulk-validate every known state/*.json file.
#
# Looks at state/schemas/*.schema.json and, for each schema X.schema.json,
# tries to validate state/X.json against it (or <state-dir>/X.json if the
# --state-dir flag is given). Missing state files are skipped with a note —
# not every install has every state file populated yet.
#
# Each file goes through scripts/validate-state.sh, so the bulk runner gets
# both validation paths (ajv strict when available; bash+jq minimal otherwise)
# for free.
#
# Design choice: we do NOT short-circuit on the first failure. Commander's
# preflight needs to see every broken state file in one pass, not just the
# first one. We collect failures and report them all at the end, exiting 1
# if any failed.
#
# Exit codes:
#   0   every state file passes (or is skipped because it doesn't exist yet)
#   1   one or more state files fail validation
#   2   usage error / schemas dir not found / --strict without ajv
#
# Spec: docs/specs/2026-04-16-state-schemas.md

set -euo pipefail

usage() {
  cat <<'EOF'
Usage: validate-state-all.sh [options]

Bulk-validates every state/*.json against its matching state/schemas/<name>.schema.json.

Options:
  --state-dir <dir>     Directory containing the state/*.json files
                        (default: state). Useful for testing against
                        fixture dirs in self-test.
  --schema-dir <dir>    Directory containing the *.schema.json files
                        (default: state/schemas).
  --strict              Require ajv-cli. Fail with exit 2 if ajv isn't
                        reachable. Without --strict, the script uses ajv
                        when available and falls back to bash+jq otherwise.
  -h, --help            Show this help.

Exit codes:
  0 = all valid (or missing) · 1 = at least one invalid · 2 = usage / setup error
EOF
}

# Resolve repo root so we don't depend on cwd.
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"

state_dir=""
schema_dir=""
strict=0
state_dir_overridden=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --state-dir)
      [[ $# -ge 2 ]] || { echo "validate-state-all: --state-dir needs a value" >&2; usage >&2; exit 2; }
      state_dir="$2"; state_dir_overridden=1; shift 2
      ;;
    --state-dir=*)
      state_dir="${1#--state-dir=}"; state_dir_overridden=1; shift
      ;;
    --schema-dir)
      [[ $# -ge 2 ]] || { echo "validate-state-all: --schema-dir needs a value" >&2; usage >&2; exit 2; }
      schema_dir="$2"; shift 2
      ;;
    --schema-dir=*)
      schema_dir="${1#--schema-dir=}"; shift
      ;;
    --strict)
      strict=1; shift
      ;;
    -h|--help)
      usage; exit 0
      ;;
    --)
      shift; break
      ;;
    *)
      echo "validate-state-all: unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

# Defaults (resolved against repo root so the script works from anywhere).
if [[ -z "$state_dir" ]]; then
  state_dir="$ROOT_DIR/state"
fi
if [[ -z "$schema_dir" ]]; then
  schema_dir="$ROOT_DIR/state/schemas"
fi

if [[ ! -d "$state_dir" ]]; then
  echo "✗ state-dir not found: $state_dir" >&2
  exit 2
fi
if [[ ! -d "$schema_dir" ]]; then
  echo "✗ schema-dir not found: $schema_dir" >&2
  exit 2
fi

# Build the list of schemas. If the dir is empty, that's a setup error.
shopt -s nullglob
schemas=( "$schema_dir"/*.schema.json )
shopt -u nullglob

if [[ ${#schemas[@]} -eq 0 ]]; then
  echo "✗ no schemas found in $schema_dir" >&2
  exit 2
fi

# Resolve which validator path the per-file runner will take. Same detection
# logic validate-state.sh uses: honor $HYDRA_AJV_CLI if it resolves, else `ajv`
# on PATH, else fall back to the bash+jq required-keys shim. We resolve it once
# here so the summary can report WHICH validator actually ran — ticket #249. A
# bash+jq fallback PASS must never be mistaken for a full Draft-07 strict pass:
# the fallback enforces only required top-level keys (no enums, no oneOf), so a
# schema-invalid file (e.g. an out-of-enum merge_policy) sails through it.
ajv_bin=""
if [[ -n "${HYDRA_AJV_CLI:-}" ]] && command -v "$HYDRA_AJV_CLI" >/dev/null 2>&1; then
  ajv_bin="$HYDRA_AJV_CLI"
elif command -v ajv >/dev/null 2>&1; then
  ajv_bin="ajv"
fi

# Human-readable label for the active path, used in the summary line.
if [[ -n "$ajv_bin" ]]; then
  validator_label="ajv strict"
else
  validator_label="bash+jq fallback"
fi

# --strict → enforce ajv presence up-front so the user gets one clear error,
# not one per file.
if [[ "$strict" -eq 1 ]] && [[ -z "$ajv_bin" ]]; then
  cat >&2 <<EOF
✗ --strict requested but ajv-cli not found.
Install with:
  npm install -g ajv-cli ajv-formats
Or set HYDRA_AJV_CLI to an explicit binary path.
EOF
  exit 2
fi

passed=0
skipped=0
failed_files=()

per_file_validator="$SCRIPT_DIR/validate-state.sh"
if [[ ! -x "$per_file_validator" ]]; then
  # Allow execution via bash even when the +x bit is missing.
  if [[ ! -f "$per_file_validator" ]]; then
    echo "✗ validate-state.sh not found next to validate-state-all.sh: $per_file_validator" >&2
    exit 2
  fi
fi

for schema_path in "${schemas[@]}"; do
  base="$(basename "$schema_path" .schema.json)"
  state_path="$state_dir/${base}.json"

  if [[ ! -f "$state_path" ]]; then
    echo "∅ $state_path (skip — file not present; nothing to validate yet)"
    skipped=$((skipped + 1))
    continue
  fi

  extra_args=()
  extra_args+=("--schema-dir" "$schema_dir")
  [[ "$strict" -eq 1 ]] && extra_args+=("--strict")

  # Run the per-file validator. Capture its output so we can format it
  # uniformly in the summary. Do NOT `set -e` around the call — a per-file
  # failure is a data point, not a fatal error.
  set +e
  bash "$per_file_validator" "${extra_args[@]}" "$state_path"
  ec=$?
  set -e

  case "$ec" in
    0)  passed=$((passed + 1)) ;;
    1)  failed_files+=("$state_path") ;;
    *)
        # Setup errors (2 and above) stop the run — the environment is broken,
        # not the state file. Surface loudly.
        echo "✗ validate-state.sh exited $ec on $state_path — aborting bulk run" >&2
        exit "$ec"
        ;;
  esac
done

# -----------------------------------------------------------------------------
# CLAUDE.md size guard — ticket #138 (binary guard), ticket #176 (graduated
# bands). Specs: docs/specs/2026-04-17-claudemd-size-guard.md,
# docs/specs/2026-05-20-claudemd-size-graduated-bands.md.
#
# The size check is part of preflight because CLAUDE.md is loaded into every
# Commander session and bloat silently degrades performance. We run it here
# rather than in a separate preflight step so one preflight call covers both
# state schemas and the CLAUDE.md budget. Same exit-code semantics as the
# per-file validator: 0 = under budget, 1 = over budget, 2+ = setup error.
#
# ADVISORY-ONLY INVARIANT (do not "fix" into a gate): the size check now emits
# NOTICE and WARN advisory bands as CLAUDE.md approaches the ceiling, but those
# bands return exit 0 — preflight stays GREEN. Their advisory text prints to the
# size check's stdout, which flows through here unsuppressed so the operator sees
# it inline. Only exit 1 (size > max) counts as a failure. NOTICE/WARN must NOT
# block spawns; that is the entire point of ticket #176.
#
# If CLAUDE.md isn't present (downstream repos borrowing the bulk runner
# against their own state-dir), the check skips gracefully.
# -----------------------------------------------------------------------------
size_check="$SCRIPT_DIR/check-claude-md-size.sh"
claude_md_path="$ROOT_DIR/CLAUDE.md"
if [[ ! -f "$claude_md_path" ]]; then
  echo "∅ $claude_md_path (skip — CLAUDE.md not present; nothing to size-check)"
  skipped=$((skipped + 1))
elif [[ ! -f "$size_check" ]]; then
  echo "∅ check-claude-md-size.sh (skip — helper script not found at $size_check)"
  skipped=$((skipped + 1))
else
  set +e
  bash "$size_check" --path "$claude_md_path"
  ec=$?
  set -e
  case "$ec" in
    0)  passed=$((passed + 1)) ;;
    1)  failed_files+=("$claude_md_path (over budget)") ;;
    *)
        echo "✗ check-claude-md-size.sh exited $ec on $claude_md_path — aborting bulk run" >&2
        exit "$ec"
        ;;
  esac
fi

# -----------------------------------------------------------------------------
# self-test assertion-count baseline guard — ticket #118.
# Spec: docs/specs/2026-06-01-self-test-baseline-guard.md.
#
# Refuses a PR that drops net executable self-test assertions below the
# committed floor (self-test/baseline.json) — the regression detector that
# would have caught #118's silent "0 cases executing".
#
# GATED behind HYDRA_SELFTEST_BASELINE_GATE=1 because the guard runs the
# ~90s script-kind harness. Every `pick up` preflight should stay fast, so the
# default path SKIPs this; the merge/review gate and CI set the flag to enforce
# it where merges are actually decided. Exit-code semantics mirror the size
# guard: 0 = OK, 1 = regression (collected as a failure), other = abort.
#
# RECURSION GUARD (two independent defenses): the baseline guard runs
# `self-test/run.sh --kind=script`, which executes EVERY script golden case —
# including `state-schemas`, which itself shells out to this very script
# (`validate-state-all.sh --state-dir <fixture>`). Because the gate flag is an
# *exported* env var, a naive gate would re-fire inside that nested invocation,
# which re-runs the harness, which re-runs the nested case … an unbounded fork
# explosion. We block that two ways, either of which is sufficient:
#   (1) skip the gate whenever --state-dir was overridden — a fixture/self-test
#       sub-run has no real `state/` coverage to gate, so the gate is meaningless
#       there; AND
#   (2) export HYDRA_SELFTEST_BASELINE_GATE_ACTIVE=1 around the guard call and
#       skip if it's already set — so any nested validate-state-all (however
#       invoked) sees the in-progress marker and declines to re-enter.
# -----------------------------------------------------------------------------
baseline_check="$SCRIPT_DIR/check-self-test-baseline.sh"
baseline_json="$ROOT_DIR/self-test/baseline.json"
if [[ "${HYDRA_SELFTEST_BASELINE_GATE:-0}" != "1" ]]; then
  echo "∅ check-self-test-baseline.sh (skip — set HYDRA_SELFTEST_BASELINE_GATE=1 to enforce; ~90s harness run)"
  skipped=$((skipped + 1))
elif [[ "${HYDRA_SELFTEST_BASELINE_GATE_ACTIVE:-0}" == "1" ]]; then
  echo "∅ check-self-test-baseline.sh (skip — already inside a baseline-gate harness run; recursion guard)"
  skipped=$((skipped + 1))
elif [[ "$state_dir_overridden" -eq 1 ]]; then
  echo "∅ check-self-test-baseline.sh (skip — --state-dir override; gate applies only to the real state/ preflight)"
  skipped=$((skipped + 1))
elif [[ ! -f "$baseline_json" ]]; then
  echo "∅ $baseline_json (skip — self-test baseline not present)"
  skipped=$((skipped + 1))
elif [[ ! -f "$baseline_check" ]]; then
  echo "∅ check-self-test-baseline.sh (skip — helper script not found at $baseline_check)"
  skipped=$((skipped + 1))
else
  set +e
  HYDRA_SELFTEST_BASELINE_GATE_ACTIVE=1 bash "$baseline_check"
  ec=$?
  set -e
  case "$ec" in
    0)  passed=$((passed + 1)) ;;
    1)  failed_files+=("self-test coverage (below baseline)") ;;
    *)
        echo "✗ check-self-test-baseline.sh exited $ec — aborting bulk run" >&2
        exit "$ec"
        ;;
  esac
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Ticket #249: surface which validator ran so a weak fallback pass is never
# mistaken for a full Draft-07 strict pass. When the fallback ran, warn loudly
# that enums/oneOf were NOT enforced and point at the fix.
if [[ "$validator_label" == "bash+jq fallback" ]]; then
  echo "validate-state-all: WARN — ran bash+jq fallback (enums/oneOf NOT enforced). Install ajv-cli for full Draft-07 validation: npm install -g ajv-cli ajv-formats" >&2
fi

if [[ ${#failed_files[@]} -eq 0 ]]; then
  echo "validate-state-all: OK ($passed passed, $skipped skipped) [validator: $validator_label]"
  exit 0
fi

echo "validate-state-all: FAIL ($passed passed, ${#failed_files[@]} failed, $skipped skipped) [validator: $validator_label]" >&2
for f in "${failed_files[@]}"; do
  echo "  ✗ $f" >&2
done
exit 1

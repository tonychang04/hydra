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

while [[ $# -gt 0 ]]; do
  case "$1" in
    --state-dir)
      [[ $# -ge 2 ]] || { echo "validate-state-all: --state-dir needs a value" >&2; usage >&2; exit 2; }
      state_dir="$2"; shift 2
      ;;
    --state-dir=*)
      state_dir="${1#--state-dir=}"; shift
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

# --strict → enforce ajv presence up-front so the user gets one clear error,
# not one per file.
if [[ "$strict" -eq 1 ]]; then
  ajv_bin=""
  if [[ -n "${HYDRA_AJV_CLI:-}" ]] && command -v "$HYDRA_AJV_CLI" >/dev/null 2>&1; then
    ajv_bin="$HYDRA_AJV_CLI"
  elif command -v ajv >/dev/null 2>&1; then
    ajv_bin="ajv"
  fi
  if [[ -z "$ajv_bin" ]]; then
    cat >&2 <<EOF
✗ --strict requested but ajv-cli not found.
Install with:
  npm install -g ajv-cli ajv-formats
Or set HYDRA_AJV_CLI to an explicit binary path.
EOF
    exit 2
  fi
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

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
if [[ ${#failed_files[@]} -eq 0 ]]; then
  echo "validate-state-all: OK ($passed passed, $skipped skipped)"
  exit 0
fi

echo "validate-state-all: FAIL ($passed passed, ${#failed_files[@]} failed, $skipped skipped)" >&2
for f in "${failed_files[@]}"; do
  echo "  ✗ $f" >&2
done
exit 1

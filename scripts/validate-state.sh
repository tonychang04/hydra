#!/usr/bin/env bash
#
# validate-state.sh — validate a state/*.json file against its schema.
#
# Two validation paths:
#   1. Strict (preferred): delegates to ajv-cli when it's available. Full
#      JSON Schema Draft-07 validation — types, enums, patterns, minimum,
#      etc. Activated automatically when `ajv` is on PATH (or
#      $HYDRA_AJV_CLI points at a specific binary). Can be forced with
#      --strict, which hard-fails if ajv isn't reachable.
#   2. Minimal (fallback): bash + jq check for JSON validity + required
#      top-level keys. Runs when ajv isn't available. Keeps the validator
#      useful on any fresh clone where Node tooling isn't installed.
#
# Auto-detects which schema to apply from the filename:
#   state/active.json          → state/schemas/active.schema.json
#   state/budget-used.json     → state/schemas/budget-used.schema.json
#   state/repos.json           → state/schemas/repos.schema.json
#   state/autopickup.json      → state/schemas/autopickup.schema.json
#   state/memory-citations.json → state/schemas/memory-citations.schema.json
#
# Override the auto-detected schema with --schema <file> or --schema-dir <dir>
# (the latter looks up <base>.schema.json inside <dir>). Used by the self-test
# harness to point at schemas without duplicating them into fixture dirs.
#
# Exit codes:
#   0   validation passed
#   1   validation failed (file does not match schema)
#   2   usage error / schema not found / JSON malformed / --strict without ajv
#
# Spec: docs/specs/2026-04-16-state-schemas.md

set -euo pipefail

usage() {
  cat <<'EOF'
Usage: validate-state.sh [--schema <file> | --schema-dir <dir>] [--strict] <state-file>

Validates a state/*.json file against its schema in state/schemas/.

Options:
  --schema <file>       Explicit schema path (overrides auto-detection).
  --schema-dir <dir>    Look up schema as <dir>/<base>.schema.json.
  --strict              Require ajv-cli. Fail with exit 2 if ajv isn't reachable.
                        Without --strict, the script uses ajv when available
                        and falls back to a minimal bash+jq check otherwise.
  -h, --help            Show this help.

Exit codes:
  0 = valid · 1 = invalid · 2 = usage / input error / --strict without ajv
EOF
}

schema_override=""
schema_dir_override=""
strict=0
state_file=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --schema)
      [[ $# -ge 2 ]] || { echo "validate-state: --schema needs a value" >&2; usage >&2; exit 2; }
      schema_override="$2"; shift 2
      ;;
    --schema=*)
      schema_override="${1#--schema=}"; shift
      ;;
    --schema-dir)
      [[ $# -ge 2 ]] || { echo "validate-state: --schema-dir needs a value" >&2; usage >&2; exit 2; }
      schema_dir_override="$2"; shift 2
      ;;
    --schema-dir=*)
      schema_dir_override="${1#--schema-dir=}"; shift
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
    -*)
      echo "validate-state: unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
    *)
      if [[ -n "$state_file" ]]; then
        echo "validate-state: only one state-file argument allowed" >&2
        exit 2
      fi
      state_file="$1"; shift
      ;;
  esac
done

if [[ -z "$state_file" ]]; then
  echo "validate-state: missing <state-file>" >&2
  usage >&2
  exit 2
fi

[[ -f "$state_file" ]] || { echo "✗ $state_file not found" >&2; exit 2; }

# Resolve schema path.
if [[ -n "$schema_override" ]]; then
  schema_file="$schema_override"
else
  base="$(basename "$state_file" .json)"
  if [[ -n "$schema_dir_override" ]]; then
    schema_file="$schema_dir_override/${base}.schema.json"
  else
    schema_file="$(dirname "$state_file")/schemas/${base}.schema.json"
  fi
fi
[[ -f "$schema_file" ]] || { echo "✗ schema $schema_file not found" >&2; exit 2; }

# JSON validity (both files) — always run, regardless of validator path.
jq empty "$state_file" 2>/dev/null || { echo "✗ $state_file is not valid JSON" >&2; exit 1; }
jq empty "$schema_file" 2>/dev/null || { echo "✗ $schema_file is not valid JSON" >&2; exit 2; }

# Resolve ajv-cli binary if available.
ajv_bin=""
if [[ -n "${HYDRA_AJV_CLI:-}" ]] && command -v "$HYDRA_AJV_CLI" >/dev/null 2>&1; then
  ajv_bin="$HYDRA_AJV_CLI"
elif command -v ajv >/dev/null 2>&1; then
  ajv_bin="ajv"
fi

if [[ "$strict" -eq 1 ]] && [[ -z "$ajv_bin" ]]; then
  cat >&2 <<EOF
✗ --strict requested but ajv-cli not found.
Install with:
  npm install -g ajv-cli ajv-formats
Or set HYDRA_AJV_CLI to an explicit binary path.
EOF
  exit 2
fi

# ----- Strict path: delegate to ajv-cli -----
if [[ -n "$ajv_bin" ]]; then
  # --spec=draft7 pins the dialect (ajv-cli v5 defaults to draft-2020-12).
  # --strict=false lets ajv tolerate $id / $schema keywords without flagging
  # them as unknown. We don't want ajv to reject our schemas for using stable
  # metadata keywords.
  if "$ajv_bin" validate -s "$schema_file" -d "$state_file" \
       --spec=draft7 --strict=false >/dev/null 2>/tmp/ajv.err.$$; then
    rm -f "/tmp/ajv.err.$$"
    echo "✓ $state_file passes strict (ajv) validation against $schema_file"
    exit 0
  fi
  echo "✗ $state_file failed strict (ajv) validation against $schema_file" >&2
  sed 's/^/  /' "/tmp/ajv.err.$$" >&2 || true
  rm -f "/tmp/ajv.err.$$"
  exit 1
fi

# ----- Fallback path: bash+jq required-keys check -----
# Use `has(...)` (not `.key`) so keys with falsy values (false / null / 0)
# still register as present — jq -e '.key' exits 1 on falsy values even when
# the key is set, which is the wrong behaviour for a presence check.
required=$(jq -r '.required // [] | .[]' "$schema_file")
missing=()
for key in $required; do
  jq -e --arg k "$key" 'has($k)' "$state_file" >/dev/null 2>&1 || missing+=("$key")
done

if [[ ${#missing[@]} -gt 0 ]]; then
  echo "✗ $state_file missing required keys: ${missing[*]}" >&2
  exit 1
fi

echo "✓ $state_file passes minimal validation against $schema_file"

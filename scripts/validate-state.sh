#!/usr/bin/env bash
# validate-state.sh — validate a state/*.json file against its schema.
# Minimal bash+jq implementation. Full ajv-cli support is a follow-up.
# Usage:  scripts/validate-state.sh <state-file>
#         scripts/validate-state.sh state/active.json
set -euo pipefail

usage() {
  cat <<EOF
Usage: $0 <state-file>

Validates a state/*.json file against its schema in state/schemas/.
Auto-detects which schema to apply from the filename:
  state/active.json          → state/schemas/active.schema.json
  state/budget-used.json     → state/schemas/budget-used.schema.json
  state/repos.json           → state/schemas/repos.schema.json
  state/autopickup.json      → state/schemas/autopickup.schema.json
  state/memory-citations.json → state/schemas/memory-citations.schema.json

Minimal validation today: JSON validity + required top-level keys via jq.
Full JSON Schema validation is a follow-up (requires ajv-cli as optional dep).
EOF
}

[[ $# -ne 1 || "${1:-}" == "-h" || "${1:-}" == "--help" ]] && { usage; exit 1; }

state_file="$1"
[[ -f "$state_file" ]] || { echo "✗ $state_file not found" >&2; exit 2; }

# Derive schema name from state file basename (active.json → active.schema.json)
base="$(basename "$state_file" .json)"
schema_file="$(dirname "$state_file")/schemas/${base}.schema.json"
[[ -f "$schema_file" ]] || { echo "✗ schema $schema_file not found" >&2; exit 2; }

# JSON validity
jq empty "$state_file" 2>/dev/null || { echo "✗ $state_file is not valid JSON" >&2; exit 1; }
jq empty "$schema_file" 2>/dev/null || { echo "✗ $schema_file is not valid JSON" >&2; exit 1; }

# Required top-level keys from schema
required=$(jq -r '.required // [] | .[]' "$schema_file")
missing=()
for key in $required; do
  jq -e ".\"$key\"" "$state_file" > /dev/null 2>&1 || missing+=("$key")
done

if [[ ${#missing[@]} -gt 0 ]]; then
  echo "✗ $state_file missing required keys: ${missing[*]}" >&2
  exit 1
fi

echo "✓ $state_file passes minimal validation against $schema_file"

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
Usage: validate-state.sh [--schema <file> | --schema-dir <dir>] [--strict] [--migrate] <state-file>

Validates a state/*.json file against its schema in state/schemas/.

Options:
  --schema <file>       Explicit schema path (overrides auto-detection).
  --schema-dir <dir>    Look up schema as <dir>/<base>.schema.json.
  --strict              Require ajv-cli. Fail with exit 2 if ajv isn't reachable.
                        Without --strict, the script uses ajv when available
                        and falls back to a minimal bash+jq check otherwise.
  --migrate             Repair-then-validate. Before validating, apply known-safe,
                        documented-default repairs to <state-file> IN PLACE (atomic
                        write), report each repair, then validate the result. The
                        remediation for a schema tightening that rejects valid-by-docs
                        pre-existing state. WRITES the file; plain validation never
                        does. Idempotent. Repairs (only these — never invents values
                        for arbitrary missing keys):
                          repos.json            backfill repos[].ticket_trigger with
                                                default_ticket_trigger // "assignee"
                          memory-citations.json coerce citations[].tickets[] numbers
                                                to strings (191 -> "191")
  -h, --help            Show this help.

Exit codes:
  0 = valid · 1 = invalid · 2 = usage / input error / --strict without ajv
EOF
}

schema_override=""
schema_dir_override=""
strict=0
migrate=0
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
    --migrate)
      migrate=1; shift
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

# -----------------------------------------------------------------------------
# --migrate: repair-then-validate. Apply known-safe, documented-default repairs
# to <state-file> IN PLACE, report each one, then fall through to validation.
#
# Why a flag and not a separate script: keeps "validate fails -> re-run with
# --migrate" one tool, one mental model. Why opt-in + write-on-purpose: plain
# validation must stay read-only (preflight runs it every tick). The repairs are
# narrow on purpose — only drift classes with a *documented* correct value
# (#260). Anything else still fails validation loudly; --migrate never papers
# over a genuinely malformed file. Pure jq, atomic write, idempotent.
# Spec: docs/specs/2026-06-08-state-validation-migration.md
# -----------------------------------------------------------------------------
if [[ "$migrate" -eq 1 ]]; then
  state_base="$(basename "$state_file" .json)"
  migrate_filter=""
  case "$state_base" in
    repos)
      # Backfill repos[].ticket_trigger with the documented default: the file's
      # own default_ticket_trigger if present, else "assignee" — exactly the
      # `(.ticket_trigger // $dt)` / `// "assignee"` logic every consumer uses.
      migrate_filter='
        (.default_ticket_trigger // "assignee") as $dt
        | .repos = ((.repos // []) | map(
            if (type == "object") and (has("ticket_trigger") | not)
            then . + {ticket_trigger: $dt}
            else .
            end))
      '
      ;;
    memory-citations)
      # Coerce numeric tickets[] elements to strings (191 -> "191"). Strings are
      # left untouched, so the transform is idempotent.
      migrate_filter='
        .citations = ((.citations // {}) | with_entries(
          if (.value | type) == "object" and (.value | has("tickets"))
          then .value.tickets = ((.value.tickets // []) | map(
                 if type == "number" then tostring else . end))
          else .
          end))
      '
      ;;
    *)
      echo "validate-state: --migrate has no repairs for '$state_base' (only repos / memory-citations); validating as-is" >&2
      ;;
  esac

  if [[ -n "$migrate_filter" ]]; then
    migrated_tmp="$(mktemp "${TMPDIR:-/tmp}/validate-state.migrate.XXXXXX")"
    # shellcheck disable=SC2064
    trap 'rm -f "$migrated_tmp"' EXIT
    if ! jq "$migrate_filter" "$state_file" > "$migrated_tmp" 2>/tmp/migrate.err.$$; then
      echo "✗ --migrate failed to transform $state_file" >&2
      sed 's/^/  /' "/tmp/migrate.err.$$" >&2 || true
      rm -f "/tmp/migrate.err.$$"
      exit 2
    fi
    rm -f "/tmp/migrate.err.$$"

    # Report repairs by diffing the canonicalized before/after, and only write
    # when something actually changed (keeps mtime stable on no-op runs).
    before_canon="$(jq -S . "$state_file")"
    after_canon="$(jq -S . "$migrated_tmp")"
    if [[ "$before_canon" == "$after_canon" ]]; then
      echo "• --migrate: no repairs needed for $state_file (already conforms to documented defaults)"
    else
      case "$state_base" in
        repos)
          n="$(jq '[.repos[]? | select(has("ticket_trigger") | not)] | length' "$state_file")"
          echo "• --migrate: backfilled ticket_trigger on $n repos entr$([[ "$n" == "1" ]] && echo y || echo ies) in $state_file"
          ;;
        memory-citations)
          n="$(jq '[.citations[]?.tickets[]? | select(type=="number")] | length' "$state_file")"
          echo "• --migrate: coerced $n numeric tickets[] element$([[ "$n" == "1" ]] && echo "" || echo s) to strings in $state_file"
          ;;
      esac
      # Atomic in-place write: cp the temp content over (preserve target inode is
      # not required; mv across same dir is atomic). Use cat>tmp2;mv to stay on
      # the target's filesystem so mv is a rename, not a cross-device copy.
      dest_dir="$(dirname "$state_file")"
      final_tmp="$(mktemp "$dest_dir/.validate-state.migrate.XXXXXX")"
      cat "$migrated_tmp" > "$final_tmp"
      mv "$final_tmp" "$state_file"
      echo "• --migrate: wrote repaired $state_file"
    fi
    rm -f "$migrated_tmp"
    trap - EXIT
  fi
fi

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

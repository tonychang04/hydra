#!/usr/bin/env bash
#
# syntax-check.sh — syntax + structural lint for the Hydra repo.
#
# Runs three checks; any failure fails the CI job:
#   1. bash -n on every shell script under setup.sh, install.sh,
#      scripts/*.sh, self-test/*.sh, self-test/fixtures/**/*.sh,
#      infra/*.sh (if present), .github/workflows/scripts/*.sh
#   2. jq empty on every known JSON-or-JSON-example file
#   3. Required frontmatter (status + date) on docs/specs/*.md
#
# Fast by design: all checks are offline, no network, no docker.
#
# Spec: docs/specs/2026-04-16-ci.md (ticket #16 / T2)

set -euo pipefail

# Resolve repo root (script lives at .github/workflows/scripts/syntax-check.sh).
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/../../.." && pwd)"
cd "$REPO_ROOT"

fail=0

# -----------------------------------------------------------------------------
# 1. bash -n on shell scripts
# -----------------------------------------------------------------------------
echo "==> bash -n on shell scripts"

shell_targets=()
for candidate in setup.sh install.sh; do
  [[ -f "$candidate" ]] && shell_targets+=("$candidate")
done
# Glob-expand; if no matches, the pattern is harmlessly kept by nullglob off.
shopt -s nullglob
for pattern in \
  scripts/*.sh \
  self-test/*.sh \
  self-test/fixtures/**/*.sh \
  infra/*.sh \
  .github/workflows/scripts/*.sh
do
  for f in $pattern; do
    shell_targets+=("$f")
  done
done
shopt -u nullglob

if [[ ${#shell_targets[@]} -eq 0 ]]; then
  echo "  (no shell targets found — nothing to check)"
else
  for f in "${shell_targets[@]}"; do
    if bash -n "$f" 2>/tmp/bash-n-err; then
      echo "  ok   $f"
    else
      echo "  FAIL $f"
      sed 's/^/       /' /tmp/bash-n-err
      fail=1
    fi
  done
fi

# -----------------------------------------------------------------------------
# 2. jq empty on JSON (and .example.json) files
# -----------------------------------------------------------------------------
echo "==> jq empty on JSON files"

json_targets=()
shopt -s nullglob
for pattern in \
  state/*.example.json \
  state/*.json \
  state/schemas/*.json \
  self-test/golden-cases.example.json \
  self-test/golden-cases.json \
  mcp/hydra-tools.json \
  mcp/*.json \
  docs/specs/*.json \
  budget.json
do
  for f in $pattern; do
    # Skip gitignored runtime state files if they somehow got picked up —
    # budget.json is committed; state/*.json (non-example) usually aren't.
    [[ -f "$f" ]] && json_targets+=("$f")
  done
done
shopt -u nullglob

if [[ ${#json_targets[@]} -eq 0 ]]; then
  echo "  (no JSON targets found — nothing to check)"
else
  # Dedupe (portable — avoids mapfile for macOS bash 3.2 compatibility).
  deduped=()
  while IFS= read -r line; do
    deduped+=("$line")
  done < <(printf '%s\n' "${json_targets[@]}" | sort -u)
  json_targets=("${deduped[@]}")
  for f in "${json_targets[@]}"; do
    if jq empty "$f" 2>/tmp/jq-err; then
      echo "  ok   $f"
    else
      echo "  FAIL $f"
      sed 's/^/       /' /tmp/jq-err
      fail=1
    fi
  done
fi

# -----------------------------------------------------------------------------
# 3. docs/specs/*.md — light frontmatter check
# -----------------------------------------------------------------------------
echo "==> Frontmatter on docs/specs/*.md (status + date)"

spec_targets=()
shopt -s nullglob
for f in docs/specs/*.md; do
  # README and TEMPLATE sit in the same directory but aren't specs.
  base="$(basename "$f")"
  [[ "$base" == "README.md" ]] && continue
  [[ "$base" == "TEMPLATE.md" ]] && continue
  spec_targets+=("$f")
done
shopt -u nullglob

if [[ ${#spec_targets[@]} -eq 0 ]]; then
  echo "  (no specs found — nothing to check)"
else
  for f in "${spec_targets[@]}"; do
    # A valid spec starts with `---`, contains `status:` and `date:` inside the
    # first frontmatter block, and closes with `---`.
    first_line="$(head -n 1 "$f" || true)"
    if [[ "$first_line" != "---" ]]; then
      echo "  FAIL $f (missing opening --- frontmatter marker)"
      fail=1
      continue
    fi
    # Extract frontmatter (between first --- and the next ---).
    fm="$(awk 'NR==1 && /^---$/ {inside=1; next} inside && /^---$/ {exit} inside' "$f")"
    missing=()
    grep -qE '^status:[[:space:]]*[^[:space:]]' <<<"$fm" || missing+=("status")
    grep -qE '^date:[[:space:]]*[^[:space:]]' <<<"$fm" || missing+=("date")
    if [[ ${#missing[@]} -gt 0 ]]; then
      echo "  FAIL $f (frontmatter missing: ${missing[*]})"
      fail=1
    else
      echo "  ok   $f"
    fi
  done
fi

# -----------------------------------------------------------------------------
# summary
# -----------------------------------------------------------------------------
echo
if [[ "$fail" -ne 0 ]]; then
  echo "syntax-check: FAIL"
  exit 1
fi
echo "syntax-check: OK"

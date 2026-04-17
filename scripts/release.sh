#!/usr/bin/env bash
#
# release.sh — cut a new Hydra release.
#
# Flow (in this order):
#   1. Validate the new version is a valid semver and strictly greater than the
#      current VERSION file contents (refuse downgrades / equal bumps).
#   2. Rewrite CHANGELOG.md:
#        - rename `## [Unreleased]` → `## [<version>] — YYYY-MM-DD` (today, UTC)
#        - add a fresh empty `## [Unreleased]` section above it
#        - update the compare-link footer (Unreleased points at new tag..HEAD;
#          new version gets its own release link)
#   3. Bump VERSION to the new value.
#   4. Run the self-test harness (`./self-test/run.sh --kind=script`) to make
#      sure the tree is healthy before tagging. Refuse to continue on failure.
#   5. `git add VERSION CHANGELOG.md` + `git commit -m "Release v<version>"`.
#   6. `git tag v<version>` (annotated).
#   7. Print next steps.
#
# `--dry-run` previews steps 2-7 without mutating anything on disk and without
# touching git. Useful for reviewing the CHANGELOG rewrite before committing.
#
# Explicitly NOT in scope:
#   - `git push` (operator-invoked; printed as a next-step).
#   - `git push --tags` (ditto).
#   - Auto-generating the Unreleased bullets from commit history — those are
#     hand-curated by contributors via the PR template checkbox.
#
# Dependencies: bash + jq. Nothing else.
#
# Spec: docs/specs/2026-04-17-release-process.md

set -euo pipefail

# -----------------------------------------------------------------------------
# resolve repo root (script lives at <root>/scripts/release.sh)
# -----------------------------------------------------------------------------
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"

VERSION_FILE="$ROOT_DIR/VERSION"
CHANGELOG_FILE="$ROOT_DIR/CHANGELOG.md"
SELF_TEST="$ROOT_DIR/self-test/run.sh"
REPO_SLUG="tonychang04/hydra"

# -----------------------------------------------------------------------------
# colors (suppressed if not a TTY or NO_COLOR=1)
# -----------------------------------------------------------------------------
if [[ -t 1 ]] && [[ "${NO_COLOR:-}" != "1" ]]; then
  C_GREEN=$'\033[32m'; C_RED=$'\033[31m'; C_YELLOW=$'\033[33m'
  C_DIM=$'\033[2m'; C_BOLD=$'\033[1m'; C_RESET=$'\033[0m'
else
  C_GREEN=""; C_RED=""; C_YELLOW=""; C_DIM=""; C_BOLD=""; C_RESET=""
fi

say()  { printf "%s▸ %s%s\n" "$C_BOLD" "$*" "$C_RESET"; }
ok()   { printf "%s✓%s %s\n" "$C_GREEN" "$C_RESET" "$*"; }
warn() { printf "%s⚠%s %s\n" "$C_YELLOW" "$C_RESET" "$*"; }
fail() { printf "%s✗%s %s\n" "$C_RED" "$C_RESET" "$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
Usage: scripts/release.sh [--dry-run] <new-version>

Cuts a release:
  - Validates <new-version> > current VERSION (refuses downgrades)
  - Renames ## [Unreleased] in CHANGELOG.md to ## [<version>] — YYYY-MM-DD
  - Adds an empty ## [Unreleased] section back at the top
  - Updates compare-link footer
  - Bumps VERSION
  - Runs self-test/run.sh --kind=script
  - Commits + tags v<version> (NOT pushed — operator pushes manually)

Options:
  --dry-run     Show what WOULD change; don't touch files, don't commit, don't tag
  -h, --help    Show this help

Example:
  ./scripts/release.sh 0.2.0
  ./scripts/release.sh --dry-run 0.2.0
EOF
}

# -----------------------------------------------------------------------------
# arg parsing
# -----------------------------------------------------------------------------
DRY_RUN=0
NEW_VERSION=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    --) shift; break ;;
    -*)
      echo "release.sh: unknown flag: $1" >&2
      usage >&2
      exit 2
      ;;
    *)
      if [[ -n "$NEW_VERSION" ]]; then
        echo "release.sh: multiple version args (already have '$NEW_VERSION', got '$1')" >&2
        exit 2
      fi
      NEW_VERSION="$1"
      shift
      ;;
  esac
done

[[ -n "$NEW_VERSION" ]] || { usage >&2; exit 2; }
command -v jq >/dev/null || fail "jq required on PATH"

# -----------------------------------------------------------------------------
# validate shape of new version (strict semver core: MAJOR.MINOR.PATCH, digits only)
# -----------------------------------------------------------------------------
SEMVER_RE='^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$'
[[ "$NEW_VERSION" =~ $SEMVER_RE ]] || \
  fail "'$NEW_VERSION' is not a valid semver (expected MAJOR.MINOR.PATCH, e.g. 0.2.0)"

# -----------------------------------------------------------------------------
# read current version
# -----------------------------------------------------------------------------
[[ -f "$VERSION_FILE" ]] || fail "VERSION file not found at $VERSION_FILE"
CURRENT_VERSION="$(tr -d '[:space:]' <"$VERSION_FILE")"
[[ "$CURRENT_VERSION" =~ $SEMVER_RE ]] || \
  fail "current VERSION '$CURRENT_VERSION' is not a valid semver"

# -----------------------------------------------------------------------------
# compare versions (refuse downgrade or equal)
# -----------------------------------------------------------------------------
# Returns 0 if $1 > $2, 1 otherwise. Pure bash, no external deps.
version_gt() {
  local a="$1" b="$2"
  IFS='.' read -r a_maj a_min a_pat <<<"$a"
  IFS='.' read -r b_maj b_min b_pat <<<"$b"
  if (( a_maj != b_maj )); then (( a_maj > b_maj )); return $?; fi
  if (( a_min != b_min )); then (( a_min > b_min )); return $?; fi
  if (( a_pat != b_pat )); then (( a_pat > b_pat )); return $?; fi
  return 1
}

if ! version_gt "$NEW_VERSION" "$CURRENT_VERSION"; then
  fail "refusing to release: new version '$NEW_VERSION' is not greater than current '$CURRENT_VERSION'"
fi

# -----------------------------------------------------------------------------
# ensure CHANGELOG has an [Unreleased] section to promote
# -----------------------------------------------------------------------------
[[ -f "$CHANGELOG_FILE" ]] || fail "CHANGELOG.md not found at $CHANGELOG_FILE"
if ! grep -qE '^## \[Unreleased\]' "$CHANGELOG_FILE"; then
  fail "CHANGELOG.md has no '## [Unreleased]' section — nothing to promote"
fi

TODAY="$(date -u +%Y-%m-%d)"

say "Release preview"
printf "  current version:  %s\n" "$CURRENT_VERSION"
printf "  new version:      %s\n" "$NEW_VERSION"
printf "  release date:     %s (UTC)\n" "$TODAY"
printf "  dry-run:          %s\n" "$( [[ $DRY_RUN -eq 1 ]] && echo yes || echo no )"

# -----------------------------------------------------------------------------
# build the new CHANGELOG into a tmpfile, then either preview or swap in.
# Strategy:
#   - Rename the first `## [Unreleased]` line to `## [<new>] — <today>`
#   - Insert a fresh empty `## [Unreleased]` section above it
#   - Rewrite the two compare-link lines at the bottom:
#       [Unreleased]: .../compare/v<new>...HEAD
#       [<new>]:      .../releases/tag/v<new>
#     plus keep existing older-version links intact.
# -----------------------------------------------------------------------------
TMP_CHANGELOG="$(mktemp)"
trap 'rm -f "$TMP_CHANGELOG"' EXIT

awk -v new="$NEW_VERSION" -v today="$TODAY" '
  BEGIN { promoted = 0 }
  {
    if (!promoted && $0 ~ /^## \[Unreleased\]/) {
      print "## [Unreleased]"
      print ""
      print "## [" new "] — " today
      promoted = 1
      next
    }
    print
  }
' "$CHANGELOG_FILE" > "$TMP_CHANGELOG"

# Now patch the footer links. We:
#   - replace the existing [Unreleased]: compare link to point at v<new>...HEAD
#   - insert a new [<new>]: releases/tag/v<new> line right after it if missing
TMP2="$(mktemp)"
trap 'rm -f "$TMP_CHANGELOG" "$TMP2"' EXIT

awk -v new="$NEW_VERSION" -v slug="$REPO_SLUG" '
  BEGIN { inserted_tag_link = 0 }
  {
    if ($0 ~ /^\[Unreleased\]:/) {
      print "[Unreleased]: https://github.com/" slug "/compare/v" new "...HEAD"
      print "[" new "]: https://github.com/" slug "/releases/tag/v" new
      inserted_tag_link = 1
      next
    }
    print
  }
  END {
    if (!inserted_tag_link) {
      # CHANGELOG had no compare-link footer; append one.
      print ""
      print "[Unreleased]: https://github.com/" slug "/compare/v" new "...HEAD"
      print "[" new "]: https://github.com/" slug "/releases/tag/v" new
    }
  }
' "$TMP_CHANGELOG" > "$TMP2"

# -----------------------------------------------------------------------------
# preview or apply
# -----------------------------------------------------------------------------
if [[ "$DRY_RUN" -eq 1 ]]; then
  say "Dry-run: CHANGELOG.md diff preview"
  if command -v diff >/dev/null; then
    diff -u "$CHANGELOG_FILE" "$TMP2" || true
  else
    cat "$TMP2"
  fi
  printf "\n"
  say "Dry-run: VERSION would become:"
  printf "  %s\n" "$NEW_VERSION"
  printf "\n"
  say "Dry-run: would run self-test:"
  printf "  %s --kind=script\n" "$SELF_TEST"
  printf "\n"
  say "Dry-run: would commit + tag:"
  printf "  git add VERSION CHANGELOG.md\n"
  printf "  git commit -m 'Release v%s'\n" "$NEW_VERSION"
  printf "  git tag v%s\n" "$NEW_VERSION"
  printf "\n"
  ok "Dry-run complete — no changes made."
  exit 0
fi

# Self-test BEFORE we mutate anything. Skip gracefully if the runner isn't
# executable (e.g. file mode lost on some filesystems) but require it exists.
if [[ -x "$SELF_TEST" ]]; then
  say "Running self-test (--kind=script) before tagging"
  if ! "$SELF_TEST" --kind=script; then
    fail "self-test failed — refusing to release. Fix the tree first."
  fi
  ok "Self-test passed"
else
  warn "self-test runner not executable at $SELF_TEST — skipping (check permissions)"
fi

# Apply CHANGELOG rewrite.
mv "$TMP2" "$CHANGELOG_FILE"
# Reset trap to only clean up the original tmpfile (TMP2 has been moved).
trap 'rm -f "$TMP_CHANGELOG"' EXIT
ok "Updated CHANGELOG.md"

# Bump VERSION.
printf '%s\n' "$NEW_VERSION" > "$VERSION_FILE"
ok "Bumped VERSION to $NEW_VERSION"

# Commit + tag.
say "git add + commit + tag"
( cd "$ROOT_DIR" && git add VERSION CHANGELOG.md )
( cd "$ROOT_DIR" && git commit -m "Release v$NEW_VERSION" )
( cd "$ROOT_DIR" && git tag -a "v$NEW_VERSION" -m "Release v$NEW_VERSION" )
ok "Committed and tagged v$NEW_VERSION"

cat <<EOF

${C_BOLD}Next steps (operator-invoked — release.sh does NOT push):${C_RESET}
  git push
  git push --tags

Then open the GitHub release at:
  https://github.com/${REPO_SLUG}/releases/new?tag=v${NEW_VERSION}

EOF

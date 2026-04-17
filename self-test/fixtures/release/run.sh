#!/usr/bin/env bash
#
# self-test fixture driver for scripts/release.sh.
#
# release.sh resolves VERSION and CHANGELOG.md relative to its own script
# location (<root>/scripts/release.sh → <root>/VERSION). To exercise it
# against fixture files without mutating the real repo root, we stage a
# minimal mirror directory layout in a tmpdir:
#
#   $tmp/VERSION                         (fixture copy)
#   $tmp/CHANGELOG.md                    (fixture copy)
#   $tmp/scripts/release.sh              (symlink to real release.sh)
#   $tmp/self-test/run.sh                (stub — release.sh invokes it)
#
# Then invoke $tmp/scripts/release.sh --dry-run and a few failure modes.
#
# Exits 0 on PASS, non-zero on FAIL. Runs with NO_COLOR=1 so grep patterns
# don't trip over ANSI escapes.
#
# Invoked by self-test/golden-cases.example.json case "release-script-smoke".

set -euo pipefail
export NO_COLOR=1

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
FIXTURE_DIR="$SCRIPT_DIR"
ROOT_DIR="$(cd -- "$SCRIPT_DIR/../../.." && pwd)"
REAL_RELEASE="$ROOT_DIR/scripts/release.sh"

[[ -x "$REAL_RELEASE" ]] || { echo "FAIL: $REAL_RELEASE not executable" >&2; exit 1; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# Stage the mirror tree.
cp "$FIXTURE_DIR/VERSION"      "$tmp/VERSION"
cp "$FIXTURE_DIR/CHANGELOG.md" "$tmp/CHANGELOG.md"
mkdir -p "$tmp/scripts" "$tmp/self-test"
# Copy (not symlink) so release.sh's $SCRIPT_DIR / $ROOT_DIR resolves under $tmp.
cp "$REAL_RELEASE" "$tmp/scripts/release.sh"
chmod +x "$tmp/scripts/release.sh"

# Stub self-test runner that just prints a pass line. release.sh only calls
# this if the file is -x; our stub returns 0.
cat > "$tmp/self-test/run.sh" <<'EOF'
#!/usr/bin/env bash
echo "fixture self-test stub: $*"
exit 0
EOF
chmod +x "$tmp/self-test/run.sh"

# Test 1: --dry-run should succeed and not mutate the fixture VERSION.
if ! "$tmp/scripts/release.sh" --dry-run 0.2.0 >/dev/null 2>&1; then
  echo "FAIL: dry-run 0.2.0 returned non-zero" >&2
  exit 1
fi
before="$(cat "$tmp/VERSION")"
if [[ "$before" != "0.1.0" ]]; then
  echo "FAIL: dry-run mutated VERSION (got '$before', expected '0.1.0')" >&2
  exit 1
fi
if ! grep -q '^## \[Unreleased\]' "$tmp/CHANGELOG.md"; then
  echo "FAIL: dry-run mutated CHANGELOG (Unreleased section missing)" >&2
  exit 1
fi

# Test 2: downgrade refusal.
if "$tmp/scripts/release.sh" 0.0.9 >/dev/null 2>&1; then
  echo "FAIL: downgrade 0.0.9 should have exited non-zero" >&2
  exit 1
fi

# Test 3: equal-version refusal.
if "$tmp/scripts/release.sh" 0.1.0 >/dev/null 2>&1; then
  echo "FAIL: equal 0.1.0 should have exited non-zero" >&2
  exit 1
fi

# Test 4: non-semver refusal.
if "$tmp/scripts/release.sh" bogus >/dev/null 2>&1; then
  echo "FAIL: 'bogus' should have exited non-zero" >&2
  exit 1
fi

# Test 5: --dry-run output contains the expected header + new version line.
out="$("$tmp/scripts/release.sh" --dry-run 0.2.0 2>&1)"
if ! grep -q 'Release preview' <<<"$out"; then
  echo "FAIL: dry-run output missing 'Release preview' header" >&2
  exit 1
fi
if ! grep -q '0.2.0' <<<"$out"; then
  echo "FAIL: dry-run output missing new version '0.2.0'" >&2
  exit 1
fi

echo "PASS: scripts/release.sh fixture roundtrip"

#!/usr/bin/env bash
#
# launcher-upgrade-regen smoke test — exercise the auto-regen path that
# ticket #123 added to setup.sh.
#
# Why this fixture exists:
#   PR #122 shipped critical fixes to ./hydra's dispatch logic. Operators
#   who had already run ./setup.sh on an earlier commit re-ran it after
#   pulling main and got "./hydra launcher already exists — leaving as-is"
#   — the fix was invisible. Ticket #123 added marker-based regen; this
#   fixture proves it end-to-end on a pre-#123-shaped launcher.
#
# Flow (mirrors launcher-dispatch-smoke shape):
#   1. stage a fresh worktree into a tmpdir
#   2. hand-write a pre-#123 launcher (no marker line)
#   3. run ./setup.sh --non-interactive; assert:
#       (a) backed-up ./hydra.bak-<ts> matches the pre-placed old
#       (b) fresh ./hydra has a marker comment line
#       (c) stdout logged the migration (pre-#123 message OR mismatch)
#   4. run ./setup.sh --non-interactive a SECOND time; assert:
#       (d) exit 0 + "already up to date" logged
#       (e) the single .bak from step 3 is still the only one (no new .bak)
#       (f) the on-disk launcher is byte-identical to the one after step 3
#   5. simulate a mismatched-marker launcher (tampered), run again; assert:
#       (g) a second .bak is created and content matches the tampered launcher
#       (h) stdout contains "Launcher version mismatch (had ..., expected ...)"
#
# Emits `SMOKE_OK` on pass; any assertion failure exits non-zero with a
# specific error message.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# Fixture is at self-test/fixtures/launcher-upgrade-regen/run.sh.
# Worktree root is three levels up.
ROOT_DIR="$(cd -- "$SCRIPT_DIR/../../.." && pwd)"

TMPDIR_BASE="${TMPDIR:-/tmp}"
WORK_DIR="$(mktemp -d "$TMPDIR_BASE/launcher-upgrade-regen-XXXXXX")"

cleanup() {
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

# -----------------------------------------------------------------------------
# 1. Stage a fresh copy of the worktree into a tmpdir.
# -----------------------------------------------------------------------------
if command -v rsync >/dev/null 2>&1; then
  rsync -a \
    --exclude='.git' \
    --exclude='node_modules' \
    --exclude='.claude/worktrees' \
    --exclude='hydra' \
    --exclude='.hydra.env' \
    --exclude='state/active.json' \
    --exclude='state/budget-used.json' \
    --exclude='state/memory-citations.json' \
    --exclude='state/autopickup.json' \
    --exclude='.claude/settings.local.json' \
    "$ROOT_DIR/" "$WORK_DIR/"
else
  (cd "$ROOT_DIR" && tar --exclude='.git' --exclude='node_modules' \
    --exclude='.claude/worktrees' --exclude='./hydra' \
    --exclude='.hydra.env' --exclude='state/active.json' \
    --exclude='state/budget-used.json' \
    --exclude='state/memory-citations.json' \
    --exclude='state/autopickup.json' \
    --exclude='.claude/settings.local.json' \
    -cf - .) | (cd "$WORK_DIR" && tar -xf -)
fi

cd "$WORK_DIR"

MEMDIR="$WORK_DIR/memdir"
mkdir -p "$MEMDIR"

# -----------------------------------------------------------------------------
# 2. Hand-write a pre-#123 launcher — no marker line, arbitrary content.
# -----------------------------------------------------------------------------
cat > hydra <<'OLD_LAUNCHER'
#!/usr/bin/env bash
# Simulated pre-#123 launcher. No version marker, minimal body.
set -e
echo "stale launcher from a pre-upgrade install"
OLD_LAUNCHER
chmod +x hydra
# Snapshot for later comparison.
cp hydra hydra.preupgrade

# -----------------------------------------------------------------------------
# 3. First setup.sh run — should detect the marker-less launcher and migrate.
# -----------------------------------------------------------------------------
# Fresh environment — strip any inherited HYDRA_* so the tmpdir's setup
# defines them locally. Matches the pattern setup-interactive-ci-mode uses.
if ! env -u HYDRA_EXTERNAL_MEMORY_DIR -u HYDRA_ROOT -u COMMANDER_ROOT \
    HYDRA_NON_INTERACTIVE=1 HYDRA_EXTERNAL_MEMORY_DIR="$MEMDIR" NO_COLOR=1 \
    ./setup.sh --non-interactive >"$WORK_DIR/setup1.log" 2>&1; then
  echo "FAIL: first setup.sh run exited non-zero" >&2
  cat "$WORK_DIR/setup1.log" >&2
  exit 1
fi

# (a) the pre-#123 launcher got backed up
shopt -s nullglob
bak_files=(hydra.bak-*)
shopt -u nullglob
if [[ ${#bak_files[@]} -eq 0 ]]; then
  echo "FAIL: no hydra.bak-* created after migrating a pre-#123 launcher" >&2
  cat "$WORK_DIR/setup1.log" >&2
  exit 1
fi
if [[ ${#bak_files[@]} -gt 1 ]]; then
  echo "FAIL: expected exactly 1 hydra.bak-*, got ${#bak_files[@]}" >&2
  printf '  %s\n' "${bak_files[@]}" >&2
  exit 1
fi
FIRST_BAK="${bak_files[0]}"

# .bak content equals the hand-written pre-upgrade launcher
if ! diff -q "$FIRST_BAK" hydra.preupgrade >/dev/null 2>&1; then
  echo "FAIL: $FIRST_BAK contents differ from the pre-upgrade launcher we placed" >&2
  diff "$FIRST_BAK" hydra.preupgrade | sed 's/^/  /' >&2
  exit 1
fi
echo "BAK_ROUNDTRIP_OK: $FIRST_BAK"

# (b) fresh ./hydra has a marker comment line
if ! grep -qE '^# hydra-launcher-version: [0-9a-f]{8}$' hydra; then
  echo "FAIL: regenerated ./hydra missing a valid '# hydra-launcher-version: <8hex>' line" >&2
  head -5 hydra | sed 's/^/  /' >&2
  exit 1
fi
MARKER1="$(awk '/^# hydra-launcher-version:/ {print $3; exit}' hydra)"
echo "MARKER_PRESENT: $MARKER1"

# (c) stdout logged the migration — either pre-123 message or mismatch
if ! grep -qE '(Launcher has no version marker|Launcher version mismatch)' \
      "$WORK_DIR/setup1.log"; then
  echo "FAIL: setup.sh stdout did not mention the migration" >&2
  cat "$WORK_DIR/setup1.log" >&2
  exit 1
fi
echo "MIGRATION_LOG_OK"

# -----------------------------------------------------------------------------
# 4. Second setup.sh run — should be a no-op (markers match, byte-identical).
# -----------------------------------------------------------------------------
cp hydra hydra.afterfirst
if ! env -u HYDRA_EXTERNAL_MEMORY_DIR -u HYDRA_ROOT -u COMMANDER_ROOT \
    HYDRA_NON_INTERACTIVE=1 HYDRA_EXTERNAL_MEMORY_DIR="$MEMDIR" NO_COLOR=1 \
    ./setup.sh --non-interactive >"$WORK_DIR/setup2.log" 2>&1; then
  echo "FAIL: second setup.sh run exited non-zero" >&2
  cat "$WORK_DIR/setup2.log" >&2
  exit 1
fi

# (d) "already up to date" logged
if ! grep -qF 'already up to date' "$WORK_DIR/setup2.log"; then
  echo "FAIL: second setup.sh run did not print 'already up to date'" >&2
  cat "$WORK_DIR/setup2.log" >&2
  exit 1
fi
# And it must NOT re-announce a mismatch/migration
if grep -qE '(Launcher has no version marker|Launcher version mismatch|Launcher version marker malformed)' \
     "$WORK_DIR/setup2.log"; then
  echo "FAIL: second run should not re-trigger migration" >&2
  cat "$WORK_DIR/setup2.log" >&2
  exit 1
fi

# (e) still exactly one .bak file
shopt -s nullglob
bak_files2=(hydra.bak-*)
shopt -u nullglob
if [[ ${#bak_files2[@]} -ne 1 ]]; then
  echo "FAIL: expected exactly 1 bak after idempotent run, got ${#bak_files2[@]}" >&2
  printf '  %s\n' "${bak_files2[@]}" >&2
  exit 1
fi

# (f) byte-identical
if ! diff -q hydra.afterfirst hydra >/dev/null 2>&1; then
  echo "FAIL: idempotent second run changed ./hydra" >&2
  diff hydra.afterfirst hydra | sed 's/^/  /' >&2
  exit 1
fi
echo "IDEMPOTENT_OK"

# -----------------------------------------------------------------------------
# 5. Mismatched-marker scenario — simulate a partial upgrade where the
#    launcher has a marker but it's wrong.
# -----------------------------------------------------------------------------
# Tamper with the marker in-place. Use sed with a temp file to stay portable
# across BSD (macOS) and GNU sed.
sed "s|^# hydra-launcher-version: [0-9a-f]*|# hydra-launcher-version: deadbeef|" \
    hydra > hydra.tampered
mv hydra.tampered hydra
chmod +x hydra
cp hydra hydra.tampered.snapshot  # for the .bak roundtrip assertion

if ! env -u HYDRA_EXTERNAL_MEMORY_DIR -u HYDRA_ROOT -u COMMANDER_ROOT \
    HYDRA_NON_INTERACTIVE=1 HYDRA_EXTERNAL_MEMORY_DIR="$MEMDIR" NO_COLOR=1 \
    ./setup.sh --non-interactive >"$WORK_DIR/setup3.log" 2>&1; then
  echo "FAIL: third setup.sh run (tampered marker) exited non-zero" >&2
  cat "$WORK_DIR/setup3.log" >&2
  exit 1
fi

# (g) a SECOND .bak now exists, and its content is the tampered launcher
shopt -s nullglob
bak_files3=(hydra.bak-*)
shopt -u nullglob
if [[ ${#bak_files3[@]} -ne 2 ]]; then
  echo "FAIL: expected 2 bak files after a mismatch run, got ${#bak_files3[@]}" >&2
  printf '  %s\n' "${bak_files3[@]}" >&2
  exit 1
fi

# Find the new .bak (neither equals FIRST_BAK)
NEW_BAK=""
for b in "${bak_files3[@]}"; do
  if [[ "$b" != "$FIRST_BAK" ]]; then
    NEW_BAK="$b"
    break
  fi
done
if [[ -z "$NEW_BAK" ]]; then
  echo "FAIL: could not identify the new .bak from the mismatch run" >&2
  exit 1
fi

if ! diff -q "$NEW_BAK" hydra.tampered.snapshot >/dev/null 2>&1; then
  echo "FAIL: $NEW_BAK differs from the tampered launcher we placed" >&2
  diff "$NEW_BAK" hydra.tampered.snapshot | sed 's/^/  /' >&2
  exit 1
fi
echo "MISMATCH_BAK_ROUNDTRIP_OK: $NEW_BAK"

# (h) the mismatch-specific log line present
if ! grep -qE 'Launcher version mismatch \(had deadbeef, expected [0-9a-f]{8}\)' \
      "$WORK_DIR/setup3.log"; then
  echo "FAIL: setup.sh stdout did not log the deadbeef mismatch" >&2
  cat "$WORK_DIR/setup3.log" >&2
  exit 1
fi
echo "MISMATCH_LOG_OK"

# Fresh launcher has a fresh (valid) marker
MARKER3="$(awk '/^# hydra-launcher-version:/ {print $3; exit}' hydra)"
if [[ ! "$MARKER3" =~ ^[0-9a-f]{8}$ ]]; then
  echo "FAIL: ./hydra marker after mismatch run is not 8-hex (got '$MARKER3')" >&2
  exit 1
fi
if [[ "$MARKER3" == "deadbeef" ]]; then
  echo "FAIL: ./hydra marker still equals 'deadbeef' — regen did not replace it" >&2
  exit 1
fi

echo "SMOKE_OK"

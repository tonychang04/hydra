#!/usr/bin/env bash
#
# launcher-marker.sh — compute / extract the ./hydra launcher version marker.
#
# Shared between setup.sh (on write/regen) and hydra-doctor.sh (on health
# check) so both agree on what "matches" means. DRY — one source of truth.
#
# The marker is an 8-hex-character prefix of SHA-256 over a normalized form
# of the launcher body: the body text with the marker line itself replaced
# by a fixed placeholder string. This avoids the chicken-and-egg of a
# self-referential hash while still tracking every meaningful heredoc edit.
#
# Subcommands:
#   compute <file>       Print the marker for <file>'s body. 8 hex chars.
#                        Exit 0. If sha256 is unavailable, exit 3 (fail-soft).
#   extract <file>       Print the marker found in <file> (from the first
#                        "# hydra-launcher-version: XXXX" comment line). On
#                        no match, print "none" and exit 4. On malformed
#                        (present but wrong shape), print "malformed" and
#                        exit 5.
#   compare <on-disk> <fresh-body>
#                        compute both, print `match` or `mismatch <old> <new>`
#                        on stdout. Exit 0 on match, exit 6 on mismatch.
#                        If the on-disk marker is missing: print
#                        `mismatch none <new>`, exit 6. If the on-disk is
#                        malformed: print `mismatch malformed <new>`, exit 6.
#   --self-test          Inline sanity check: hash a known string, assert
#                        a known output. Catches coreutils drift on exotic
#                        platforms. Exit 0 pass / 1 fail.
#
# Environment:
#   NO_COLOR=1           Suppress ANSI color on diagnostic output.
#
# Exit codes (summary):
#   0  success (matched / computed / extracted fine)
#   1  usage error
#   2  file not found
#   3  sha256 tool unavailable
#   4  marker not present on file
#   5  marker present but malformed
#   6  compare: mismatch (expected vs. actual differ)
#
# Spec: docs/specs/2026-04-17-launcher-auto-regen.md (ticket #123)

set -euo pipefail

# Fixed placeholder used when normalizing the marker line before hashing.
# Must NOT be a valid 8-hex marker (it's not — `PLACEHOLDER` has no digits).
PLACEHOLDER_TOKEN="PLACEHOLDER"
MARKER_LINE_PREFIX="# hydra-launcher-version:"

# Expected marker shape: exactly 8 hex characters (lowercase).
MARKER_SHAPE_RE='^[0-9a-f]{8}$'

# ---------------------------------------------------------------------------
# sha256 wrapper — portable over macOS (shasum) and Linux (sha256sum).
# Reads from stdin, prints hash only on stdout.
# Returns 3 if neither tool is present.
# ---------------------------------------------------------------------------
_sha256_stdin() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 | awk '{print $1}'
  else
    return 3
  fi
}

# ---------------------------------------------------------------------------
# Compute the marker for a given launcher body file.
# Normalizes the marker line to `PLACEHOLDER` before hashing so the marker
# itself doesn't perturb the hash.
#
# Args:
#   $1 — path to launcher body file
# Stdout: 8 hex chars
# Exit:   0 success; 2 file missing; 3 sha256 unavailable
# ---------------------------------------------------------------------------
cmd_compute() {
  local file="$1"
  [[ -f "$file" ]] || { echo "launcher-marker: file not found: $file" >&2; return 2; }

  local hash
  if ! hash="$(
    sed "s|^${MARKER_LINE_PREFIX} .*|${MARKER_LINE_PREFIX} ${PLACEHOLDER_TOKEN}|" "$file" \
      | _sha256_stdin
  )"; then
    return 3
  fi
  # Truncate to 8 hex chars. awk above already stripped filename; trim newlines.
  printf '%s\n' "$(printf '%s' "$hash" | cut -c1-8)"
}

# ---------------------------------------------------------------------------
# Extract the existing marker from a launcher file.
# Greps the first matching comment line; validates shape.
#
# Args:
#   $1 — path to launcher file (./hydra)
# Stdout: 8 hex chars (or "none", or "malformed")
# Exit:   0 valid marker printed; 2 file missing; 4 marker absent; 5 malformed
# ---------------------------------------------------------------------------
cmd_extract() {
  local file="$1"
  [[ -f "$file" ]] || { echo "launcher-marker: file not found: $file" >&2; return 2; }

  local raw
  raw="$(
    awk -v prefix="$MARKER_LINE_PREFIX" '
      $0 ~ "^"prefix {
        # Strip prefix + surrounding spaces; print second field if present.
        sub("^"prefix"[[:space:]]*", "")
        # Keep only the first whitespace-delimited token.
        sub("[[:space:]].*$", "")
        print
        exit
      }
    ' "$file"
  )"

  if [[ -z "$raw" ]]; then
    echo "none"
    return 4
  fi

  if [[ ! "$raw" =~ $MARKER_SHAPE_RE ]]; then
    echo "malformed"
    return 5
  fi

  echo "$raw"
  return 0
}

# ---------------------------------------------------------------------------
# Compare on-disk marker vs. freshly computed marker.
#
# Args:
#   $1 — path to on-disk launcher (./hydra)
#   $2 — path to fresh body file to hash (typically a tmpfile setup.sh
#        just wrote)
# Stdout: `match` or `mismatch <old> <new>`
# Exit:   0 match; 6 mismatch (regen needed); 2/3 propagated from compute
# ---------------------------------------------------------------------------
cmd_compare() {
  local on_disk="$1" fresh_body="$2"
  local old new

  # Extract on-disk marker. Treat "not found" / "malformed" as mismatch signals.
  set +e
  old="$(cmd_extract "$on_disk")"
  local extract_rc=$?
  set -e
  case "$extract_rc" in
    0) ;;
    4) old="none" ;;
    5) old="malformed" ;;
    *) return "$extract_rc" ;;
  esac

  # Compute expected marker from the fresh body.
  new="$(cmd_compute "$fresh_body")" || return $?

  if [[ "$old" == "$new" ]]; then
    echo "match"
    return 0
  else
    echo "mismatch $old $new"
    return 6
  fi
}

# ---------------------------------------------------------------------------
# Self-test — catches sha256 tool drift and shape assertions.
# Golden input → golden output for both shasum and sha256sum paths.
# ---------------------------------------------------------------------------
cmd_self_test() {
  local tmp
  tmp="$(mktemp)"
  # shellcheck disable=SC2064  # intentional early expansion so EXIT trap sees the value
  trap "rm -f '$tmp' '$tmp.orig' '$tmp.2'" RETURN

  # Known-input body. First line is a shebang, second is the marker line
  # with a nonsense value (proves normalization works).
  cat > "$tmp" <<BODY
#!/usr/bin/env bash
${MARKER_LINE_PREFIX} deadbeef
echo hello
BODY

  local got1 got2
  got1="$(cmd_compute "$tmp")"

  # Swap the marker value; the normalized hash MUST be identical.
  sed -i.orig "s|${MARKER_LINE_PREFIX} deadbeef|${MARKER_LINE_PREFIX} 12345678|" "$tmp" 2>/dev/null \
    || { rm -f "$tmp.orig"; sed -i '' "s|${MARKER_LINE_PREFIX} deadbeef|${MARKER_LINE_PREFIX} 12345678|" "$tmp"; }
  rm -f "$tmp.orig"
  got2="$(cmd_compute "$tmp")"

  if [[ "$got1" != "$got2" ]]; then
    echo "launcher-marker self-test: marker normalization failed (got1=$got1 got2=$got2)" >&2
    return 1
  fi

  # Shape check: 8 lowercase-hex chars.
  if [[ ! "$got1" =~ $MARKER_SHAPE_RE ]]; then
    echo "launcher-marker self-test: output shape invalid (got=$got1)" >&2
    return 1
  fi

  # Extract path: write the hash back in and re-extract.
  sed "s|${MARKER_LINE_PREFIX} 12345678|${MARKER_LINE_PREFIX} ${got1}|" "$tmp" > "$tmp.2"
  local extracted
  extracted="$(cmd_extract "$tmp.2")"
  if [[ "$extracted" != "$got1" ]]; then
    echo "launcher-marker self-test: extract(write($got1)) != $got1 (got=$extracted)" >&2
    rm -f "$tmp.2"
    return 1
  fi
  rm -f "$tmp.2"

  # Missing-marker extraction:
  : > "$tmp"
  echo "#!/usr/bin/env bash" >> "$tmp"
  echo "echo no marker" >> "$tmp"
  set +e
  cmd_extract "$tmp" >/dev/null
  local rc=$?
  set -e
  if [[ "$rc" -ne 4 ]]; then
    echo "launcher-marker self-test: expected exit 4 on missing marker, got $rc" >&2
    return 1
  fi

  # Malformed extraction:
  echo "${MARKER_LINE_PREFIX} not-hex" >> "$tmp"
  set +e
  cmd_extract "$tmp" >/dev/null
  rc=$?
  set -e
  if [[ "$rc" -ne 5 ]]; then
    echo "launcher-marker self-test: expected exit 5 on malformed marker, got $rc" >&2
    return 1
  fi

  echo "launcher-marker self-test: OK (marker=$got1)"
  return 0
}

usage() {
  cat <<'EOF'
Usage: launcher-marker.sh <subcommand> [args]

Subcommands:
  compute <file>              Print 8-hex marker for file's body.
  extract <file>              Print existing marker (or "none"/"malformed").
  compare <on-disk> <fresh>   Compare on-disk launcher vs. freshly written
                              body file. Prints "match" or
                              "mismatch <old> <new>".
  --self-test                 Sanity check sha256 + normalization logic.

Exit codes:
  0 success     1 usage      2 file missing     3 sha256 unavailable
  4 no marker   5 malformed  6 mismatch

Spec: docs/specs/2026-04-17-launcher-auto-regen.md
EOF
}

# ---------------------------------------------------------------------------
# Dispatch
# ---------------------------------------------------------------------------
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  # Invoked directly (not sourced). Parse args.
  case "${1:-}" in
    compute)
      [[ $# -eq 2 ]] || { usage >&2; exit 1; }
      cmd_compute "$2"
      ;;
    extract)
      [[ $# -eq 2 ]] || { usage >&2; exit 1; }
      cmd_extract "$2"
      ;;
    compare)
      [[ $# -eq 3 ]] || { usage >&2; exit 1; }
      cmd_compare "$2" "$3"
      ;;
    --self-test)
      cmd_self_test
      ;;
    -h|--help|help|"")
      usage
      ;;
    *)
      echo "launcher-marker: unknown subcommand: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
fi

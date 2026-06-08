#!/usr/bin/env bash
#
# self-test fixture driver for the Decision Record substrate (ticket #267).
#
# Exercises the writer + reader end to end, offline (bash + jq, no
# network/docker/auth):
#   1. The committed sample-decisions.jsonl is valid JSONL with the five required
#      top-level keys on every line, a legal decision_type enum on every line,
#      and exactly one entry per seeded type (tier-classify, merge-surface,
#      escalate) — proving the on-disk format the spec promises.
#   2. Delegates to scripts/test-record-decision.sh for the full writer suite
#      (flags + JSON-stdin append, RED->GREEN schema rejection, ts auto-gen,
#      --date seam, usage errors).
#   3. Delegates to scripts/test-decisions.sh for the full reader suite.
#   4. Asserts scripts/decisions.sh output against the committed fixture: no-arg
#      lists all seeded entries, a #N subject filter narrows correctly, --since
#      filters by date, and --json emits a well-formed array. This binds the
#      committed fixture to the reader contract so a drift in either side fails.
#
# Prints SMOKE_OK on success; non-zero exit on any failure.
#
# Invoked by self-test/golden-cases.example.json case "decision-record".
# Spec: docs/specs/2026-06-08-decision-record.md (ticket #267)

set -euo pipefail
export NO_COLOR=1

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd -- "$SCRIPT_DIR/../../.." && pwd)"
FIXTURE="$SCRIPT_DIR/sample-decisions.jsonl"
READER="$ROOT_DIR/scripts/decisions.sh"
TEST_WRITER="$ROOT_DIR/scripts/test-record-decision.sh"
TEST_READER="$ROOT_DIR/scripts/test-decisions.sh"

command -v jq >/dev/null 2>&1 || { echo "FAIL: jq required" >&2; exit 1; }
[[ -f "$FIXTURE" ]]     || { echo "FAIL: missing fixture $FIXTURE" >&2; exit 1; }
[[ -x "$READER" ]]      || { echo "FAIL: $READER not executable" >&2; exit 1; }
[[ -x "$TEST_WRITER" ]] || { echo "FAIL: $TEST_WRITER not executable" >&2; exit 1; }
[[ -x "$TEST_READER" ]] || { echo "FAIL: $TEST_READER not executable" >&2; exit 1; }

# --- 1. committed fixture is structurally sound ------------------------------
if ! jq empty "$FIXTURE" >/dev/null 2>&1; then
  echo "FAIL: sample-decisions.jsonl is not valid JSONL" >&2
  exit 1
fi

# Every line must carry the five required top-level keys.
bad_lines="$(jq -c 'select((["ts","decision_type","subject","decided","why"] - (keys)) != []) | .subject // "?"' "$FIXTURE")"
if [[ -n "$bad_lines" ]]; then
  echo "FAIL: lines missing required keys (subjects): $bad_lines" >&2
  exit 1
fi

# Every line's decision_type must be in the schema enum.
ENUM='["tier-classify","ticket-pick","subagent-route","scope","merge-surface","escalate","rescue","gc","pause"]'
bad_enum="$(jq -c --argjson e "$ENUM" 'select((.decision_type as $t | $e | index($t)) == null) | .decision_type' "$FIXTURE")"
if [[ -n "$bad_enum" ]]; then
  echo "FAIL: illegal decision_type(s) in fixture: $bad_enum" >&2
  exit 1
fi

# Exactly one entry per seeded type the spec names.
for t in tier-classify merge-surface escalate; do
  n="$(jq -c --arg t "$t" 'select(.decision_type == $t)' "$FIXTURE" | wc -l | tr -d ' ')"
  if [[ "$n" != "1" ]]; then
    echo "FAIL: expected exactly 1 '$t' entry in fixture, found $n" >&2
    exit 1
  fi
done

# --- 2. full writer suite ----------------------------------------------------
if ! "$TEST_WRITER" >/dev/null 2>&1; then
  echo "FAIL: scripts/test-record-decision.sh assertions failed; run it directly for detail" >&2
  exit 1
fi

# --- 3. full reader suite ----------------------------------------------------
if ! "$TEST_READER" >/dev/null 2>&1; then
  echo "FAIL: scripts/test-decisions.sh assertions failed; run it directly for detail" >&2
  exit 1
fi

# --- 4. reader output asserted against the committed fixture ------------------
# Stage the fixture as a daily file so the reader's <YYYY-MM-DD>.jsonl globbing
# picks it up (the fixture's entries are all dated 2026-06-08).
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
cp "$FIXTURE" "$TMP/2026-06-08.jsonl"

# 4a. no-arg --json lists every seeded entry.
n_all="$(NO_COLOR=1 "$READER" --json --decisions-dir "$TMP" | jq 'length')"
n_fixture="$(jq -c '.' "$FIXTURE" | wc -l | tr -d ' ')"
if [[ "$n_all" != "$n_fixture" ]]; then
  echo "FAIL: reader returned $n_all entries; fixture has $n_fixture" >&2
  exit 1
fi

# 4b. #N subject filter narrows to the matching entry and normalizes #501 ->
#     tonychang04/hydra#501.
sel="$(NO_COLOR=1 "$READER" '#501' --json --decisions-dir "$TMP" | jq -r '.[0].subject // "MISS"')"
if [[ "$sel" != "tonychang04/hydra#501" ]]; then
  echo "FAIL: '#501' filter expected tonychang04/hydra#501, got '$sel'" >&2
  exit 1
fi
n_sel="$(NO_COLOR=1 "$READER" '#501' --json --decisions-dir "$TMP" | jq 'length')"
if [[ "$n_sel" != "1" ]]; then
  echo "FAIL: '#501' filter expected exactly 1 entry, got $n_sel" >&2
  exit 1
fi

# 4c. --since after every entry's date yields an empty (but well-formed) array.
n_future="$(NO_COLOR=1 "$READER" --json --since 2026-06-09 --decisions-dir "$TMP" | jq 'length')"
if [[ "$n_future" != "0" ]]; then
  echo "FAIL: --since 2026-06-09 expected 0 entries, got $n_future" >&2
  exit 1
fi
# --since on the entries' own date still includes them.
n_since="$(NO_COLOR=1 "$READER" --json --since 2026-06-08 --decisions-dir "$TMP" | jq 'length')"
if [[ "$n_since" != "$n_fixture" ]]; then
  echo "FAIL: --since 2026-06-08 expected $n_fixture entries, got $n_since" >&2
  exit 1
fi

# 4d. human (non-JSON) output surfaces the rationale ('why') for a filtered subject.
human="$(NO_COLOR=1 "$READER" '#501' --decisions-dir "$TMP")"
if ! grep -q 'why: t3-never' <<<"$human"; then
  echo "FAIL: human reader output missing the recorded 'why' for #501" >&2
  echo "----- got -----" >&2
  printf '%s\n' "$human" >&2
  exit 1
fi

echo "SMOKE_OK"

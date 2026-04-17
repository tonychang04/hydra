#!/usr/bin/env bash
#
# self-test fixture driver for scripts/alloc-worker-port.sh.
#
# Verifies the port allocator's core behaviors:
#   1. Returns slot 0's first port (40000) when nothing is taken.
#   2. Slot math: slot 1 → 40100, slot 2 → 40200.
#   3. Skips a known-taken port and returns the next free one.
#   4. --desired-port is honored when free, falls through to next-free when taken.
#   5. Exhausted range exits 1 with a clear error.
#   6. Argument validation (bad slot, missing service) exits 2.
#
# Does NOT require Docker. Runs locally on any machine with bash + python3
# (python3 is used only as a convenient background TCP listener; no other
# deps). Wired into self-test/golden-cases.example.json as case
# "worker-port-isolation-allocator".
#
# Exits 0 on PASS, non-zero on FAIL.

set -euo pipefail
export NO_COLOR=1

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd -- "$SCRIPT_DIR/../../.." && pwd)"
ALLOC="$ROOT_DIR/scripts/alloc-worker-port.sh"

[[ -x "$ALLOC" ]] || { echo "FAIL: $ALLOC not executable" >&2; exit 1; }

command -v python3 >/dev/null 2>&1 || {
  echo "SKIP: python3 not available — needed for background TCP listener in test 3/4" >&2
  # We still run the non-listener tests below by short-circuiting; but the
  # golden case expects all tests to run. Return SKIP (exit 0) is safer
  # than partial pass here.
  exit 0
}

# -----------------------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------------------
fail() {
  echo "FAIL: $*" >&2
  exit 1
}

# Background listener on a list of host ports. Uses SO_REUSEADDR so
# repeated runs don't wedge on TIME_WAIT. Prints the listener's PID to
# stdout (and only that; python's stdout goes to /dev/null so it doesn't
# poison the command substitution capturing this function's output).
spawn_listener() {
  local ports_csv="$1"
  python3 - "$ports_csv" >/dev/null 2>&1 <<'PY' &
import socket, select, sys, time
ports = [int(p) for p in sys.argv[1].split(',') if p]
socks = []
for p in ports:
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.bind(('127.0.0.1', p))
    s.listen(128)
    s.setblocking(False)
    socks.append(s)
# Accept + immediately close every connection so rapid probes don't fill
# the kernel accept queue. Run for up to 30s.
deadline = time.time() + 30
while time.time() < deadline:
    try:
        r, _, _ = select.select(socks, [], [], 0.1)
    except (ValueError, OSError):
        break
    for s in r:
        try:
            c, _ = s.accept()
            c.close()
        except BlockingIOError:
            pass
PY
  echo $!
}

wait_for_port() {
  local port="$1"
  local i
  for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    sleep 0.1
    if ( exec 3<>"/dev/tcp/127.0.0.1/$port" ) 2>/dev/null; then
      return 0
    fi
  done
  return 1
}

kill_and_wait() {
  local pid="$1"
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
}

# -----------------------------------------------------------------------------
# Test 1 — default allocation.
# Slot 0, no listener: first port in range (40000) is free → returns 40000.
# -----------------------------------------------------------------------------
got="$("$ALLOC" --worker-slot 0 --service pg)"
[[ "$got" == "40000" ]] || fail "test 1: expected 40000, got '$got'"

# -----------------------------------------------------------------------------
# Test 2 — slot math.
# Slot 1 → 40100, slot 2 → 40200, slot 3 → 40300.
# -----------------------------------------------------------------------------
got="$("$ALLOC" --worker-slot 1 --service pg)"
[[ "$got" == "40100" ]] || fail "test 2a: slot 1 expected 40100, got '$got'"
got="$("$ALLOC" --worker-slot 2 --service pg)"
[[ "$got" == "40200" ]] || fail "test 2b: slot 2 expected 40200, got '$got'"
got="$("$ALLOC" --worker-slot 3 --service pg)"
[[ "$got" == "40300" ]] || fail "test 2c: slot 3 expected 40300, got '$got'"

# -----------------------------------------------------------------------------
# Test 3 — skip a known-taken port.
# Listener on 40000 (first port in slot 0). Allocator must return 40001.
# -----------------------------------------------------------------------------
pid="$(spawn_listener 40000)"
trap 'kill_and_wait "$pid"' EXIT
wait_for_port 40000 || fail "test 3 setup: listener never came up on 40000"
got="$("$ALLOC" --worker-slot 0 --service pg)"
[[ "$got" == "40001" ]] || fail "test 3: expected 40001 (40000 taken), got '$got'"
kill_and_wait "$pid"
trap - EXIT

# -----------------------------------------------------------------------------
# Test 4 — --desired-port behavior.
# 4a: desired-port free → returns it.
# 4b: desired-port taken → returns next free (not the desired).
# 4c: desired-port outside the slot range → ignored, returns range start.
# -----------------------------------------------------------------------------
got="$("$ALLOC" --worker-slot 0 --service pg --desired-port 40042)"
[[ "$got" == "40042" ]] || fail "test 4a: desired 40042 free, expected 40042, got '$got'"

pid="$(spawn_listener 40042)"
trap 'kill_and_wait "$pid"' EXIT
wait_for_port 40042 || fail "test 4b setup: listener never came up on 40042"
got="$("$ALLOC" --worker-slot 0 --service pg --desired-port 40042)"
[[ "$got" != "40042" ]] || fail "test 4b: desired 40042 taken, got '$got' (should differ)"
# Should be a port in the slot range
(( got >= 40000 && got <= 40099 )) || fail "test 4b: got '$got' outside slot 0 range 40000-40099"
kill_and_wait "$pid"
trap - EXIT

# Outside range: slot 0 is 40000-40099, so 50000 is outside → ignored.
got="$("$ALLOC" --worker-slot 0 --service pg --desired-port 50000)"
[[ "$got" == "40000" ]] || fail "test 4c: desired-outside-range expected 40000, got '$got'"

# -----------------------------------------------------------------------------
# Test 5 — exhausted range exits 1.
# Shrink the range to 2 ports (40500,40501), listen on both, expect exit 1.
# -----------------------------------------------------------------------------
pid="$(spawn_listener 40500,40501)"
trap 'kill_and_wait "$pid"' EXIT
wait_for_port 40500 || fail "test 5 setup: listener never came up on 40500"
wait_for_port 40501 || fail "test 5 setup: listener never came up on 40501"

set +e
out="$("$ALLOC" --worker-slot 0 --service pg --base-port 40500 --ports-per-slot 2 2>&1)"
ec=$?
set -e
[[ "$ec" -eq 1 ]] || fail "test 5: exhausted range expected exit 1, got $ec (output: $out)"
grep -qF "no free port in slot 0" <<<"$out" || fail "test 5: output missing 'no free port in slot 0' (got: $out)"
kill_and_wait "$pid"
trap - EXIT

# -----------------------------------------------------------------------------
# Test 6 — argument validation.
# -----------------------------------------------------------------------------
set +e
"$ALLOC" >/dev/null 2>&1; ec=$?
set -e
[[ "$ec" -eq 2 ]] || fail "test 6a: no args expected exit 2, got $ec"

set +e
"$ALLOC" --worker-slot abc --service pg >/dev/null 2>&1; ec=$?
set -e
[[ "$ec" -eq 2 ]] || fail "test 6b: non-integer slot expected exit 2, got $ec"

set +e
"$ALLOC" --worker-slot 0 >/dev/null 2>&1; ec=$?
set -e
[[ "$ec" -eq 2 ]] || fail "test 6c: missing service expected exit 2, got $ec"

set +e
"$ALLOC" --worker-slot 0 --service pg --desired-port 99999 >/dev/null 2>&1; ec=$?
set -e
[[ "$ec" -eq 2 ]] || fail "test 6d: desired-port > 65535 expected exit 2, got $ec"

# Slot that would exceed 65535
set +e
"$ALLOC" --worker-slot 999 --service pg >/dev/null 2>&1; ec=$?
set -e
[[ "$ec" -eq 2 ]] || fail "test 6e: slot 999 (range exceeds 65535) expected exit 2, got $ec"

echo "PASS: scripts/alloc-worker-port.sh fixture roundtrip (6 test groups)"

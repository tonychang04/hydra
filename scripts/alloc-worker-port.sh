#!/usr/bin/env bash
#
# alloc-worker-port.sh — allocate a free TCP host port for a Hydra worker.
#
# Context: when two worker-implementation subagents run `docker compose up`
# in parallel against repos with overlapping published ports (5432, 6379,
# 3000...), the second one fails with "bind: address already in use". The
# fix is Layer 2 from docs/specs/2026-04-16-worker-port-isolation.md:
# remap each worker's published ports into a worker-scoped range, and write
# a docker-compose.override.yml that applies the remap.
#
# This script owns the "pick a free port for this worker + service" half
# of the fix. The worker (see .claude/agents/worker-implementation.md,
# "Docker isolation for parallel workers") is responsible for the rest:
# enumerating docker-compose.yml services, calling this script per service,
# and writing the override file.
#
# Port range math (per slot):
#   slot 0: 40000-40099
#   slot 1: 40100-40199
#   slot 2: 40200-40299
#   ... slot N: (40000 + N*100) to (40000 + (N+1)*100 - 1)
#
# 40000-40299 is below Linux's default ephemeral range (32768-60999) and
# macOS's (49152-65535), so the scoped range does not clash with the
# kernel's own ephemeral allocator.
#
# Algorithm:
#   1. Compute the slot's [lo, hi] inclusive range.
#   2. If --desired-port is supplied and is inside [lo, hi], probe it
#      first (lets callers express "prefer 5432 remapped to 40042").
#      Otherwise start at lo.
#   3. For each candidate in the range, probe it with `nc -z 127.0.0.1 N`
#      (preferred) or bash's `</dev/tcp` builtin (fallback).
#   4. Return the first candidate that is NOT currently accepting
#      connections. Exit 0.
#   5. If every port in the range is occupied, exit 1 with a clear error.
#
# Output format:
#   Plain integer port on stdout, nothing else. Caller can capture with
#   $(scripts/alloc-worker-port.sh ...).
#
# Exit codes:
#   0  success (port printed to stdout)
#   1  no free port in the slot's range / probe tool missing
#   2  usage error (bad flags / invalid slot)

set -euo pipefail

BASE_PORT_DEFAULT=40000
PORTS_PER_SLOT_DEFAULT=100

usage() {
  cat <<'EOF'
Usage: alloc-worker-port.sh --worker-slot <N> --service <name> [options]

Required:
  --worker-slot <N>        Non-negative integer slot (position in active.json).
                           Slot 0 = first worker, slot 1 = second, etc.
  --service <name>         Service name (e.g. "postgres", "redis", "web").
                           Used only for clearer log messages; the script
                           does not remember state across invocations.

Options:
  --desired-port <N>       Preferred port. If it falls inside the slot's
                           range AND is free, returns it. Otherwise probes
                           the rest of the range. Useful for "remap 5432
                           to the slot-local version of 5432 if possible".
  --base-port <N>          Override the slot-0 starting port (default 40000).
  --ports-per-slot <N>     Override the slot width (default 100).
  --probe-host <host>      Probe against this host (default 127.0.0.1).
                           Testing knob; production always uses localhost.
  -h, --help               Show this help.

Exit codes:
  0  success (port on stdout)
  1  no free port available / probe tool missing
  2  usage error
EOF
}

# -----------------------------------------------------------------------------
# Arg parsing.
# -----------------------------------------------------------------------------
slot=""
service=""
desired_port=""
base_port="$BASE_PORT_DEFAULT"
ports_per_slot="$PORTS_PER_SLOT_DEFAULT"
probe_host="127.0.0.1"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --worker-slot)
      [[ $# -ge 2 ]] || { echo "alloc-worker-port: --worker-slot needs a value" >&2; usage >&2; exit 2; }
      slot="$2"
      shift 2
      ;;
    --service)
      [[ $# -ge 2 ]] || { echo "alloc-worker-port: --service needs a value" >&2; usage >&2; exit 2; }
      service="$2"
      shift 2
      ;;
    --desired-port)
      [[ $# -ge 2 ]] || { echo "alloc-worker-port: --desired-port needs a value" >&2; usage >&2; exit 2; }
      desired_port="$2"
      shift 2
      ;;
    --base-port)
      [[ $# -ge 2 ]] || { echo "alloc-worker-port: --base-port needs a value" >&2; usage >&2; exit 2; }
      base_port="$2"
      shift 2
      ;;
    --ports-per-slot)
      [[ $# -ge 2 ]] || { echo "alloc-worker-port: --ports-per-slot needs a value" >&2; usage >&2; exit 2; }
      ports_per_slot="$2"
      shift 2
      ;;
    --probe-host)
      [[ $# -ge 2 ]] || { echo "alloc-worker-port: --probe-host needs a value" >&2; usage >&2; exit 2; }
      probe_host="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "alloc-worker-port: unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

# -----------------------------------------------------------------------------
# Validate.
# -----------------------------------------------------------------------------
if [[ -z "$slot" ]]; then
  echo "alloc-worker-port: --worker-slot is required" >&2
  usage >&2
  exit 2
fi
if [[ -z "$service" ]]; then
  echo "alloc-worker-port: --service is required" >&2
  usage >&2
  exit 2
fi

# slot must be a non-negative integer
if ! [[ "$slot" =~ ^[0-9]+$ ]]; then
  echo "alloc-worker-port: --worker-slot must be a non-negative integer (got: $slot)" >&2
  exit 2
fi

# base_port / ports_per_slot sanity
if ! [[ "$base_port" =~ ^[0-9]+$ ]] || (( base_port < 1024 )) || (( base_port > 65535 )); then
  echo "alloc-worker-port: --base-port must be 1024-65535 (got: $base_port)" >&2
  exit 2
fi
if ! [[ "$ports_per_slot" =~ ^[0-9]+$ ]] || (( ports_per_slot < 1 )); then
  echo "alloc-worker-port: --ports-per-slot must be a positive integer (got: $ports_per_slot)" >&2
  exit 2
fi

# desired_port (if given) must be a valid TCP port
if [[ -n "$desired_port" ]]; then
  if ! [[ "$desired_port" =~ ^[0-9]+$ ]] || (( desired_port < 1 )) || (( desired_port > 65535 )); then
    echo "alloc-worker-port: --desired-port must be 1-65535 (got: $desired_port)" >&2
    exit 2
  fi
fi

# -----------------------------------------------------------------------------
# Compute the slot's range.
# -----------------------------------------------------------------------------
lo=$(( base_port + slot * ports_per_slot ))
hi=$(( lo + ports_per_slot - 1 ))

if (( hi > 65535 )); then
  echo "alloc-worker-port: slot $slot range ($lo-$hi) exceeds 65535" >&2
  echo "alloc-worker-port: shrink --ports-per-slot or lower the slot number" >&2
  exit 2
fi

# -----------------------------------------------------------------------------
# Pick a probe function. Bash's /dev/tcp builtin is always available under
# bash 4+ (both linux + macOS since bash 3.2 in practice), works without
# root, and needs no external dependency. It's our primary probe. `nc -z`
# is a nice-to-have optimisation on systems where the socket probe is
# noticeably faster, but for port availability testing the speed delta is
# negligible — /dev/tcp is the simpler, more portable choice.
# -----------------------------------------------------------------------------
port_in_use() {
  # Returns 0 (true) if the port is currently accepting TCP connections on
  # $probe_host, 1 (false) otherwise. Stderr is suppressed; we only care
  # about the exit code.
  #
  # Uses bash's /dev/tcp builtin in a subshell so the transient fd doesn't
  # leak into the parent process.
  local port="$1"
  if ( exec 3<>"/dev/tcp/$probe_host/$port" ) 2>/dev/null; then
    return 0
  fi
  return 1
}

# -----------------------------------------------------------------------------
# Build the candidate list.
#   - If --desired-port was provided AND is inside [lo, hi], start there.
#   - Otherwise (or after desired_port), walk lo..hi and skip desired.
# -----------------------------------------------------------------------------
candidates=()
if [[ -n "$desired_port" ]] && (( desired_port >= lo )) && (( desired_port <= hi )); then
  candidates+=("$desired_port")
fi
for (( p = lo; p <= hi; p++ )); do
  if [[ -n "$desired_port" ]] && (( p == desired_port )); then
    continue
  fi
  candidates+=("$p")
done

# -----------------------------------------------------------------------------
# Probe in order; print the first free one.
# -----------------------------------------------------------------------------
for p in "${candidates[@]}"; do
  if ! port_in_use "$p"; then
    printf '%s\n' "$p"
    exit 0
  fi
done

echo "alloc-worker-port: no free port in slot $slot range $lo-$hi for service '$service'" >&2
echo "alloc-worker-port: either bump --ports-per-slot, reduce parallelism, or clean up orphan containers" >&2
exit 1

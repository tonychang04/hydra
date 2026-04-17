#!/usr/bin/env bash
#
# Integration smoke: prove two "workers" can bring up the SAME compose file
# in parallel without port collisions, using COMPOSE_PROJECT_NAME (Layer 1)
# + a generated docker-compose.override.yml (Layer 2) per worker.
#
# Requires: docker (running daemon), python3. Skips (exit 0) if either is
# missing or if docker info fails. Gated in golden-cases.example.json by
# the "requires_docker" marker, so it also skips on CI (HYDRA_CI_SKIP_DOCKER).
#
# What the smoke proves:
#   1. Both "workers" bring up their stack successfully (docker compose up -d exit 0).
#   2. docker ps shows two containers, one per worker-project.
#   3. After both workers `docker compose down -v`, docker ps shows no
#      hydra-worker-* containers — no orphan leak (regression check).
#
# How it fakes a "worker": the fixture ships a single docker-compose.yml
# that publishes 5432:5432 for alpine/socat listening on 5432 inside the
# container. The smoke script then:
#   - Stages two tmpdirs (workerA, workerB), each with a copy of the compose
#     file AND an auto-generated docker-compose.override.yml that remaps
#     5432 to a slot-allocated host port from scripts/alloc-worker-port.sh.
#   - Exports COMPOSE_PROJECT_NAME=hydra-worker-a / hydra-worker-b per
#     worker (docker compose requires lowercase project names).
#   - Runs `docker compose up -d` in each.
#   - Verifies both containers listed by `docker ps --filter name=hydra-worker-`.
#   - Tears down both with `docker compose down -v`.
#   - Confirms no orphans.
#
# Exits 0 on PASS (or SKIP when docker is unavailable). Non-zero on FAIL.

set -euo pipefail
export NO_COLOR=1

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd -- "$SCRIPT_DIR/../../.." && pwd)"
ALLOC="$ROOT_DIR/scripts/alloc-worker-port.sh"

# -----------------------------------------------------------------------------
# Precondition checks — SKIP on missing prerequisites.
# -----------------------------------------------------------------------------
if ! command -v docker >/dev/null 2>&1; then
  echo "SKIP: docker CLI not found" >&2
  exit 0
fi
if ! docker info >/dev/null 2>&1; then
  echo "SKIP: docker daemon not reachable (docker info failed)" >&2
  exit 0
fi
if ! command -v python3 >/dev/null 2>&1; then
  echo "SKIP: python3 not available" >&2
  exit 0
fi
if [[ "${HYDRA_CI_SKIP_DOCKER:-0}" == "1" ]]; then
  echo "SKIP: HYDRA_CI_SKIP_DOCKER=1" >&2
  exit 0
fi
[[ -x "$ALLOC" ]] || { echo "FAIL: $ALLOC not executable" >&2; exit 1; }

fail() { echo "FAIL: $*" >&2; exit 1; }

# -----------------------------------------------------------------------------
# Generate a minimal docker-compose.yml. Uses a small, fast image that
# listens on 5432 — alpine + socat, pulling <10MB. If alpine's not cached,
# the pull adds a few seconds to the first run but is cached thereafter.
# -----------------------------------------------------------------------------
make_compose_file() {
  local dest="$1"
  cat >"$dest" <<'YAML'
services:
  fake-pg:
    image: alpine:3.19
    # Install socat once, then listen on 5432 forever.
    command: ["sh", "-c", "apk add --no-cache socat >/dev/null && socat TCP-LISTEN:5432,fork,reuseaddr EXEC:'echo hi'"]
    ports:
      - "5432:5432"
YAML
}

# Generate a docker-compose.override.yml that remaps 5432 to the allocated
# worker-slot port. This mirrors what worker-implementation.md teaches
# workers to do at spawn time.
#
# Uses `ports: !override` (Compose 2.17+) to REPLACE the base compose's
# ports list rather than merge-append. Without !override, the base's
# 5432:5432 binding is still active alongside our remapped binding, so the
# host port collision we're trying to avoid still happens.
make_override_file() {
  local dest="$1"
  local host_port="$2"
  cat >"$dest" <<YAML
services:
  fake-pg:
    ports: !override
      - "$host_port:5432"
YAML
}

# -----------------------------------------------------------------------------
# Cleanup trap — always tear down both projects, even on failure. This is
# the same cleanup invariant workers follow per memory/escalation-faq.md.
# -----------------------------------------------------------------------------
WORKER_A_DIR=""
WORKER_B_DIR=""
cleanup() {
  local rc=$?
  if [[ -n "$WORKER_A_DIR" && -f "$WORKER_A_DIR/docker-compose.yml" ]]; then
    ( cd "$WORKER_A_DIR" && COMPOSE_PROJECT_NAME="hydra-worker-a" \
        docker compose down -v >/dev/null 2>&1 || true )
    rm -rf "$WORKER_A_DIR"
  fi
  if [[ -n "$WORKER_B_DIR" && -f "$WORKER_B_DIR/docker-compose.yml" ]]; then
    ( cd "$WORKER_B_DIR" && COMPOSE_PROJECT_NAME="hydra-worker-b" \
        docker compose down -v >/dev/null 2>&1 || true )
    rm -rf "$WORKER_B_DIR"
  fi
  exit $rc
}
trap cleanup EXIT INT TERM

# -----------------------------------------------------------------------------
# Stage workers A + B.
# -----------------------------------------------------------------------------
WORKER_A_DIR="$(mktemp -d -t hydra-smoke-A.XXXXXX)"
WORKER_B_DIR="$(mktemp -d -t hydra-smoke-B.XXXXXX)"

make_compose_file "$WORKER_A_DIR/docker-compose.yml"
make_compose_file "$WORKER_B_DIR/docker-compose.yml"

# Allocate slot-scoped host ports. Each worker gets a different slot so
# their ranges do not overlap, preventing even accidental collisions.
port_a="$("$ALLOC" --worker-slot 0 --service fake-pg)"
port_b="$("$ALLOC" --worker-slot 1 --service fake-pg)"
[[ -n "$port_a" && -n "$port_b" ]] || fail "port allocation returned empty value(s): a='$port_a' b='$port_b'"
[[ "$port_a" != "$port_b" ]] || fail "allocator gave both workers the same port: $port_a"

make_override_file "$WORKER_A_DIR/docker-compose.override.yml" "$port_a"
make_override_file "$WORKER_B_DIR/docker-compose.override.yml" "$port_b"

echo "Worker A: project=hydra-worker-a dir=$WORKER_A_DIR host_port=$port_a"
echo "Worker B: project=hydra-worker-b dir=$WORKER_B_DIR host_port=$port_b"

# -----------------------------------------------------------------------------
# Bring both up. We do NOT run them in true parallel because docker
# compose is already fast at bringing up a single container, and
# sequential exercise still covers the key invariant: both stacks must
# coexist at the same time.
# -----------------------------------------------------------------------------
( cd "$WORKER_A_DIR" && COMPOSE_PROJECT_NAME="hydra-worker-a" \
    docker compose up -d >/dev/null 2>&1 ) || fail "worker A: docker compose up failed"
( cd "$WORKER_B_DIR" && COMPOSE_PROJECT_NAME="hydra-worker-b" \
    docker compose up -d >/dev/null 2>&1 ) || fail "worker B: docker compose up failed (the collision this ticket fixes)"

# -----------------------------------------------------------------------------
# Assert both containers are running concurrently.
# -----------------------------------------------------------------------------
running_count="$(docker ps --filter 'name=hydra-worker-' --format '{{.Names}}' | wc -l | tr -d ' ')"
[[ "$running_count" == "2" ]] || fail "expected 2 running hydra-worker-* containers, got $running_count"

# -----------------------------------------------------------------------------
# Assert host-port bindings differ — Layer 2 actually did its job.
# -----------------------------------------------------------------------------
bindings="$(docker ps --filter 'name=hydra-worker-' --format '{{.Ports}}')"
grep -qE "[0-9]+->5432" <<<"$bindings" || fail "no 5432 binding visible in docker ps output: $bindings"
grep -qF "$port_a" <<<"$bindings" || fail "port_a=$port_a not in docker ps output: $bindings"
grep -qF "$port_b" <<<"$bindings" || fail "port_b=$port_b not in docker ps output: $bindings"

# -----------------------------------------------------------------------------
# Tear down both stacks — our cleanup trap would catch this, but do it
# explicitly so we can then assert "no orphans" as a regression check.
# -----------------------------------------------------------------------------
( cd "$WORKER_A_DIR" && COMPOSE_PROJECT_NAME="hydra-worker-a" \
    docker compose down -v >/dev/null 2>&1 ) || fail "worker A: docker compose down failed"
( cd "$WORKER_B_DIR" && COMPOSE_PROJECT_NAME="hydra-worker-b" \
    docker compose down -v >/dev/null 2>&1 ) || fail "worker B: docker compose down failed"

# -----------------------------------------------------------------------------
# Regression: no orphans after both workers exit.
# -----------------------------------------------------------------------------
orphans="$(docker ps -a --filter 'name=hydra-worker-' --format '{{.Names}}' | tr '\n' ',' | sed 's/,$//')"
[[ -z "$orphans" ]] || fail "orphan hydra-worker-* containers after cleanup: $orphans"

echo "PASS: two parallel workers on the same compose file, distinct host ports, no orphans"

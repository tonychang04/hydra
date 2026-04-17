#!/usr/bin/env bash
#
# run-e2e.sh — round-trip scripts/hydra-memory-sync.sh through localstack S3.
#
# Flow:
#   1. Start localstack (reuses self-test/fixtures/s3-backend/docker-compose.yml
#      + setup-fixture.sh) — same container name so a running one is reused.
#   2. Build a fake memory tree in a tmpdir (MEMORY.md + learnings-test.md).
#   3. --push the tmpdir to s3://<bucket>/<prefix>/memory/ via localstack.
#   4. List the bucket; expect both files present under memory/.
#   5. Wipe the tmpdir; --pull from the bucket.
#   6. Diff pulled tree against the original → must be bit-for-bit.
#   7. Strict-mode negative test: point at an unroutable endpoint with
#      HYDRA_MEMORY_BACKEND semantics — expect exit 1 from the sync script.
#   8. Teardown runs via trap (if we started localstack).
#
# Exit 0 on full PASS (prints "PASS" as the last line). Non-zero on any
# mismatch / failure.
#
# Skips (exit 2) if docker / aws / jq absent.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
S3_FIXTURE_DIR="$REPO_ROOT/self-test/fixtures/s3-backend"

cd "$SCRIPT_DIR"

# Pre-flight.
if ! command -v docker >/dev/null 2>&1; then
  echo "memory-sync-e2e: docker not on PATH — cannot run this test" >&2
  exit 2
fi
if ! docker info >/dev/null 2>&1; then
  echo "memory-sync-e2e: docker daemon not reachable — cannot run this test" >&2
  exit 2
fi
command -v aws >/dev/null 2>&1 || { echo "memory-sync-e2e: awscli required" >&2; exit 2; }
command -v jq  >/dev/null 2>&1 || { echo "memory-sync-e2e: jq required" >&2; exit 2; }

# Whether WE started localstack (for teardown decision).
STARTED_LOCALSTACK=0

cleanup() {
  local rc=$?
  if (( STARTED_LOCALSTACK == 1 )); then
    echo
    echo "memory-sync-e2e: tearing down localstack (we started it)"
    "$S3_FIXTURE_DIR/teardown-fixture.sh" >/dev/null 2>&1 || true
  fi
  # Remove the work tmpdir.
  if [[ -n "${WORK_DIR:-}" && -d "$WORK_DIR" ]]; then
    rm -rf "$WORK_DIR"
  fi
  exit "$rc"
}
trap cleanup EXIT INT TERM

export HYDRA_AWS_ENDPOINT_URL="http://localhost:4566"
export HYDRA_AWS_REGION="us-east-1"
export HYDRA_S3_BUCKET="hydra-fixture-knowledge"
# Use a prefix DIFFERENT from the s3-backend fixture's prefix so the
# .hydra-mount-marker seed files that setup-fixture.sh touches don't
# pollute this memory tree. Unique per-run via $$ so parallel CI runs
# don't collide.
export HYDRA_S3_PREFIX="memory-sync-e2e-$$"
export AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID:-test}"
export AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY:-test}"

# Note whether localstack is already running.
if ! docker ps --filter name=hydra-s3-backend-fixture --filter status=running --format '{{.Names}}' | grep -q .; then
  STARTED_LOCALSTACK=1
fi

echo "memory-sync-e2e: bringing up localstack (and creating bucket + dummy tables)"
# The s3-backend fixture's setup also creates dynamodb tables we don't use —
# harmless, and reusing it means we don't duplicate bucket-creation logic.
#
# CRITICAL: setup-fixture.sh reads HYDRA_S3_PREFIX from env to decide where
# to write its .hydra-mount-marker seed files. Our exported prefix above
# (memory-sync-e2e-$$) is the round-trip target — if setup-fixture.sh uses
# it, the marker lands inside our tree and the --pull diff fails. Override
# to the s3-backend fixture's own default prefix so the marker stays in its
# own namespace (localstack-fixture/memory/.hydra-mount-marker) and our
# memory-sync-e2e-$$ prefix only contains what --push wrote. Fixes #115.
HYDRA_S3_PREFIX="localstack-fixture" "$S3_FIXTURE_DIR/setup-fixture.sh"

# Build a fake memory tree.
WORK_DIR="$(mktemp -d)"
FAKE_MEM="$WORK_DIR/memory"
PULL_MEM="$WORK_DIR/memory-pulled"
mkdir -p "$FAKE_MEM"
cat >"$FAKE_MEM/MEMORY.md" <<'EOF'
# Memory index (test fixture)

- [learnings](learnings-test.md) — test fixture for memory-sync-roundtrip
EOF
cat >"$FAKE_MEM/learnings-test.md" <<'EOF'
---
name: memory-sync-e2e fixture
description: synthetic learnings file used by memory-sync-roundtrip self-test
type: project
---

## Conventions

- 2026-04-17 — this file exists only as a test fixture; delete if you see it in real memory.
EOF

echo "memory-sync-e2e: fake memory tree ready at $FAKE_MEM"

# ---- 1. Push ----
echo "memory-sync-e2e: --push $FAKE_MEM -> s3://$HYDRA_S3_BUCKET/$HYDRA_S3_PREFIX/memory/"
"$REPO_ROOT/scripts/hydra-memory-sync.sh" --push --memory-dir "$FAKE_MEM"

# ---- 2. Verify remote ----
echo "memory-sync-e2e: listing remote"
remote_list="$(aws --endpoint-url "$HYDRA_AWS_ENDPOINT_URL" --region "$HYDRA_AWS_REGION" \
                   s3 ls "s3://$HYDRA_S3_BUCKET/$HYDRA_S3_PREFIX/memory/" --recursive)"
echo "$remote_list"

# Every file we wrote must appear in the remote listing.
for f in MEMORY.md learnings-test.md; do
  if ! grep -q "$f" <<<"$remote_list"; then
    echo "memory-sync-e2e: FAIL — $f missing from remote after push" >&2
    exit 1
  fi
done

# ---- 3. Pull into a clean dir ----
mkdir -p "$PULL_MEM"
echo "memory-sync-e2e: --pull s3://$HYDRA_S3_BUCKET/$HYDRA_S3_PREFIX/memory/ -> $PULL_MEM"
"$REPO_ROOT/scripts/hydra-memory-sync.sh" --pull --memory-dir "$PULL_MEM"

# ---- 4. Diff ----
echo "memory-sync-e2e: diffing original tree vs pulled tree"
if ! diff -r "$FAKE_MEM" "$PULL_MEM"; then
  echo "memory-sync-e2e: FAIL — pulled tree differs from pushed tree" >&2
  exit 1
fi

# ---- 5. Strict-mode negative test ----
echo "memory-sync-e2e: strict-mode negative path (unreachable endpoint must exit 1)"
if HYDRA_AWS_ENDPOINT_URL="http://127.0.0.1:1" \
   "$REPO_ROOT/scripts/hydra-memory-sync.sh" --push --memory-dir "$FAKE_MEM" >/dev/null 2>&1; then
  echo "memory-sync-e2e: FAIL — sync against unreachable endpoint unexpectedly succeeded" >&2
  exit 1
fi
echo "memory-sync-e2e: strict-mode negative OK (exit != 0 on unreachable endpoint)"

echo "memory-sync-e2e: roundtrip OK"
echo "PASS"

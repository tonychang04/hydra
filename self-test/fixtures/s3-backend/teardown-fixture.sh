#!/usr/bin/env bash
#
# teardown-fixture.sh — stop and remove the localstack container used by
# run-e2e.sh. Data is not persisted between runs, so nothing else to clean.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

echo "teardown-fixture: stopping localstack"
docker compose -f "$SCRIPT_DIR/docker-compose.yml" down --remove-orphans

echo "teardown-fixture: done"

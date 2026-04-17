#!/usr/bin/env bash
#
# setup-fixture.sh — bring up localstack (if needed), then create the S3
# bucket + DynamoDB tables the Phase 2 adapters expect.
#
# Safe to re-run: bucket / tables are created idempotently.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

ENDPOINT="${HYDRA_AWS_ENDPOINT_URL:-http://localhost:4566}"
REGION="${HYDRA_AWS_REGION:-us-east-1}"
BUCKET="${HYDRA_S3_BUCKET:-hydra-fixture-knowledge}"
PREFIX="${HYDRA_S3_PREFIX:-localstack-fixture}"

# Tables — match the names from docs/phase2-s3-knowledge-store.md.
TABLES=(
  "commander-active"
  "commander-budget"
  "commander-memory-citations"
)

command -v aws >/dev/null 2>&1 || { echo "setup-fixture: awscli required" >&2; exit 1; }

# Localstack accepts any creds; just make sure some are set to satisfy awscli.
export AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID:-test}"
export AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY:-test}"
export AWS_DEFAULT_REGION="$REGION"

start_localstack() {
  if docker ps --filter name=hydra-s3-backend-fixture --filter status=running --format '{{.Names}}' | grep -q .; then
    echo "setup-fixture: localstack already running"
    return 0
  fi
  echo "setup-fixture: starting localstack"
  docker compose -f "$SCRIPT_DIR/docker-compose.yml" up -d

  # Wait for health.
  for i in {1..30}; do
    if curl -sf "$ENDPOINT/_localstack/health" >/dev/null 2>&1; then
      echo "setup-fixture: localstack healthy"
      return 0
    fi
    sleep 1
  done
  echo "setup-fixture: localstack did not become healthy within 30s" >&2
  return 1
}

create_bucket() {
  if aws --endpoint-url "$ENDPOINT" --region "$REGION" \
       s3api head-bucket --bucket "$BUCKET" >/dev/null 2>&1; then
    echo "setup-fixture: bucket $BUCKET already exists"
    return 0
  fi
  echo "setup-fixture: creating bucket $BUCKET"
  aws --endpoint-url "$ENDPOINT" --region "$REGION" \
      s3api create-bucket --bucket "$BUCKET" >/dev/null
  # Touch the per-instance prefix so `aws s3 ls` shows the tree.
  printf 'phase2-fixture\n' \
    | aws --endpoint-url "$ENDPOINT" --region "$REGION" \
          s3 cp - "s3://$BUCKET/$PREFIX/memory/.hydra-mount-marker" >/dev/null
  printf 'phase2-fixture\n' \
    | aws --endpoint-url "$ENDPOINT" --region "$REGION" \
          s3 cp - "s3://$BUCKET/$PREFIX/logs/.hydra-mount-marker" >/dev/null
}

create_table() {
  local table="$1"
  if aws --endpoint-url "$ENDPOINT" --region "$REGION" \
       dynamodb describe-table --table-name "$table" >/dev/null 2>&1; then
    echo "setup-fixture: table $table already exists"
    return 0
  fi
  echo "setup-fixture: creating table $table"
  aws --endpoint-url "$ENDPOINT" --region "$REGION" \
      dynamodb create-table \
      --table-name "$table" \
      --attribute-definitions AttributeName=id,AttributeType=S \
      --key-schema AttributeName=id,KeyType=HASH \
      --billing-mode PAY_PER_REQUEST >/dev/null
}

start_localstack
create_bucket
for t in "${TABLES[@]}"; do
  create_table "$t"
done

echo "setup-fixture: ready."
echo "  endpoint:  $ENDPOINT"
echo "  region:    $REGION"
echo "  bucket:    $BUCKET"
echo "  prefix:    $PREFIX"
echo "  tables:    ${TABLES[*]}"

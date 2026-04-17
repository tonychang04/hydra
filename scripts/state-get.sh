#!/usr/bin/env bash
#
# state-get.sh — read a hydra state blob, choosing local JSON files or a
# remote DynamoDB table based on $HYDRA_STATE_BACKEND.
#
# Phase 1 (default): HYDRA_STATE_BACKEND=local — just `cat state/<key>.json`.
# Phase 2 (opt-in):  HYDRA_STATE_BACKEND=dynamodb — aws dynamodb get-item on
#                    the mapped table for <key>, and print its JSON payload.
#
# See docs/phase2-s3-knowledge-store.md and
# docs/specs/2026-04-16-s3-knowledge-store.md for the rationale.
#
# Commander (and any script in the hot path) should call this rather than
# touching state/*.json directly — that way flipping to Phase 2 is a single
# env-var change with no commander logic rewrites.

set -euo pipefail

STATE_DIR_DEFAULT="./state"

usage() {
  cat <<'EOF'
Usage: state-get.sh --key <name> [--state-dir <path>] [--backend <local|dynamodb>]

Options:
  --key <name>          Logical state key. Maps to state/<name>.json locally,
                        or to the DynamoDB table named by
                        HYDRA_DDB_TABLE_<NAME_UPPER> (falls back to
                        "commander-<name>"). Valid examples: active, budget,
                        memory-citations.
  --state-dir <path>    Override local state dir (default: ./state).
  --backend <mode>      Override $HYDRA_STATE_BACKEND. One of: local, dynamodb.
  -h, --help            Show this help.

Environment:
  HYDRA_STATE_BACKEND   local (default) | dynamodb
  HYDRA_AWS_REGION      Required when backend=dynamodb. No default — never
                        hardcoded.
  HYDRA_DDB_TABLE_<KEY> Optional per-key table name override (uppercase key,
                        hyphens -> underscores). Defaults to
                        "commander-<key>".
  HYDRA_DDB_PK          Partition-key attribute name (default: "id").
  HYDRA_DDB_PK_VALUE    Partition-key value (default: "singleton").
                        Hydra stores one row per logical blob, keyed by this.

Output:
  JSON on stdout (the state payload).

Exit codes:
  0   success
  1   backend/read failure (message on stderr)
  2   usage error
EOF
}

key=""
state_dir=""
backend=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --key)
      [[ $# -ge 2 ]] || { echo "state-get: --key needs a value" >&2; usage >&2; exit 2; }
      key="$2"
      shift 2
      ;;
    --state-dir)
      [[ $# -ge 2 ]] || { echo "state-get: --state-dir needs a value" >&2; usage >&2; exit 2; }
      state_dir="$2"
      shift 2
      ;;
    --backend)
      [[ $# -ge 2 ]] || { echo "state-get: --backend needs a value" >&2; usage >&2; exit 2; }
      backend="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "state-get: unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ -z "$key" ]]; then
  echo "state-get: --key is required" >&2
  usage >&2
  exit 2
fi

[[ -z "$state_dir" ]] && state_dir="$STATE_DIR_DEFAULT"
[[ -z "$backend"   ]] && backend="${HYDRA_STATE_BACKEND:-local}"

case "$backend" in
  local)
    file="$state_dir/$key.json"
    if [[ ! -f "$file" ]]; then
      echo "state-get: local state file not found: $file" >&2
      exit 1
    fi
    cat "$file"
    ;;
  dynamodb)
    command -v aws >/dev/null 2>&1 || {
      echo "state-get: aws CLI not found; install awscli to use the dynamodb backend" >&2
      exit 1
    }
    command -v jq >/dev/null 2>&1 || {
      echo "state-get: jq not found; install jq to use the dynamodb backend" >&2
      exit 1
    }
    if [[ -z "${HYDRA_AWS_REGION:-}" ]]; then
      echo "state-get: HYDRA_AWS_REGION must be set for backend=dynamodb" >&2
      exit 1
    fi
    key_upper="$(printf '%s' "$key" | tr '[:lower:]-' '[:upper:]_')"
    table_var="HYDRA_DDB_TABLE_${key_upper}"
    table="${!table_var:-commander-$key}"
    pk_name="${HYDRA_DDB_PK:-id}"
    pk_value="${HYDRA_DDB_PK_VALUE:-singleton}"

    # Optional localstack / custom endpoint support (used by the self-test
    # fixture under self-test/fixtures/s3-backend/).
    endpoint_args=()
    if [[ -n "${HYDRA_AWS_ENDPOINT_URL:-}" ]]; then
      endpoint_args=(--endpoint-url "$HYDRA_AWS_ENDPOINT_URL")
    fi

    raw="$(aws "${endpoint_args[@]}" \
            --region "$HYDRA_AWS_REGION" \
            dynamodb get-item \
            --table-name "$table" \
            --key "{\"$pk_name\":{\"S\":\"$pk_value\"}}" \
            --output json 2>/dev/null || true)"

    if [[ -z "$raw" ]]; then
      echo "state-get: dynamodb get-item returned nothing for table=$table key=$pk_value" >&2
      exit 1
    fi

    # Extract the stringified payload stored under attribute "payload"
    # (matches state-put.sh's write shape). If absent, emit "{}" so callers
    # can treat a missing row as empty state.
    payload="$(printf '%s' "$raw" | jq -r '.Item.payload.S // empty')"
    if [[ -z "$payload" ]]; then
      echo '{}'
    else
      printf '%s\n' "$payload"
    fi
    ;;
  *)
    echo "state-get: unknown backend: $backend (expected local|dynamodb)" >&2
    exit 2
    ;;
esac

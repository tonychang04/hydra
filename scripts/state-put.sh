#!/usr/bin/env bash
#
# state-put.sh — write a hydra state blob, choosing local JSON files or a
# remote DynamoDB table based on $HYDRA_STATE_BACKEND.
#
# Phase 1 (default): HYDRA_STATE_BACKEND=local — write JSON to
#                    state/<key>.json (atomic via tmp + mv).
# Phase 2 (opt-in):  HYDRA_STATE_BACKEND=dynamodb — aws dynamodb put-item on
#                    the mapped table with the JSON payload stored under
#                    attribute "payload" (string) alongside the partition
#                    key and an updated_at ISO-8601 attribute.
#
# See docs/phase2-s3-knowledge-store.md and
# docs/specs/2026-04-16-s3-knowledge-store.md.

set -euo pipefail

STATE_DIR_DEFAULT="./state"

usage() {
  cat <<'EOF'
Usage: state-put.sh --key <name> [--state-dir <path>] [--backend <local|dynamodb>] [<payload-file>]

Reads JSON payload from <payload-file> if supplied, else from stdin. The
payload is written atomically to the backing store.

Options:
  --key <name>          Logical state key. Maps to state/<name>.json locally,
                        or to DynamoDB table HYDRA_DDB_TABLE_<NAME_UPPER>
                        (falls back to "commander-<name>").
  --state-dir <path>    Override local state dir (default: ./state).
  --backend <mode>      Override $HYDRA_STATE_BACKEND.
  -h, --help            Show this help.

Environment:
  HYDRA_STATE_BACKEND   local (default) | dynamodb
  HYDRA_AWS_REGION      Required when backend=dynamodb. Never hardcoded.
  HYDRA_DDB_TABLE_<KEY> Optional per-key table override.
  HYDRA_DDB_PK          Partition-key attribute name (default: "id").
  HYDRA_DDB_PK_VALUE    Partition-key value (default: "singleton").
  HYDRA_AWS_ENDPOINT_URL Optional endpoint (for localstack fixtures).

Exit codes:
  0   success
  1   backend/write failure (message on stderr)
  2   usage error / payload not valid JSON
EOF
}

key=""
state_dir=""
backend=""
payload_file=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --key)
      [[ $# -ge 2 ]] || { echo "state-put: --key needs a value" >&2; usage >&2; exit 2; }
      key="$2"
      shift 2
      ;;
    --state-dir)
      [[ $# -ge 2 ]] || { echo "state-put: --state-dir needs a value" >&2; usage >&2; exit 2; }
      state_dir="$2"
      shift 2
      ;;
    --backend)
      [[ $# -ge 2 ]] || { echo "state-put: --backend needs a value" >&2; usage >&2; exit 2; }
      backend="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --)
      shift
      break
      ;;
    -*)
      echo "state-put: unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
    *)
      if [[ -n "$payload_file" ]]; then
        echo "state-put: only one positional payload file allowed" >&2
        exit 2
      fi
      payload_file="$1"
      shift
      ;;
  esac
done

if [[ -z "$key" ]]; then
  echo "state-put: --key is required" >&2
  usage >&2
  exit 2
fi

[[ -z "$state_dir" ]] && state_dir="$STATE_DIR_DEFAULT"
[[ -z "$backend"   ]] && backend="${HYDRA_STATE_BACKEND:-local}"

command -v jq >/dev/null 2>&1 || {
  echo "state-put: jq is required" >&2
  exit 1
}

# Read payload.
if [[ -n "$payload_file" ]]; then
  if [[ ! -f "$payload_file" ]]; then
    echo "state-put: payload file not found: $payload_file" >&2
    exit 2
  fi
  payload="$(cat "$payload_file")"
else
  payload="$(cat)"
fi

# Validate payload as JSON before committing.
if ! printf '%s' "$payload" | jq -e . >/dev/null 2>&1; then
  echo "state-put: payload is not valid JSON" >&2
  exit 2
fi

case "$backend" in
  local)
    mkdir -p "$state_dir"
    file="$state_dir/$key.json"
    tmp="$(mktemp "${file}.XXXXXX")"
    # shellcheck disable=SC2064
    trap "rm -f '$tmp'" EXIT
    printf '%s\n' "$payload" > "$tmp"
    mv "$tmp" "$file"
    trap - EXIT
    ;;
  dynamodb)
    command -v aws >/dev/null 2>&1 || {
      echo "state-put: aws CLI not found; install awscli to use the dynamodb backend" >&2
      exit 1
    }
    if [[ -z "${HYDRA_AWS_REGION:-}" ]]; then
      echo "state-put: HYDRA_AWS_REGION must be set for backend=dynamodb" >&2
      exit 1
    fi
    key_upper="$(printf '%s' "$key" | tr '[:lower:]-' '[:upper:]_')"
    table_var="HYDRA_DDB_TABLE_${key_upper}"
    table="${!table_var:-commander-$key}"
    pk_name="${HYDRA_DDB_PK:-id}"
    pk_value="${HYDRA_DDB_PK_VALUE:-singleton}"
    now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

    # Build the Item JSON via jq (safer than string concat — payload may
    # contain quotes, newlines, etc).
    item="$(jq -n \
      --arg pk "$pk_name" \
      --arg pkv "$pk_value" \
      --arg payload "$payload" \
      --arg updated_at "$now" \
      '{
         ($pk): {S: $pkv},
         payload: {S: $payload},
         updated_at: {S: $updated_at}
       }')"

    endpoint_args=()
    if [[ -n "${HYDRA_AWS_ENDPOINT_URL:-}" ]]; then
      endpoint_args=(--endpoint-url "$HYDRA_AWS_ENDPOINT_URL")
    fi

    if ! aws "${endpoint_args[@]}" \
          --region "$HYDRA_AWS_REGION" \
          dynamodb put-item \
          --table-name "$table" \
          --item "$item" >/dev/null; then
      echo "state-put: dynamodb put-item failed for table=$table key=$pk_value" >&2
      exit 1
    fi
    ;;
  *)
    echo "state-put: unknown backend: $backend (expected local|dynamodb)" >&2
    exit 2
    ;;
esac

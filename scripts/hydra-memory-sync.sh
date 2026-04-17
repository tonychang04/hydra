#!/usr/bin/env bash
#
# hydra-memory-sync.sh — bidirectional `aws s3 sync` between the local memory
# directory (./memory/ or $HYDRA_EXTERNAL_MEMORY_DIR) and
# s3://$HYDRA_S3_BUCKET/$HYDRA_S3_PREFIX/memory/.
#
# Two modes:
#   --push  local -> S3   (call after a memory-layer write completes)
#   --pull  S3 -> local   (call once at commander session start)
#
# Design decisions (see docs/specs/2026-04-17-dual-mode-memory.md):
#   - Uses `aws s3 sync`, not `mount-s3`. Simpler, no daemon, no FUSE.
#   - `--delete` only on pull. NEVER on push — a buggy laptop push should
#     never wipe the remote memory store.
#   - Excludes `.git*` and `archive/**` defensively.
#   - Idempotent: repeated calls with no delta are ~100ms no-ops.
#
# Backend selection (honored by the memory-layer scripts that call this):
#   HYDRA_MEMORY_BACKEND=local        — sync not called at all (default, Phase 1)
#   HYDRA_MEMORY_BACKEND=s3           — sync failure is a warning, not fatal
#   HYDRA_MEMORY_BACKEND=s3-strict    — sync failure is fatal
#
# This script itself does NOT read HYDRA_MEMORY_BACKEND — it just exits non-zero
# on failure and lets callers decide the severity. That keeps it composable
# (callers can use `|| true` for fail-soft, or propagate the exit code).

set -euo pipefail

MEMORY_DIR_DEFAULT="./memory"

usage() {
  cat <<'EOF'
Usage: hydra-memory-sync.sh [--push | --pull] [OPTIONS]

Required (one of):
  --push                     Sync local memory dir TO S3.
  --pull                     Sync S3 TO local memory dir (uses --delete to
                             mirror remote exactly).

Options:
  --memory-dir <path>        Override the memory directory. Default:
                             $HYDRA_EXTERNAL_MEMORY_DIR, falls back to ./memory.
  --bucket <name>            Override $HYDRA_S3_BUCKET.
  --prefix <string>          Override $HYDRA_S3_PREFIX.
  --region <name>            Override $HYDRA_AWS_REGION.
  --endpoint-url <url>       Override $HYDRA_AWS_ENDPOINT_URL (for localstack).
  --dry-run                  Pass --dryrun to aws s3 sync; no files transfer.
  -h, --help                 Show this help.

Required environment (unless overridden by the matching --flag):
  HYDRA_S3_BUCKET            Target bucket.
  HYDRA_S3_PREFIX            Per-instance prefix (e.g. "prod", "gary-laptop").
  HYDRA_AWS_REGION           Bucket region.

Optional environment:
  HYDRA_AWS_ENDPOINT_URL     Alternate endpoint (localstack, MinIO, etc).
  HYDRA_EXTERNAL_MEMORY_DIR  Memory dir override (same as --memory-dir).
  HYDRA_MEMORY_SYNC_LOG      Append-only log path. Default: logs/memory-sync.log
                             relative to the current working directory.

Exit codes:
  0    success (sync completed; may have been a no-op)
  1    sync failed (S3 unreachable, auth, bucket missing, etc.)
  2    usage error (missing direction flag, missing required env/flag, bad arg)

Examples:
  # Push after a memory write, from a local commander
  HYDRA_S3_BUCKET=my-bucket HYDRA_S3_PREFIX=gary-laptop HYDRA_AWS_REGION=us-east-1 \
    scripts/hydra-memory-sync.sh --push

  # Pull at session start from a cloud commander
  scripts/hydra-memory-sync.sh --pull

  # Dry-run push against a localstack fixture
  HYDRA_AWS_ENDPOINT_URL=http://localhost:4566 \
    scripts/hydra-memory-sync.sh --push --dry-run
EOF
}

direction=""
memory_dir=""
bucket=""
prefix=""
region=""
endpoint_url=""
dry_run=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --push)
      if [[ -n "$direction" ]]; then
        echo "hydra-memory-sync: --push and --pull are mutually exclusive" >&2
        exit 2
      fi
      direction="push"
      shift
      ;;
    --pull)
      if [[ -n "$direction" ]]; then
        echo "hydra-memory-sync: --push and --pull are mutually exclusive" >&2
        exit 2
      fi
      direction="pull"
      shift
      ;;
    --memory-dir)
      [[ $# -ge 2 ]] || { echo "hydra-memory-sync: --memory-dir needs a value" >&2; exit 2; }
      memory_dir="$2"; shift 2
      ;;
    --bucket)
      [[ $# -ge 2 ]] || { echo "hydra-memory-sync: --bucket needs a value" >&2; exit 2; }
      bucket="$2"; shift 2
      ;;
    --prefix)
      [[ $# -ge 2 ]] || { echo "hydra-memory-sync: --prefix needs a value" >&2; exit 2; }
      prefix="$2"; shift 2
      ;;
    --region)
      [[ $# -ge 2 ]] || { echo "hydra-memory-sync: --region needs a value" >&2; exit 2; }
      region="$2"; shift 2
      ;;
    --endpoint-url)
      [[ $# -ge 2 ]] || { echo "hydra-memory-sync: --endpoint-url needs a value" >&2; exit 2; }
      endpoint_url="$2"; shift 2
      ;;
    --dry-run)
      dry_run=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --)
      shift
      break
      ;;
    *)
      echo "hydra-memory-sync: unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ -z "$direction" ]]; then
  echo "hydra-memory-sync: must specify --push or --pull" >&2
  usage >&2
  exit 2
fi

# Resolve defaults from env.
if [[ -z "$memory_dir" ]]; then
  memory_dir="${HYDRA_EXTERNAL_MEMORY_DIR:-$MEMORY_DIR_DEFAULT}"
fi
if [[ -z "$bucket" ]]; then
  bucket="${HYDRA_S3_BUCKET:-}"
fi
if [[ -z "$prefix" ]]; then
  prefix="${HYDRA_S3_PREFIX:-}"
fi
if [[ -z "$region" ]]; then
  region="${HYDRA_AWS_REGION:-}"
fi
if [[ -z "$endpoint_url" ]]; then
  endpoint_url="${HYDRA_AWS_ENDPOINT_URL:-}"
fi

# Validate required inputs.
missing=()
[[ -z "$bucket" ]]  && missing+=("HYDRA_S3_BUCKET or --bucket")
[[ -z "$prefix" ]]  && missing+=("HYDRA_S3_PREFIX or --prefix")
[[ -z "$region" ]]  && missing+=("HYDRA_AWS_REGION or --region")
if (( ${#missing[@]} > 0 )); then
  echo "hydra-memory-sync: missing required config: ${missing[*]}" >&2
  echo "Either set the env var or pass the flag. See --help." >&2
  exit 2
fi

# Strip trailing slashes from prefix (aws s3 sync cares).
prefix="${prefix%/}"

# Verify awscli is installed.
if ! command -v aws >/dev/null 2>&1; then
  echo "hydra-memory-sync: awscli not on PATH — install with 'brew install awscli' or your distro's package" >&2
  exit 1
fi

# Ensure memory dir exists on push (we're uploading from it) — and on pull
# (we're writing into it). On pull, create if absent; on push, error if absent
# (nothing to push; operator is pointing at the wrong dir).
if [[ "$direction" == "push" ]]; then
  if [[ ! -d "$memory_dir" ]]; then
    echo "hydra-memory-sync: memory dir does not exist: $memory_dir" >&2
    echo "(nothing to push; check --memory-dir or HYDRA_EXTERNAL_MEMORY_DIR)" >&2
    exit 1
  fi
else
  mkdir -p "$memory_dir"
fi

s3_uri="s3://${bucket}/${prefix}/memory/"

# Build aws command.
aws_cmd=(aws s3 sync)
if [[ -n "$endpoint_url" ]]; then
  aws_cmd+=(--endpoint-url "$endpoint_url")
fi
aws_cmd+=(--region "$region")

# Direction-specific args.
if [[ "$direction" == "push" ]]; then
  aws_cmd+=("$memory_dir/" "$s3_uri")
  # NO --delete on push: a local `rm -rf memory/` should NOT wipe the remote.
else
  aws_cmd+=("$s3_uri" "$memory_dir/")
  # --delete on pull: remote is the source of truth for the pre-session state.
  aws_cmd+=(--delete)
fi

# Safety excludes. Same on push and pull.
aws_cmd+=(--exclude ".git*")
aws_cmd+=(--exclude "archive/**")

if $dry_run; then
  aws_cmd+=(--dryrun)
fi

# Log what we're about to do.
ts="$(date -u +%FT%TZ)"
log_path="${HYDRA_MEMORY_SYNC_LOG:-logs/memory-sync.log}"
log_dir="$(dirname "$log_path")"
[[ -d "$log_dir" ]] || mkdir -p "$log_dir" 2>/dev/null || true

log_msg="[$ts] hydra-memory-sync: --$direction $memory_dir <-> $s3_uri"
if $dry_run; then
  log_msg="$log_msg (dry-run)"
fi
echo "$log_msg"
if [[ -w "$log_dir" ]] || [[ ! -e "$log_dir" ]]; then
  echo "$log_msg" >> "$log_path" 2>/dev/null || true
fi

# Run the sync. `aws s3 sync` prints per-file "(dry-run) upload: ... to ..." or
# "upload: ... to ..." lines, which we preserve (tee'd to the same log).
rc=0
if [[ -w "$log_dir" ]] || [[ ! -e "$log_dir" ]]; then
  "${aws_cmd[@]}" 2>&1 | tee -a "$log_path" || rc=$?
else
  "${aws_cmd[@]}" || rc=$?
fi

# `tee` makes the exit code come from itself; capture `aws`'s rc via PIPESTATUS.
# On bash 3.2 (macOS default), ${PIPESTATUS[0]:-0} is the safe idiom.
if (( rc == 0 )); then
  # Tee was clean; check the pipeline's head.
  pipe_rc="${PIPESTATUS[0]:-0}"
  if (( pipe_rc != 0 )); then
    rc="$pipe_rc"
  fi
fi

if (( rc != 0 )); then
  echo "hydra-memory-sync: FAIL ($direction) — aws s3 sync exited $rc" >&2
  echo "hydra-memory-sync: check AWS creds, bucket/prefix, and connectivity to $s3_uri" >&2
  exit 1
fi

echo "hydra-memory-sync: OK ($direction)"
exit 0

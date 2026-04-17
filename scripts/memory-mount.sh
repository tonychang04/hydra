#!/usr/bin/env bash
#
# memory-mount.sh — operator-invoked helper that mounts the Phase 2 S3
# knowledge-store bucket at $HYDRA_EXTERNAL_MEMORY_DIR using
# Mountpoint-for-Amazon-S3 (`mount-s3`). Phase 1 users never run this.
#
# This script DOES NOT provision AWS resources. The operator must have
# already created:
#   - the S3 bucket (name in $HYDRA_S3_BUCKET)
#   - the IAM role the host assumes (see INSTALL.md "Phase 2" section)
#   - the KMS key policy (SSE-KMS with an operator-owned key)
# and installed mount-s3 via the AWS instructions:
#   https://github.com/awslabs/mountpoint-s3
#
# What this script does:
#   1. Preflights: mount-s3 installed; required env vars set; target dir not
#      already a mountpoint.
#   2. Creates $HYDRA_EXTERNAL_MEMORY_DIR if absent.
#   3. Runs `mount-s3 <bucket> <dir>` with the configured prefix. The
#      resulting filesystem contains memory/ and logs/ subtrees under
#      s3://<bucket>/<prefix>/.
#   4. Prints next-step validation instructions.

set -euo pipefail

usage() {
  cat <<'EOF'
Usage: memory-mount.sh [--dry-run]

Options:
  --dry-run   Print the mount-s3 command that WOULD run, but don't execute it.
  -h, --help  Show this help.

Required environment:
  HYDRA_S3_BUCKET            S3 bucket holding memory/ and logs/.
  HYDRA_S3_PREFIX            Per-instance prefix inside the bucket (e.g. the
                             commander instance id — "dev", "prod",
                             "gary-laptop", etc).
  HYDRA_EXTERNAL_MEMORY_DIR  Local mountpoint. Must exist or be creatable.
  HYDRA_AWS_REGION           Region the bucket lives in.

Optional environment:
  HYDRA_S3_MOUNT_OPTS        Extra flags passed verbatim to mount-s3.
                             Recommended defaults for Hydra's workload:
                               --allow-overwrite \
                               --file-mode=0644 \
                               --dir-mode=0755
                             (memory and logs are append-ish; workers need
                             overwrite permission on their own files).

Exit codes:
  0   success — mount active, or dry-run printed
  1   missing dependency (mount-s3), required env var, or mount failed
  2   usage error

Validation after mounting:
  ls "$HYDRA_EXTERNAL_MEMORY_DIR"/memory/
  ls "$HYDRA_EXTERNAL_MEMORY_DIR"/logs/
  ./scripts/state-get.sh --key active   # reads DynamoDB (if configured)

Unmount when done (macOS):
  umount "$HYDRA_EXTERNAL_MEMORY_DIR"
Unmount when done (Linux):
  fusermount -u "$HYDRA_EXTERNAL_MEMORY_DIR"
EOF
}

dry_run=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) dry_run=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "memory-mount: unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

# --- Preflight checks ---

mount_s3_present=true
if ! command -v mount-s3 >/dev/null 2>&1; then
  mount_s3_present=false
  # In dry-run we still want to print the command, so we only FAIL here if
  # this is a real mount attempt.
  cat >&2 <<'ERR'
memory-mount: mount-s3 is not installed or not on PATH.

Mountpoint-for-Amazon-S3 is an AWS tool; Hydra does not bundle it. Install
it once per operator machine:

  macOS:
    brew install --cask mountpoint-s3
    # or download the signed package from:
    #   https://s3.amazonaws.com/mountpoint-s3-release/latest/x86_64/mount-s3.pkg

  Linux (Amazon Linux, Debian, Ubuntu, RHEL):
    see https://github.com/awslabs/mountpoint-s3/blob/main/doc/INSTALL.md

After install, verify:
  mount-s3 --version

Then re-run this script.
ERR
  if ! $dry_run; then
    exit 1
  fi
  echo "memory-mount: (continuing with --dry-run despite missing mount-s3)" >&2
fi

missing=()
[[ -z "${HYDRA_S3_BUCKET:-}" ]]            && missing+=("HYDRA_S3_BUCKET")
[[ -z "${HYDRA_S3_PREFIX:-}" ]]            && missing+=("HYDRA_S3_PREFIX")
[[ -z "${HYDRA_EXTERNAL_MEMORY_DIR:-}" ]]  && missing+=("HYDRA_EXTERNAL_MEMORY_DIR")
[[ -z "${HYDRA_AWS_REGION:-}" ]]           && missing+=("HYDRA_AWS_REGION")

if (( ${#missing[@]} > 0 )); then
  echo "memory-mount: missing required env vars: ${missing[*]}" >&2
  echo "Set them in .env.hydra-phase2 (copy from .env.hydra-phase2.example) and re-run." >&2
  exit 1
fi

# Make sure the mountpoint is ready.
if [[ ! -d "$HYDRA_EXTERNAL_MEMORY_DIR" ]]; then
  echo "memory-mount: creating mountpoint $HYDRA_EXTERNAL_MEMORY_DIR"
  mkdir -p "$HYDRA_EXTERNAL_MEMORY_DIR"
fi

# Don't remount on top of an existing mount.
if mount | grep -Eq " on $HYDRA_EXTERNAL_MEMORY_DIR( |$|\()"; then
  echo "memory-mount: $HYDRA_EXTERNAL_MEMORY_DIR already appears mounted — nothing to do." >&2
  echo "Unmount first if you want to remount with new options." >&2
  exit 0
fi

# Build the mount-s3 invocation. The AWS CLI style varies between mount-s3
# releases; the operator can override via HYDRA_S3_MOUNT_OPTS.
default_opts="--prefix ${HYDRA_S3_PREFIX%/}/ --region $HYDRA_AWS_REGION --allow-overwrite --file-mode 0644 --dir-mode 0755"
mount_opts="${HYDRA_S3_MOUNT_OPTS:-$default_opts}"

# shellcheck disable=SC2206
cmd=(mount-s3 $mount_opts "$HYDRA_S3_BUCKET" "$HYDRA_EXTERNAL_MEMORY_DIR")

if $dry_run; then
  echo "memory-mount: dry-run — would execute:"
  printf '  %q ' "${cmd[@]}"
  printf '\n'
  exit 0
fi

echo "memory-mount: mounting s3://$HYDRA_S3_BUCKET/${HYDRA_S3_PREFIX%/}/ -> $HYDRA_EXTERNAL_MEMORY_DIR"
if ! "${cmd[@]}"; then
  echo "memory-mount: mount-s3 returned non-zero; check IAM role, bucket policy, and KMS key access" >&2
  exit 1
fi

cat <<EOF
memory-mount: mounted.

Next steps:
  ls '$HYDRA_EXTERNAL_MEMORY_DIR/memory/'       # should list shared/ + learnings files
  ls '$HYDRA_EXTERNAL_MEMORY_DIR/logs/'         # should list per-ticket JSON (may be empty on first mount)
  ./scripts/state-get.sh --key active           # should return active.json from DynamoDB

If any of those fail:
  - Double-check the IAM role has s3:ListBucket + s3:GetObject + s3:PutObject
    on arn:aws:s3:::$HYDRA_S3_BUCKET/${HYDRA_S3_PREFIX%/}/*
  - Confirm the KMS key grant is in place for the role.
  - Confirm HYDRA_STATE_BACKEND=dynamodb is exported in your shell.
EOF

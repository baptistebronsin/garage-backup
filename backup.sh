#!/bin/bash

set -o pipefail

# --- Source: Garage instance ---
: "${GARAGE_ENDPOINT:?Missing variable GARAGE_ENDPOINT}"
: "${GARAGE_REGION:?Missing variable GARAGE_REGION}"
: "${GARAGE_ACCESS_KEY_ID:?Missing variable GARAGE_ACCESS_KEY_ID}"
: "${GARAGE_SECRET_ACCESS_KEY:?Missing variable GARAGE_SECRET_ACCESS_KEY}"
: "${GARAGE_BUCKET:?Missing variable GARAGE_BUCKET}"

# --- Destination: other S3 ---
: "${S3_ENDPOINT:?Missing variable S3_ENDPOINT}"
: "${S3_ACCESS_KEY:?Missing variable S3_ACCESS_KEY}"
: "${S3_SECRET_ACCESS_KEY:?Missing variable S3_SECRET_ACCESS_KEY}"
: "${S3_BUCKET:?Missing variable S3_BUCKET}"
: "${DEST_PATH:=}"

# --- Compression ---
: "${XZ_LEVEL:=6}"    # 0-9 (9 = maximum ratio, much slower/heavier)
: "${XZ_THREADS:=0}"  # 0 = auto-detect number of cores

# --- Transfer settings ---
: "${TRANSFERS:=8}"
: "${CHECKERS:=16}"
: "${LOG_DIR:=${HOME}/logs/garage-backup}"
: "${TMP_DIR:=${TMPDIR:-/tmp}}"

# --- Uptime monitoring ---
: "${UPTIME_MONITORING_URL:=}"

# ---------------------------------------------------------------------------
# 2. RCLONE CONFIGURATION VIA ENVIRONMENT VARIABLES
#    Convention: RCLONE_CONFIG_<REMOTE_NAME>_<OPTION>
# ---------------------------------------------------------------------------

# "garage" remote (S3 compatible, path-style addressing required)
export RCLONE_CONFIG_GARAGE_TYPE="s3"
export RCLONE_CONFIG_GARAGE_PROVIDER="Other"
export RCLONE_CONFIG_GARAGE_ACCESS_KEY_ID="${GARAGE_ACCESS_KEY_ID}"
export RCLONE_CONFIG_GARAGE_SECRET_ACCESS_KEY="${GARAGE_SECRET_ACCESS_KEY}"
export RCLONE_CONFIG_GARAGE_ENDPOINT="${GARAGE_ENDPOINT}"
export RCLONE_CONFIG_GARAGE_REGION="${GARAGE_REGION}"
export RCLONE_CONFIG_GARAGE_FORCE_PATH_STYLE="true"

# "s3" remote (other S3-compatible service, destination for the archive)
export RCLONE_CONFIG_S3_TYPE="s3"
export RCLONE_CONFIG_S3_PROVIDER="Other"
export RCLONE_CONFIG_S3_ACCESS_KEY_ID="${S3_ACCESS_KEY}"
export RCLONE_CONFIG_S3_SECRET_ACCESS_KEY="${S3_SECRET_ACCESS_KEY}"
export RCLONE_CONFIG_S3_ENDPOINT="${S3_ENDPOINT}"
export RCLONE_CONFIG_S3_REGION="${S3_REGION}"
export RCLONE_CONFIG_S3_FORCE_PATH_STYLE="true"

# export RCLONE_CONFIG_S3_NO_CHECK_BUCKET="true"

# ---------------------------------------------------------------------------
# 3. PRE-FLIGHT CHECKS
# ---------------------------------------------------------------------------
command -v rclone >/dev/null 2>&1 || { echo "Error: rclone is not installed." >&2; exit 1; }
command -v tar >/dev/null 2>&1 || { echo "Error: tar is not installed." >&2; exit 1; }
command -v xz >/dev/null 2>&1 || { echo "Error: xz is not installed." >&2; exit 1; }
command -v fusermount >/dev/null 2>&1 || { echo "Error: fusermount not found (fuse package required for 'rclone mount')." >&2; exit 1; }
[ -e /dev/fuse ] || { echo "Error: /dev/fuse not found. Run the container with --device /dev/fuse --cap-add SYS_ADMIN." >&2; exit 1; }

# S3 requires rclone >= 1.59 (otherwise HTTP 401 errors)
RCLONE_VER="$(rclone version | head -n1 | awk '{print $2}' | tr -d 'v')"
if [ "$(printf '%s\n1.59.0\n' "$RCLONE_VER" | sort -V | head -n1)" != "1.59.0" ]; then
  echo "Warning: rclone $RCLONE_VER detected; version >= 1.59 recommended for S3." >&2
fi

mkdir -p "${LOG_DIR}"
TIMESTAMP="$(date +%Y-%m-%d_%H-%M-%S)"
LOG_FILE="${LOG_DIR}/backup-${TIMESTAMP}.log"
ARCHIVE_NAME="${TIMESTAMP}.tar.xz"

if [ -n "${DEST_PATH}" ]; then
  DEST_OBJECT="${DEST_PATH%/}/${ARCHIVE_NAME}"
else
  DEST_OBJECT="${ARCHIVE_NAME}"
fi

echo "==> Testing connection to the source (garage:${GARAGE_BUCKET})..."
rclone lsd "garage:${GARAGE_BUCKET}" >/dev/null \
  || { echo "Error: cannot access the source Garage bucket." >&2; exit 1; }

echo "==> Testing connection to the destination (s3:${S3_BUCKET})..."
rclone lsd "s3:${S3_BUCKET}" >/dev/null \
  || { echo "Error: cannot access the destination S3 bucket." >&2; exit 1; }

# ---------------------------------------------------------------------------
# 4. MOUNT THE SOURCE BUCKET (FUSE, read-only, no local caching)
# ---------------------------------------------------------------------------
MOUNT_DIR="$(mktemp -d "${TMP_DIR}/garage-backup-mount.XXXXXX")"

cleanup() {
  if mountpoint -q "${MOUNT_DIR}" 2>/dev/null; then
    fusermount -u "${MOUNT_DIR}" 2>/dev/null || umount "${MOUNT_DIR}" 2>/dev/null || true
  fi
  rmdir "${MOUNT_DIR}" 2>/dev/null || true
}
trap cleanup EXIT

echo "==> Mounting garage:${GARAGE_BUCKET} on ${MOUNT_DIR}"
rclone mount "garage:${GARAGE_BUCKET}" "${MOUNT_DIR}" \
  --read-only \
  --vfs-cache-mode off \
  --daemon \
  --log-file "${LOG_FILE}" \
  --log-level INFO \
  || { echo "Error: failed to mount the source Garage bucket. Last log lines:" >&2; tail -n 30 "${LOG_FILE}" >&2; exit 1; }

mountpoint -q "${MOUNT_DIR}" \
  || { echo "Error: mount did not become ready. Last log lines:" >&2; tail -n 30 "${LOG_FILE}" >&2; exit 1; }

# ---------------------------------------------------------------------------
# 5. BACKUP
#    Streams a single dated tar.xz archive of the whole bucket straight to
#    the destination: tar (mount) | xz | rclone rcat. No local staging.
# ---------------------------------------------------------------------------
echo "==> Starting backup to s3:${S3_BUCKET}/${DEST_OBJECT}"
echo "    Log file: ${LOG_FILE}"

tar -cf - -C "${MOUNT_DIR}" . \
  | xz -T"${XZ_THREADS}" -"${XZ_LEVEL}" \
  | rclone rcat "s3:${S3_BUCKET}/${DEST_OBJECT}" \
      --log-file "${LOG_FILE}" \
      --log-level INFO

PIPE_STATUS=("${PIPESTATUS[@]}")
TAR_STATUS="${PIPE_STATUS[0]}"
XZ_STATUS="${PIPE_STATUS[1]}"
RCAT_STATUS="${PIPE_STATUS[2]}"

if [ "${TAR_STATUS}" -eq 0 ] && [ "${XZ_STATUS}" -eq 0 ] && [ "${RCAT_STATUS}" -eq 0 ]; then
  STATUS=0
else
  STATUS=1
fi

# ---------------------------------------------------------------------------
# 6. SUMMARY
# ---------------------------------------------------------------------------
if [ "${STATUS}" -eq 0 ]; then
  echo "==> Backup completed successfully: ${DEST_OBJECT}"
  rclone lsl "s3:${S3_BUCKET}/${DEST_OBJECT}" 2>/dev/null || true
else
  echo "==> Backup failed (tar=${TAR_STATUS}, xz=${XZ_STATUS}, rclone=${RCAT_STATUS}). Last log lines:" >&2
  tail -n 30 "${LOG_FILE}" >&2
  exit "${STATUS}"
fi

# ---------------------------------------------------------------------------
# 7. UPTIME
# ---------------------------------------------------------------------------
if [ -n "${UPTIME_MONITORING_URL}" ]; then
  echo "==> Sending uptime monitoring ping to ${UPTIME_MONITORING_URL}"
  curl -fsS "${UPTIME_MONITORING_URL}" >/dev/null || true
fi

exit "${STATUS}"

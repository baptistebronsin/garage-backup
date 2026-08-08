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
: "${BACKUP_MAX_BEFORE_DELETE:=}"

# --- Encryption ---
: "${BACKUP_AGE_RECIPIENT:=}" # age public key; leave empty to disable encryption

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

export RCLONE_CONFIG_S3_NO_CHECK_BUCKET="true"

# ---------------------------------------------------------------------------
# 3. PRE-FLIGHT CHECKS
# ---------------------------------------------------------------------------
command -v rclone >/dev/null 2>&1 || { echo "Error: rclone is not installed." >&2; exit 1; }
command -v tar >/dev/null 2>&1 || { echo "Error: tar is not installed." >&2; exit 1; }
command -v xz >/dev/null 2>&1 || { echo "Error: xz is not installed." >&2; exit 1; }
if [ -n "${BACKUP_AGE_RECIPIENT}" ]; then
  command -v age >/dev/null 2>&1 || { echo "Error: age is not installed." >&2; exit 1; }
fi

# S3 requires rclone >= 1.59 (otherwise HTTP 401 errors)
RCLONE_VER="$(rclone version | head -n1 | awk '{print $2}' | tr -d 'v')"
if [ "$(printf '%s\n1.59.0\n' "$RCLONE_VER" | sort -V | head -n1)" != "1.59.0" ]; then
  echo "Warning: rclone $RCLONE_VER detected; version >= 1.59 recommended for S3." >&2
fi

mkdir -p "${LOG_DIR}"
TIMESTAMP="$(date +%Y-%m-%d_%H-%M-%S)"
LOG_FILE="${LOG_DIR}/backup-${TIMESTAMP}.log"
ARCHIVE_NAME="${TIMESTAMP}.tar.xz"
if [ -n "${BACKUP_AGE_RECIPIENT}" ]; then
  ARCHIVE_NAME="${ARCHIVE_NAME}.age"
fi

if [ -n "${DEST_PATH}" ]; then
  DEST_DIR="s3:${S3_BUCKET}/${DEST_PATH%/}"
  DEST_OBJECT="${DEST_PATH%/}/${ARCHIVE_NAME}"
else
  DEST_DIR="s3:${S3_BUCKET}"
  DEST_OBJECT="${ARCHIVE_NAME}"
fi

echo "==> Testing connection to the source (garage:${GARAGE_BUCKET})..."
rclone lsd "garage:${GARAGE_BUCKET}" >/dev/null \
  || { echo "Error: cannot access the source Garage bucket." >&2; exit 1; }

echo "==> Testing connection to the destination (s3:${S3_BUCKET})..."
rclone lsd "s3:${S3_BUCKET}" >/dev/null \
  || { echo "Error: cannot access the destination S3 bucket." >&2; exit 1; }

# ---------------------------------------------------------------------------
# 4. DOWNLOAD THE SOURCE BUCKET LOCALLY (no special privileges required)
# ---------------------------------------------------------------------------
SRC_DIR="$(mktemp -d "${TMP_DIR}/garage-backup-src.XXXXXX")"

cleanup() {
  rm -rf "${SRC_DIR}"
}
trap cleanup EXIT

echo "==> Downloading garage:${GARAGE_BUCKET} to ${SRC_DIR}"
rclone copy "garage:${GARAGE_BUCKET}" "${SRC_DIR}" \
  --transfers "${TRANSFERS}" \
  --checkers "${CHECKERS}" \
  --fast-list \
  --stats 30s \
  --stats-one-line \
  --log-file "${LOG_FILE}" \
  --log-level INFO \
  || { echo "Error: failed to download the source Garage bucket. Last log lines:" >&2; tail -n 30 "${LOG_FILE}" >&2; exit 1; }

# ---------------------------------------------------------------------------
# 5. BACKUP
#    Streams a single dated tar.xz archive of the downloaded bucket straight
#    to the destination: tar (local dir) | xz | [age] | rclone rcat.
# ---------------------------------------------------------------------------
echo "==> Starting backup to s3:${S3_BUCKET}/${DEST_OBJECT}"
echo "    Log file: ${LOG_FILE}"

AGE_STATUS=0
if [ -n "${BACKUP_AGE_RECIPIENT}" ]; then
  echo "    Encryption: enabled (age)"
  tar -cf - -C "${SRC_DIR}" . \
    | xz -T"${XZ_THREADS}" -"${XZ_LEVEL}" \
    | age -r "${BACKUP_AGE_RECIPIENT}" \
    | rclone rcat "s3:${S3_BUCKET}/${DEST_OBJECT}" \
        --log-file "${LOG_FILE}" \
        --log-level INFO

  PIPE_STATUS=("${PIPESTATUS[@]}")
  TAR_STATUS="${PIPE_STATUS[0]}"
  XZ_STATUS="${PIPE_STATUS[1]}"
  AGE_STATUS="${PIPE_STATUS[2]}"
  RCAT_STATUS="${PIPE_STATUS[3]}"
else
  tar -cf - -C "${SRC_DIR}" . \
    | xz -T"${XZ_THREADS}" -"${XZ_LEVEL}" \
    | rclone rcat "s3:${S3_BUCKET}/${DEST_OBJECT}" \
        --log-file "${LOG_FILE}" \
        --log-level INFO

  PIPE_STATUS=("${PIPESTATUS[@]}")
  TAR_STATUS="${PIPE_STATUS[0]}"
  XZ_STATUS="${PIPE_STATUS[1]}"
  RCAT_STATUS="${PIPE_STATUS[2]}"
fi

if [ "${TAR_STATUS}" -eq 0 ] && [ "${XZ_STATUS}" -eq 0 ] && [ "${AGE_STATUS}" -eq 0 ] && [ "${RCAT_STATUS}" -eq 0 ]; then
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
  echo "==> Backup failed (tar=${TAR_STATUS}, xz=${XZ_STATUS}, age=${AGE_STATUS}, rclone=${RCAT_STATUS}). Last log lines:" >&2
  tail -n 30 "${LOG_FILE}" >&2
  exit "${STATUS}"
fi

# ---------------------------------------------------------------------------
# 7. BACKUP ROTATION
#    Keeps only the BACKUP_MAX_BEFORE_DELETE most recent archives in
#    DEST_DIR. Filenames sort lexicographically = chronologically
#    (YYYY-MM-DD_HH-MM-SS.tar.xz), so no date parsing is needed.
# ---------------------------------------------------------------------------
if [ -z "${BACKUP_MAX_BEFORE_DELETE}" ]; then
  echo "==> No limit on the number of backups to keep"
else
  echo "==> Rotating backups in ${DEST_DIR} (keeping ${BACKUP_MAX_BEFORE_DELETE} most recent)..."
  OLD_BACKUPS="$(rclone lsf "${DEST_DIR}" --files-only --include "*.tar.xz*" \
    | sort -r | tail -n "+$((BACKUP_MAX_BEFORE_DELETE + 1))")"

  if [ -z "${OLD_BACKUPS}" ]; then
    echo "==> No old backups to delete"
  else
    while IFS= read -r FILE_NAME; do
      echo "==> Deleting ${FILE_NAME}..."
      if rclone deletefile "${DEST_DIR}/${FILE_NAME}" --log-file "${LOG_FILE}" --log-level INFO; then
        echo "    Deleted."
      else
        echo "    Error: failed to delete ${FILE_NAME}." >&2
      fi
    done <<< "${OLD_BACKUPS}"
  fi
fi

# ---------------------------------------------------------------------------
# 8. UPTIME
# ---------------------------------------------------------------------------
if [ -n "${UPTIME_MONITORING_URL}" ]; then
  echo "==> Sending uptime monitoring ping to ${UPTIME_MONITORING_URL}"
  curl -fsS "${UPTIME_MONITORING_URL}" >/dev/null || true
fi

exit "${STATUS}"

#!/bin/bash

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
: "${ZSTD_LEVEL:=4}" # 0=off, 2=default, 4=maximum ratio

# --- Transfer settings ---
: "${TRANSFERS:=8}"
: "${CHECKERS:=16}"
: "${LOG_DIR:=${HOME}/logs/garage-backup}"

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

# "s3" remote (other S3-compatible service, underlying the compression wrapper)
export RCLONE_CONFIG_S3_TYPE="s3"
export RCLONE_CONFIG_S3_PROVIDER="Other"
export RCLONE_CONFIG_S3_ACCESS_KEY_ID="${S3_ACCESS_KEY}"
export RCLONE_CONFIG_S3_SECRET_ACCESS_KEY="${S3_SECRET_ACCESS_KEY}"
export RCLONE_CONFIG_S3_ENDPOINT="${S3_ENDPOINT}"
export RCLONE_CONFIG_S3_REGION="${S3_REGION}"
export RCLONE_CONFIG_S3_FORCE_PATH_STYLE="true"

# export RCLONE_CONFIG_S3_NO_CHECK_BUCKET="true"

# "s3c" remote: wraps "s3" with transparent zstd compression
export RCLONE_CONFIG_S3C_TYPE="compress"
export RCLONE_CONFIG_S3C_REMOTE="s3:${S3_BUCKET}"
export RCLONE_CONFIG_S3C_MODE="zstd"
export RCLONE_CONFIG_S3C_LEVEL="${ZSTD_LEVEL}"

# ---------------------------------------------------------------------------
# 3. PRE-FLIGHT CHECKS
# ---------------------------------------------------------------------------
command -v rclone >/dev/null 2>&1 || { echo "Error: rclone is not installed." >&2; exit 1; }

# S3 requires rclone >= 1.59 (otherwise HTTP 401 errors)
RCLONE_VER="$(rclone version | head -n1 | awk '{print $2}' | tr -d 'v')"
if [ "$(printf '%s\n1.59.0\n' "$RCLONE_VER" | sort -V | head -n1)" != "1.59.0" ]; then
  echo "Warning: rclone $RCLONE_VER detected; version >= 1.59 recommended for S3." >&2
fi

mkdir -p "${LOG_DIR}"
TIMESTAMP="$(date +%Y-%m-%dT%H-%M-%S)"
LOG_FILE="${LOG_DIR}/backup-${TIMESTAMP}.log"

DEST_REMOTE="s3c:${DEST_PATH}"

echo "==> Testing connection to the source (garage:${GARAGE_BUCKET})..."
rclone lsd "garage:${GARAGE_BUCKET}" >/dev/null \
  || { echo "Error: cannot access the source Garage bucket." >&2; exit 1; }

echo "==> Testing connection to the destination (${DEST_REMOTE})..."
rclone lsd "s3:${S3_BUCKET}" >/dev/null \
  || { echo "Error: cannot access the destination S3 bucket." >&2; exit 1; }

# ---------------------------------------------------------------------------
# 4. BACKUP
#    "copy": adds/updates without ever deleting on the destination side.
#    Replace with "sync" for an exact mirror (test it with --dry-run first!).
# ---------------------------------------------------------------------------
echo "==> Starting backup to ${DEST_REMOTE}"
echo "    Log file: ${LOG_FILE}"

rclone copy "garage:${GARAGE_BUCKET}" "${DEST_REMOTE}" \
  --transfers "${TRANSFERS}" \
  --checkers "${CHECKERS}" \
  --fast-list \
  --stats 30s \
  --stats-one-line \
  --log-file "${LOG_FILE}" \
  --log-level INFO

STATUS=$?

# ---------------------------------------------------------------------------
# 5. SUMMARY
# ---------------------------------------------------------------------------
if [ "${STATUS}" -eq 0 ]; then
  echo "==> Backup completed successfully."
  echo "==> Stored size on S3 (after compression):"
  rclone size "s3:${S3_BUCKET}" 2>/dev/null || true
else
  echo "==> Backup failed (exit code ${STATUS}). See ${LOG_FILE}." >&2
  exit "${STATUS}"
fi

# ---------------------------------------------------------------------------
# 6. UPTIME
# ---------------------------------------------------------------------------
if [ -n "${UPTIME_MONITORING_URL}" ]; then
  echo "==> Sending uptime monitoring ping to ${UPTIME_MONITORING_URL}"
  curl -fsS "${UPTIME_MONITORING_URL}" >/dev/null || true
fi

exit "${STATUS}"
FROM rclone/rclone:1.75

RUN apk add --no-cache bash curl fuse xz

WORKDIR /app

COPY --chmod=755 backup.sh /app/backup.sh

ENTRYPOINT ["/app/backup.sh"]

# Requires: docker run --device /dev/fuse --cap-add SYS_ADMIN ...
# (rclone mount needs FUSE access, which is not granted by default)
# Runs as root: /dev/fuse is typically root-only (crw-------) on the host,
# and CAP_SYS_ADMIN is already required for the mount itself.
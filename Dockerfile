FROM rclone/rclone:1.75

RUN apk add --no-cache bash curl \
    && addgroup -S app && adduser -S -G app app

WORKDIR /app

COPY --chmod=755 backup.sh /app/backup.sh

USER app

ENTRYPOINT ["/app/backup.sh"]
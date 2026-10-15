ARG PG_MAJOR=16
FROM postgres:${PG_MAJOR}-alpine
LABEL org.opencontainers.image.source=https://github.com/woB2K/pg-backup \
      org.opencontainers.image.description="Postgres and folder backups to restic over rclone"
RUN apk add --no-cache curl rclone restic
ENV RCLONE_CONFIG=/var/lib/backup/rclone.conf \
    RESTIC_CACHE_DIR=/var/lib/backup/cache
COPY --chmod=755 entrypoint.sh /usr/local/bin/entrypoint
COPY --chmod=755 backup.sh /usr/local/bin/backup
COPY --chmod=755 restore.sh /usr/local/bin/restore
ENTRYPOINT ["entrypoint"]
CMD []

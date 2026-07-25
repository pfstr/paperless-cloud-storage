#!/usr/bin/env bash
# Watchdog for the cloud-backed Paperless document store.
#
# THE ONE RULE: if the mount is missing, STOP Paperless — do not let it run.
# A missing FUSE mount is just an empty local directory. If Paperless consumes
# a document in that state, the file is written to the local directory and
# becomes invisible (and appears lost) the moment the mount returns.
#
# Run from cron, e.g. every minute:
#   * * * * * /path/to/watchdog.sh >> /var/log/paperless-watchdog.log 2>&1

set -u

MOUNTPOINT="${MOUNTPOINT:-$HOME/paperless/media/documents/originals}"
COMPOSE_DIR="${COMPOSE_DIR:-$HOME/paperless}"
MARKER="$COMPOSE_DIR/.watchdog-stopped"

mount_ok() {
    # mountpoint -q exits non-zero both when nothing is mounted and when the
    # mount is dead ("Transport endpoint is not connected").
    mountpoint -q "$MOUNTPOINT" && timeout 15 ls "$MOUNTPOINT" > /dev/null 2>&1
}

if mount_ok; then
    if [ -f "$MARKER" ]; then
        echo "$(date -Is) mount is back — starting Paperless"
        rm -f "$MARKER"
        (cd "$COMPOSE_DIR" && docker compose start webserver)
    fi
    exit 0
fi

echo "$(date -Is) mount missing or dead"

# 1) Stop Paperless FIRST so nothing writes into the bare directory.
if [ ! -f "$MARKER" ]; then
    echo "$(date -Is) stopping Paperless webserver"
    (cd "$COMPOSE_DIR" && docker compose stop webserver)
    touch "$MARKER"
fi

# 2) Clear a dead mount so systemd's restart can mount over it again.
if mountpoint -q "$MOUNTPOINT"; then
    fusermount3 -u "$MOUNTPOINT" 2>/dev/null || fusermount3 -uz "$MOUNTPOINT" 2>/dev/null
fi

# 3) The rclone systemd unit has Restart=always and will bring the mount back;
#    the next watchdog run then restarts Paperless.
exit 1

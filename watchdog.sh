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

BASE_DIR="${BASE_DIR:-/srv/paperless}"
MOUNTPOINT="${MOUNTPOINT:-$BASE_DIR/media/documents/originals}"

# Compose file that defines the Paperless webserver. For an existing
# installation, point this at your own compose file.
PAPERLESS_COMPOSE="${PAPERLESS_COMPOSE:-$(dirname "$0")/paperless.yml}"
SERVICE="${SERVICE:-webserver}"
MARKER="${MARKER:-$BASE_DIR/.watchdog-stopped}"

compose() { docker compose -f "$PAPERLESS_COMPOSE" "$@"; }

mount_ok() {
    # mountpoint -q fails both when nothing is mounted and when the mount is
    # dead ("Transport endpoint is not connected"). The ls confirms the mount
    # actually answers rather than just existing in the mount table.
    mountpoint -q "$MOUNTPOINT" && timeout 15 ls "$MOUNTPOINT" > /dev/null 2>&1
}

if mount_ok; then
    if [ -f "$MARKER" ]; then
        echo "$(date -Is) mount is back — starting Paperless"
        rm -f "$MARKER"
        compose start "$SERVICE"
    fi
    exit 0
fi

echo "$(date -Is) mount missing or dead"

# 1) Stop Paperless FIRST so nothing writes into the bare directory.
if [ ! -f "$MARKER" ]; then
    echo "$(date -Is) stopping Paperless"
    compose stop "$SERVICE"
    touch "$MARKER"
fi

# 2) Clear a dead mount so the next mount attempt can take the path again.
if mountpoint -q "$MOUNTPOINT"; then
    fusermount3 -u "$MOUNTPOINT" 2>/dev/null || fusermount3 -uz "$MOUNTPOINT" 2>/dev/null
fi

# 3) The rclone container restarts on its own (restart: unless-stopped) and
#    re-establishes the mount; the next watchdog run then starts Paperless.
exit 1

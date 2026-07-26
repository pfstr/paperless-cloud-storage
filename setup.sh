#!/usr/bin/env bash
# One-time host preparation for the cloud-backed Paperless document store.
#
# This is the ONLY step that needs root, and the only one you cannot do from a
# browser. It does three things:
#
#   1. creates the directory layout
#   2. turns the media directory into a SHARED mount point
#   3. installs a systemd unit so step 2 survives a reboot
#
# Why step 2 is not optional
# --------------------------
# The rclone container publishes its FUSE mount to the host so the Paperless
# container can see it. Docker only propagates a mount outwards when the bind
# source is itself a mount point with shared propagation. If it is a plain
# directory, Docker silently downgrades `propagation: rshared` to slave and
# the mount inside the container fails with:
#
#     fusermount3: mount failed: Permission denied
#
# Verified on Ubuntu 25.10 / Docker 29.6. A plain directory shows up as
# `master:1` (slave) in /proc/self/mountinfo instead of `shared:N`.
#
# Usage:  sudo ./setup.sh [BASE_DIR]        (default: /srv/paperless)

set -euo pipefail

BASE="${1:-/srv/paperless}"
UNIT="paperless-shared-mount.service"

if [ "$(id -u)" -ne 0 ]; then
    echo "This script needs root: sudo $0 ${1:-}" >&2
    exit 1
fi

OWNER="${SUDO_USER:-root}"
OWNER_UID="$(id -u "$OWNER")"
OWNER_GID="$(id -g "$OWNER")"

echo "==> Base directory: $BASE (owner: $OWNER, ${OWNER_UID}:${OWNER_GID})"

# ---------------------------------------------------------------- directories
mkdir -p \
    "$BASE/media/documents/originals" \
    "$BASE/media/documents/archive" \
    "$BASE/media/documents/thumbnails" \
    "$BASE/cache" \
    "$BASE/consume" \
    "$BASE/export" \
    "$BASE/rclone-config"
chown -R "$OWNER_UID:$OWNER_GID" "$BASE"
echo "==> Directories created"

# -------------------------------------------------------- shared mount point
if ! mountpoint -q "$BASE/media"; then
    mount --bind "$BASE/media" "$BASE/media"
fi
mount --make-shared "$BASE/media"

PROP="$(findmnt -no PROPAGATION "$BASE/media" 2>/dev/null || echo unknown)"
if [ "$PROP" != "shared" ]; then
    echo "!! $BASE/media has propagation '$PROP', expected 'shared'." >&2
    echo "!! The rclone container will not be able to publish its mount." >&2
    exit 1
fi
echo "==> $BASE/media is a shared mount point"

# ------------------------------------------------------------ persist at boot
cat > "/etc/systemd/system/$UNIT" <<UNITFILE
[Unit]
Description=Shared bind mount for the Paperless cloud document store
Documentation=https://github.com/pfstr/paperless-cloud-storage
DefaultDependencies=no
After=local-fs.target
Before=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh -c 'mountpoint -q $BASE/media || mount --bind $BASE/media $BASE/media; mount --make-shared $BASE/media'
ExecStop=/bin/sh -c 'umount $BASE/media 2>/dev/null || true'

[Install]
WantedBy=multi-user.target
UNITFILE

systemctl daemon-reload
systemctl enable "$UNIT" >/dev/null
echo "==> $UNIT installed and enabled (survives reboot)"

# ----------------------------------------------------------------- fuse.conf
# Only needed if you later run rclone directly on the host instead of in a
# container. Harmless otherwise.
if ! grep -q '^user_allow_other' /etc/fuse.conf 2>/dev/null; then
    echo 'user_allow_other' >> /etc/fuse.conf
    echo "==> user_allow_other added to /etc/fuse.conf"
fi

cat <<DONE

Done. Next steps (no root needed from here on):

  1. cp .env.example .env        and set BASE_DIR=$BASE plus a GUI password
  2. docker compose -f storage.yml up -d
  3. Open the rclone web UI, add your cloud remote and create the mount:
       ssh -L 5522:localhost:5522 -L 5533:localhost:5533 <this-host>
       http://localhost:5522/login?url=localhost:5533
  4. Start Paperless (new install: paperless.yml,
     existing install: see docs/RETROFIT.md)
DONE

#!/bin/sh
# Container entrypoint: mounts everything listed in mounts.conf and keeps
# watch. mounts.conf is written by wizard.sh and lives next to rclone.conf,
# so mount definitions survive container restarts — no UI, no RC API.
#
# Line format:  <remote>:<path> <relative-target>
#   e.g.        cloud:paperless/originals documents/originals
#
# Each entry is FUSE-mounted at /mnt/inner/<relative-target>, then
# bind-published to /data/<relative-target> — the host-shared bind that
# Paperless consumes via rslave. The detour exists because hosts that ship
# an AppArmor profile for fusermount3 (Ubuntu does) only permit FUSE mounts
# on an allow-list of patterns (/mnt/**, /media/**, $HOME/**, /tmp/**),
# matched against the path AS SEEN INSIDE THE CONTAINER; mounting straight
# onto /data fails with "fusermount3: mount failed: Permission denied" even
# in a privileged container. A plain bind mount is not fusermount3 and not
# covered by the profile. Verified on Ubuntu 25.10 / kernel 6.17.
#
# Self-healing: if any mount dies, this script exits non-zero. With
# restart: unless-stopped Docker restarts the container, everything is
# remounted, and Paperless picks the mounts up without being restarted
# itself (verified). The watchdog additionally stops Paperless while mounts
# are missing so nothing is written into bare directories.

set -u

CONF=/config/rclone/mounts.conf
INNER=/mnt/inner
OUTER=/data
CACHE_MAX="${VFS_CACHE_MAX:-1G}"

[ -s "$CONF" ] || {
    echo "mount-runner: $CONF is missing or empty — run ./wizard.sh first."
    echo "mount-runner: sleeping so the container does not crash-loop."
    exec sleep infinity
}

cleanup() {
    grep -vE '^\s*(#|$)' "$CONF" | while read -r _ rel _; do
        fusermount3 -u "$INNER/$rel" 2>/dev/null
        umount "$OUTER/$rel" 2>/dev/null
    done
    kill 0 2>/dev/null
}
trap cleanup TERM INT

alive() {
    # a dead FUSE mount fails both checks; a bare dir fails the first
    grep -q " $1 " /proc/self/mountinfo && timeout 20 ls "$1" >/dev/null 2>&1
}

# ---------------------------------------------------------- clean stale state
# A previous container life may leave dead mounts behind: a defunct bind on
# /data (which would block republishing) and a half-torn-down inner mount.
# They can only be cleared from inside the container — on the host they
# belong to root, and the unmount propagates out through the shared bind.
grep -vE '^\s*(#|$)' "$CONF" | while read -r fs rel _; do
    while grep -q " $OUTER/$rel " /proc/self/mountinfo; do
        umount -l "$OUTER/$rel" 2>/dev/null || break
        echo "mount-runner: cleared stale bind $OUTER/$rel"
    done
    while grep -q " $INNER/$rel " /proc/self/mountinfo; do
        fusermount3 -u "$INNER/$rel" 2>/dev/null \
            || umount -l "$INNER/$rel" 2>/dev/null || break
        echo "mount-runner: cleared stale mount $INNER/$rel"
    done
done

# ------------------------------------------------------------------ mount all
grep -vE '^\s*(#|$)' "$CONF" | while read -r fs rel _; do
    mkdir -p "$INNER/$rel" "$OUTER/$rel"
    echo "mount-runner: mounting $fs -> $INNER/$rel"
    rclone mount "$fs" "$INNER/$rel" \
        --allow-other \
        --vfs-cache-mode full \
        --vfs-cache-max-size "$CACHE_MAX" \
        --vfs-cache-max-age 720h \
        --dir-cache-time 1h \
        --cache-dir /cache \
        --log-level INFO &
done

# wait for the mounts, then publish them to the shared /data bind
sleep 5
grep -vE '^\s*(#|$)' "$CONF" | while read -r fs rel _; do
    for _ in 1 2 3 4 5 6; do
        alive "$INNER/$rel" && break
        sleep 5
    done
    if alive "$INNER/$rel"; then
        mount --bind "$INNER/$rel" "$OUTER/$rel" \
            && echo "mount-runner: published $INNER/$rel -> $OUTER/$rel" \
            || echo "mount-runner: WARN bind to $OUTER/$rel failed"
    else
        echo "mount-runner: ERROR $fs did not come up"
    fi
done

# --------------------------------------------------------------------- watch
while :; do
    sleep 30
    grep -vE '^\s*(#|$)' "$CONF" | while read -r fs rel _; do
        if ! alive "$INNER/$rel"; then
            echo "mount-runner: $fs at $INNER/$rel is dead — exiting for restart"
            exit 1
        fi
    done || { cleanup; exit 1; }
done

#!/bin/sh
# Publishes FUSE mounts created under /mnt/inner to the host-shared /data bind.
#
# Why this exists: on hosts that ship an AppArmor profile for fusermount3
# (Ubuntu does), FUSE mounts are only permitted on an allow-list of mount
# point patterns — /mnt/**, /media/**, $HOME/**, /tmp/** — matched against
# the path AS SEEN INSIDE THE CONTAINER. A mount onto /data/... therefore
# fails with "fusermount3: mount failed: Permission denied" even in a
# privileged container (kernel audit log: apparmor="DENIED"
# operation="mount" info="failed mntpnt match" profile="fusermount3").
#
# A plain bind mount is not fusermount3 and not covered by that profile, so:
# mount FUSE on an allowed path, then bind that onto the shared /data.
# Verified on Ubuntu 25.10 / kernel 6.17 / Docker 29.6.
#
# So: create your mounts (GUI or RC API) under /mnt/inner/<path>. This loop
# mirrors every mount that appears under /mnt/inner to the same <path> under
# /data, and removes the bind again when the inner mount goes away.
#
# Runs as PID-1-adjacent background loop, started by the container command.

INNER=/mnt/inner
OUTER=/data

mkdir -p "$INNER" "$OUTER"

is_mountpoint() {
    # busybox has no mountpoint(1); compare device numbers with parent
    [ "$(stat -c %d "$1" 2>/dev/null)" != "$(stat -c %d "$(dirname "$1")" 2>/dev/null)" ]
}

while :; do
    # 1) publish: every fuse mount under /mnt/inner that is not yet bound under /data
    awk -v inner="$INNER" '$9 ~ /fuse/ && index($5, inner"/") == 1 { print $5 }' /proc/self/mountinfo |
    while read -r m; do
        rel="${m#"$INNER"/}"
        tgt="$OUTER/$rel"
        if ! is_mountpoint "$tgt"; then
            mkdir -p "$tgt"
            if mount --bind "$m" "$tgt" 2>/dev/null; then
                echo "bind-publish: $m -> $tgt"
            fi
        fi
    done

    # 2) retract: binds under /data whose inner source is no longer mounted
    awk -v outer="$OUTER" '$9 ~ /fuse/ && index($5, outer"/") == 1 { print $5 }' /proc/self/mountinfo |
    while read -r t; do
        rel="${t#"$OUTER"/}"
        src="$INNER/$rel"
        if ! is_mountpoint "$src"; then
            if umount "$t" 2>/dev/null; then
                echo "bind-publish: retracted $t (inner mount gone)"
            fi
        fi
    done

    sleep 5
done

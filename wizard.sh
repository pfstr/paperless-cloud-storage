#!/usr/bin/env bash
# Guided setup for the cloud-backed Paperless document store.
#
# Asks which provider you use, creates the rclone remote, verifies the
# connection with a real upload/download round trip, writes the mount
# definition (mounts.conf) and starts the storage container. No rclone
# knowledge required.
#
# Curated providers get a short tailored form. Everything else rclone
# supports (70+ backends) is available via "Not in the list", which opens
# rclone's own configuration dialog and then continues with the same
# verification and mount steps.
#
# Run as your normal user from the repository directory:  ./wizard.sh

set -u

cd "$(dirname "$0")"

RCLONE_IMG="rclone/rclone:latest"
say()  { printf '%s\n' "$*"; }
ok()   { printf '  \033[32m✔\033[0m %s\n' "$*"; }
fail() { printf '  \033[31m✘\033[0m %s\n' "$*"; }
die()  { fail "$*"; exit 1; }

# ---------------------------------------------------------------- environment
if [ ! -f .env ]; then
    BASE_DEFAULT=/srv/paperless
    printf 'Base directory [%s]: ' "$BASE_DEFAULT"
    read -r BASE_DIR
    BASE_DIR="${BASE_DIR:-$BASE_DEFAULT}"
    printf 'BASE_DIR=%s\n' "$BASE_DIR" > .env
else
    # shellcheck disable=SC1091
    . ./.env
fi
BASE_DIR="${BASE_DIR:?BASE_DIR missing in .env}"

[ -d "$BASE_DIR/rclone-config" ] || die "$BASE_DIR/rclone-config does not exist — run 'sudo ./setup.sh $BASE_DIR' first."
findmnt -no PROPAGATION "$BASE_DIR/media" 2>/dev/null | grep -q shared \
    || die "$BASE_DIR/media is not a shared mount point — run 'sudo ./setup.sh $BASE_DIR' first."

# rclone helper against the shared config dir (no container needs to run yet)
rc() {
    docker run --rm -i \
        -v "$BASE_DIR/rclone-config:/config/rclone" \
        "$RCLONE_IMG" "$@" 2>&1
}
rc_tty() {
    docker run --rm -it \
        -v "$BASE_DIR/rclone-config:/config/rclone" \
        "$RCLONE_IMG" "$@"
}
obscure() { printf '%s' "$1" | rc obscure -; }

ask()        { printf '%s: ' "$1"; read -r REPLY; }
ask_secret() { printf '%s: ' "$1"; read -rs REPLY; printf '\n'; }

REMOTE=cloud

# ------------------------------------------------------------------ provider
say ""
say "Where should the documents be stored?"
say ""
say "  1) Proton Drive"
say "  2) S3 compatible (AWS, MinIO, Wasabi, Hetzner, ...)"
say "  3) Backblaze B2"
say "  4) WebDAV (Nextcloud, ...)"
say "  5) SFTP server"
say "  6) Not in the list (any of rclone's 70+ backends)"
say ""
printf '> '
read -r CHOICE

if rc listremotes | grep -qx "$REMOTE:"; then
    printf 'A remote "%s" already exists. Replace it? [y/N]: ' "$REMOTE"
    read -r R
    [ "$R" = "y" ] || die "Keeping the existing remote. Delete it first if you want to start over."
    rc config delete "$REMOTE" >/dev/null
fi

case "$CHOICE" in
  1)
    say ""
    say "Use a DEDICATED Proton account without two-factor authentication —"
    say "sessions from a one-time 2FA code expire after ~35 minutes and cannot"
    say "renew unattended (see README: choosing the cloud account)."
    say ""
    ask "Proton e-mail"; P_USER=$REPLY
    ask_secret "Proton password"; P_PASS=$(obscure "$REPLY")
    rc config create "$REMOTE" protondrive username "$P_USER" password "$P_PASS" \
        --no-obscure >/dev/null || die "creating the remote failed"
    ;;
  2)
    ask "Endpoint URL (empty for AWS)"; S_EP=$REPLY
    ask "Access key ID"; S_KEY=$REPLY
    ask_secret "Secret access key"; S_SEC=$REPLY
    ask "Region (empty if unsure)"; S_REG=$REPLY
    rc config create "$REMOTE" s3 provider Other env_auth false \
        access_key_id "$S_KEY" secret_access_key "$S_SEC" \
        ${S_EP:+endpoint "$S_EP"} ${S_REG:+region "$S_REG"} >/dev/null \
        || die "creating the remote failed"
    ;;
  3)
    ask "Account ID (or application key ID)"; B_ID=$REPLY
    ask_secret "Application key"; B_KEY=$REPLY
    rc config create "$REMOTE" b2 account "$B_ID" key "$B_KEY" >/dev/null \
        || die "creating the remote failed"
    ;;
  4)
    ask "WebDAV URL (e.g. https://cloud.example.com/remote.php/dav/files/USER)"; W_URL=$REPLY
    ask "User"; W_USER=$REPLY
    ask_secret "Password"; W_PASS=$(obscure "$REPLY")
    rc config create "$REMOTE" webdav url "$W_URL" vendor other \
        user "$W_USER" pass "$W_PASS" --no-obscure >/dev/null \
        || die "creating the remote failed"
    ;;
  5)
    ask "Host"; F_HOST=$REPLY
    ask "User"; F_USER=$REPLY
    ask "Port [22]"; F_PORT=${REPLY:-22}
    ask_secret "Password (empty if you use an SSH key agent)"; F_PASS=$REPLY
    rc config create "$REMOTE" sftp host "$F_HOST" user "$F_USER" port "$F_PORT" \
        ${F_PASS:+pass "$(obscure "$F_PASS")"} ${F_PASS:+--no-obscure} >/dev/null \
        || die "creating the remote failed"
    ;;
  6)
    say ""
    say "Opening rclone's own configuration dialog. Create a new remote and"
    say "name it \"$REMOTE\". Any backend works; the mount layer underneath is"
    say "identical for all of them. Note for OAuth backends (Google Drive,"
    say "OneDrive, Dropbox, ...): answer 'n' to \"Use web browser to"
    say "automatically authenticate\" and follow the printed instructions to"
    say "authorize from a machine that has a browser."
    say ""
    rc_tty config
    rc listremotes | grep -qx "$REMOTE:" \
        || die "no remote named \"$REMOTE\" was created — run ./wizard.sh again"
    ;;
  *)
    die "invalid choice"
    ;;
esac
ok "remote \"$REMOTE\" configured"

# ------------------------------------------------------------------- verify
say ""
say "Testing the connection ..."
rc lsd "$REMOTE:" >/dev/null || { rc lsd "$REMOTE:" | tail -3; die "cannot list the remote — check the credentials"; }
ok "signed in"

CLOUD_PATH=paperless/originals
printf 'Cloud folder [%s]: ' "$CLOUD_PATH"
read -r R; CLOUD_PATH="${R:-$CLOUD_PATH}"

rc mkdir "$REMOTE:$CLOUD_PATH" >/dev/null || die "could not create $REMOTE:$CLOUD_PATH"
ok "folder $CLOUD_PATH ready"

# real round trip: upload, download, compare, clean up
PROBE=".wizard-probe-$$"
TMP=$(mktemp -d)
printf 'roundtrip %s\n' "$(date -u +%s)" > "$TMP/$PROBE"
docker run --rm -i -v "$BASE_DIR/rclone-config:/config/rclone" -v "$TMP:/probe" \
    "$RCLONE_IMG" copy "/probe/$PROBE" "$REMOTE:$CLOUD_PATH" >/dev/null 2>&1 \
    || die "upload failed"
GOT=$(rc cat "$REMOTE:$CLOUD_PATH/$PROBE")
[ "$GOT" = "$(cat "$TMP/$PROBE")" ] || die "downloaded content differs from upload"
rc deletefile "$REMOTE:$CLOUD_PATH/$PROBE" >/dev/null 2>&1
rm -rf "$TMP"
ok "upload/download round trip verified"

# ---------------------------------------------------------------- mount def
# mounts.conf is read by the storage container at every start — mounts
# survive restarts without anyone clicking anything.
CONF="$BASE_DIR/rclone-config/mounts.conf"
LINE="$REMOTE:$CLOUD_PATH documents/originals"
grep -qxF "$LINE" "$CONF" 2>/dev/null || printf '%s\n' "$LINE" >> "$CONF"
ok "mount definition written ($CONF)"

# ------------------------------------------------------------------- start
say ""
say "Starting the storage container ..."
docker compose -f storage.yml up -d --force-recreate >/dev/null 2>&1 || die "docker compose failed"

TARGET="$BASE_DIR/media/documents/originals"
for _ in $(seq 1 12); do
    sleep 5
    if mountpoint -q "$TARGET" && timeout 20 ls "$TARGET" >/dev/null 2>&1; then
        ok "mount is live at $TARGET"
        say ""
        say "Done. Next:"
        say "  new Paperless install:      docker compose -f paperless.yml up -d"
        say "  existing Paperless install: docs/RETROFIT.md (one volume block)"
        say "  protect against outages:    add watchdog.sh to cron (README)"
        exit 0
    fi
done

fail "the mount did not come up — check: docker logs rclone-mounts"
exit 1

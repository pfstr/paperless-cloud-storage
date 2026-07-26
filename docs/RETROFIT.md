# Adding cloud storage to an existing Paperless-ngx installation

You do not need to reinstall Paperless. Your database, search index, tags,
correspondents and saved views stay exactly as they are — only the location of
the document files changes.

Plan for a short downtime (a few minutes) and do not delete anything local
until the final verification step has passed.

---

## 0. Before you start

**Make a backup that does not depend on this change:**

```bash
docker compose exec webserver document_exporter ../export
```

Copy that export somewhere off the machine. Note that exports are tied to the
Paperless version that created them — an export from 2.20.x cannot be imported
into 3.0.x.

**Find out how your media is stored.** This decides how much work step 3 is:

```bash
docker compose config | grep -A2 'paperless/media'
```

- A path like `./media:/usr/src/paperless/media` → **bind mount**, easy case.
- Something like `media:/usr/src/paperless/media` → **named volume**, one extra
  copy step.

---

## 1. Prepare the host

```bash
sudo ./setup.sh /srv/paperless
```

This creates the directory layout and turns `/srv/paperless/media` into a
shared mount point. See the script header for why that is required.

## 2. Set up the cloud remote

```bash
./wizard.sh
```

Pick your provider and enter the credentials; the wizard verifies the
connection with a real upload/download round trip, writes the mount
definition and starts the storage container. Use `paperless/originals` as
the cloud folder (the default).

The wizard's mount will initially show an empty cloud folder — that is
expected, your existing files go up in the next step.

## 3. Move the existing documents into the cloud

Stop Paperless so nothing changes underneath you:

```bash
docker compose stop webserver
```

Upload the originals from wherever your old media lives, using a throwaway
rclone container with the wizard's credentials.

**Bind mount case** (old media in a directory):

```bash
docker run --rm \
  -v /srv/paperless/rclone-config:/config/rclone \
  -v /path/to/old/media:/old:ro \
  rclone/rclone copy /old/documents/originals cloud:paperless/originals --progress
```

**Named volume case** — mount the volume instead of a path:

```bash
docker run --rm \
  -v /srv/paperless/rclone-config:/config/rclone \
  -v <your_media_volume>:/old:ro \
  rclone/rclone copy /old/documents/originals cloud:paperless/originals --progress
```

The parts that stay **local** — `thumbnails/` and (if you keep it)
`archive/` — must move into the new base directory, because Paperless will
mount `$BASE_DIR/media` as its media root from now on:

```bash
rsync -a /path/to/old/media/documents/thumbnails /srv/paperless/media/documents/
rsync -a /path/to/old/media/documents/archive    /srv/paperless/media/documents/
```

(Named volume: copy them out with the same `alpine cp` pattern first.)

Decide what to offload:

- **`originals/` only** — the safe default. Paperless serves the archive copy
  locally, so the cloud is barely touched in normal use.
- **`originals/` and `archive/`** — maximum saving. Add a second wizard run /
  `mounts.conf` line for `archive`, and consider
  `PAPERLESS_ARCHIVE_FILE_GENERATION=never` so the second copy stops being
  created at all.

## 4. Refresh the mount and verify

The mount was created before the upload, so its directory listing may be
stale. Restart the storage container to pick everything up:

```bash
docker compose -f storage.yml restart
```

Then verify on the host:

```bash
mountpoint /srv/paperless/media/documents/originals && \
  ls /srv/paperless/media/documents/originals | head
```

You should see your document files.

## 5. Point Paperless at it

Edit **your existing** compose file. Replace the media volume line:

```yaml
    # before
    # - ./media:/usr/src/paperless/media

    # after
    - type: bind
      source: /srv/paperless/media
      target: /usr/src/paperless/media
      bind:
        propagation: rslave
```

Add to your environment file:

```ini
PAPERLESS_SANITY_TASK_CRON=disable
```

Then recreate the container so the new mount options take effect — a restart
is not enough:

```bash
docker compose up -d --force-recreate webserver
```

## 6. Verify before deleting anything

```bash
# every file readable through the mount, checksums match the database
docker compose exec webserver document_sanity_checker
```

`No issues detected.` is the green light. Also open a few documents in the web
interface — the first open of each takes a moment while it is fetched.

Only now remove the local copies you set aside in step 3.

## 7. Protect against a missing mount

If the mount disappears, the directory is just an empty local directory again.
Paperless would happily write new documents into it, and they would become
invisible the moment the mount returns.

Install the watchdog so this cannot happen:

```bash
crontab -e
# * * * * * /path/to/watchdog.sh >> /var/log/paperless-watchdog.log 2>&1
```

It stops Paperless while the mount is gone and starts it again once the mount
is back.

---

## Rolling back

1. Stop Paperless.
2. Unmount: in the GUI, or `fusermount3 -u /srv/paperless/media/documents/originals`.
3. Copy the files back: `rclone copy <remote>:paperless/originals /srv/paperless/media/documents/originals`.
4. Restore the original volume line in your compose file, recreate the container.

The database never changed, so nothing else has to be undone.

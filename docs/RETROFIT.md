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
cp .env.example .env      # set BASE_DIR and RCLONE_GUI_PASS
docker compose -f storage.yml up -d
```

Open the GUI through an SSH tunnel and add your remote:

```bash
ssh -L 5522:localhost:5522 -L 5533:localhost:5533 <your-host>
```

Then get the ready-made login link on the server and open it exactly as printed (it uses `127.0.0.1`, which must match):

```bash
docker logs rclone-web 2>&1 | grep "GUI available"
```

**Do not create the mount yet.** First the existing files have to go up.

## 3. Move the existing documents into the cloud

Stop Paperless so nothing changes underneath you:

```bash
docker compose stop webserver
```

**Bind mount case** — copy straight from the old directory:

```bash
docker compose -f storage.yml exec rclone \
  rclone copy /data/documents/originals <remote>:paperless/originals --progress
```

If your old media directory is not yet `/srv/paperless/media`, move it there
first (`rsync -a old/media/ /srv/paperless/media/`).

**Named volume case** — copy the volume contents out first:

```bash
docker run --rm \
  -v <your_media_volume>:/from \
  -v /srv/paperless/media:/to \
  alpine sh -c 'cp -a /from/. /to/'
```

Then upload as in the bind mount case.

Decide what to offload:

- **`originals/` only** — the safe default. Paperless serves the archive copy
  locally, so the cloud is barely touched in normal use.
- **`originals/` and `archive/`** — maximum saving. Consider setting
  `PAPERLESS_ARCHIVE_FILE_GENERATION=never` so the second copy stops being
  created at all.

## 4. Create the mount

In the rclone web UI, go to **Mounts → new mount**:

- Remote: `<remote>:paperless/originals`
- Mount point: `/mnt/inner/documents/originals`
- VFS cache mode: `full`
- **Allow other: enabled** (Paperless runs as a different uid than the mount)
- Cache size limit: e.g. `1G`

The mount must sit under **`/mnt/inner/...`** — AppArmor on the host only
permits FUSE mounts on that path pattern (see README, critical detail 2).
`bind-publish.sh` inside the container then mirrors it to `/data/...`
automatically, which is the shared bind that reaches the host and therefore
Paperless. Allow a few seconds for it to appear.

Verify on the host:

```bash
mountpoint /srv/paperless/media/documents/originals && \
  ls /srv/paperless/media/documents/originals | head
```

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

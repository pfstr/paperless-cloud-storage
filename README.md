# paperless-cloud-storage

Run [Paperless-ngx](https://github.com/paperless-ngx/paperless-ngx) on a small disk by keeping the document store in cloud storage, mounted via [rclone](https://rclone.org/). Only the database, search index, thumbnails and a bounded cache stay local — the collection can grow without the disk growing with it.

> **Status: experimental.** Verified working in both directions (serving documents and consuming new ones, integrity check passes), but without long-term production data yet. Read [What can go wrong](#what-can-go-wrong) before trusting it with documents you cannot lose.

## Works with any rclone backend

The provider is fully abstracted by rclone: the mount, the VFS cache, the `rslave` propagation and the watchdog are identical for every one of the [70+ supported backends](https://rclone.org/overview/) — S3-compatible stores, Backblaze B2, OneDrive, Google Drive, WebDAV, SFTP, Proton Drive, and so on. Switching providers means changing **only the remote configuration** (`rclone config`) and the remote name in the mount unit; nothing else in this template.

What differs per backend:

| Concern | Notes |
|---|---|
| Unattended auth | Must work without interactive prompts. Proton with 2FA breaks after ~35 min (see below); S3 key pairs or service accounts are unproblematic. |
| Change notifications | Some backends push changes (polling works); Proton does not (`poll-interval is not supported`) — relevant only if `consume/` is cloud-backed. |
| Maturity | S3/B2 backends are battle-tested; Proton Drive is explicitly beta in rclone. |
| Encryption | Proton offers end-to-end encryption out of the box; for other backends, layer [rclone crypt](https://rclone.org/crypt/) on top if needed. |

Tested with Proton Drive; an S3-compatible store is the more robust choice if you do not need Proton's end-to-end encryption.

## How it works

Paperless reads document files rarely: search runs against the database (which holds the OCR text) and the list views render thumbnails. The actual file is only opened on view/download. This template therefore:

- keeps **database, search index, thumbnails** on local disk (they need real locking — never put them on a cloud mount),
- mounts the **document store** from cloud storage with `rclone mount --vfs-cache-mode full`,
- binds it into the container with **`propagation: rslave`** — the detail that makes the setup survive mount restarts without a container restart,
- runs a **watchdog** that stops Paperless whenever the mount is missing, because otherwise Paperless writes into the bare directory and the files become invisible once the mount returns.

Measured on a small home server (single measurements, orders of magnitude): first open of a ~600 KB document ~1.8 s, cached open ~20 ms, new document consumed and uploaded to the cloud in ~20 s end to end.

## Setup

### 1. rclone remote

```bash
rclone config        # create a remote named "paperless-storage"
```

Use a **dedicated cloud account** for this, holding nothing but these documents. The account must be able to sign in unattended:

- **No 2FA** on the dedicated account (recommended), **or**
- store the TOTP seed in the rclone config (defeats 2FA for that account — acceptable only because the account is dedicated).

With Proton Drive specifically: a session established with a one-time 2FA code dies after ~35 minutes and cannot re-authenticate (`422 .../auth/v4/2fa`). This is why the account choice matters.

### 2. FUSE

```bash
echo user_allow_other | sudo tee -a /etc/fuse.conf
```

### 3. Mount unit

```bash
sudo cp systemd/rclone-paperless-media.service /etc/systemd/system/
# edit: User, Group, remote name, paths
sudo systemctl daemon-reload
sudo systemctl enable --now rclone-paperless-media
```

### 4. Paperless

```bash
cp paperless.env.example paperless.env   # edit secrets
mkdir -p media consume export
docker compose up -d
docker compose exec webserver createsuperuser
```

### 5. Watchdog

```bash
crontab -e
# * * * * * /path/to/watchdog.sh >> ~/paperless/watchdog.log 2>&1
```

## The two critical details

**`propagation: rslave`** on the media bind mount. Docker defaults to `rprivate`, so a mount created on the host *after* the container started never reaches the container — after any rclone restart the container is stuck on `Transport endpoint is not connected` until recreated. With `rslave`, the container picks the new mount up immediately (verified: restart counter unchanged).

**Stop-on-missing-mount.** When the mount is down, the media path is a plain empty directory. Paperless would happily consume documents into it; the moment the mount returns, those files are shadowed by the mount point — present on disk, invisible to everything. The watchdog therefore stops the webserver first and only starts it again once the mount is verified alive.

## Settings explained (`paperless.env.example`)

| Setting | Why |
|---|---|
| `PAPERLESS_ARCHIVE_FILE_GENERATION=never` | Skips the second (PDF/A) copy of every document; the original is served instead. Halves the offloaded volume. Search is unaffected — the text lives in the database. |
| `PAPERLESS_SANITY_TASK_CRON=disable` | The scheduled sanity check reads **every file** to verify checksums — i.e. downloads the entire collection. Run `document_sanity_checker` manually instead when needed. |
| `PAPERLESS_CONSUMER_POLLING_INTERVAL` | Only if `consume/` is also cloud-backed: inotify cannot see changes made from outside on a FUSE mount. |

## What can go wrong

- **Upload window.** A newly consumed document lives only in the local VFS cache until rclone uploads it (seconds). If the machine dies inside that window, the database row exists but the file is gone.
- **Cache overshoot.** `--vfs-cache-max-size` is enforced by a cleanup pass roughly once per minute. During bursts the cache can temporarily hold far more — budget for the peak, not the limit.
- **Full-store operations.** `document_exporter`, thumbnail regeneration and re-OCR read everything → full download. Back up the database and index instead; the documents are already in the cloud (add an independent second copy, e.g. `rclone copy` to another remote, if you need real redundancy — the cloud store is primary storage here, not a backup).
- **Proton Drive backend is beta** in rclone. Under rapid successive API calls it returned inconsistent directory listings (throttling). S3-compatible backends are more mature.

## Background

Full write-up with measurements and methodology: [rafaelpfister.ch/blog/paperless-dokumente-proton-drive-auslagern](https://rafaelpfister.ch/blog/paperless-dokumente-proton-drive-auslagern) ([English](https://rafaelpfister.ch/en/blog/offloading-paperless-documents-to-proton-drive)).

## License

MIT

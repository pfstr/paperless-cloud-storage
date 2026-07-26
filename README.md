# paperless-cloud-storage

Run [Paperless-ngx](https://github.com/paperless-ngx/paperless-ngx) on a small disk by keeping the document store in cloud storage, mounted via [rclone](https://rclone.org/). Only the database, search index, thumbnails and a bounded cache stay local — the collection can grow without the disk growing with it.

Cloud setup happens in a **browser**, through rclone's built-in web GUI. No `rclone config` in a terminal.

> **Status: experimental.** Verified working in both directions (serving documents and consuming new ones, integrity check passes), but without long-term production data yet. Read [What can go wrong](#what-can-go-wrong) before trusting it with documents you cannot lose.

## What you actually have to type

```bash
sudo ./setup.sh                                   # once, prepares the host
cp .env.example .env && $EDITOR .env              # base dir + a GUI password
docker compose -f storage.yml up -d       # starts the storage layer
```

Everything after that — connecting the cloud account, creating and managing mounts, watching transfers — happens in the web UI. Reach it through an SSH tunnel:

```bash
ssh -L 5522:localhost:5522 -L 5533:localhost:5533 <your-host>
```

then open `http://localhost:5522/login?url=localhost:5533`.

In the GUI, add your cloud remote, then create the mount at **`/mnt/inner/documents/originals`** with VFS cache mode `full` and **allow other** enabled. A helper inside the container (`bind-publish.sh`) automatically mirrors everything mounted under `/mnt/inner` to the host — a few seconds later it appears at `$BASE_DIR/media/documents/originals`, where Paperless picks it up. (Why the detour via `/mnt/inner`: see critical detail 2 below.)

Adding Paperless afterwards: **new install** → `docker compose -f paperless.yml up -d`. **Existing install** → [docs/RETROFIT.md](docs/RETROFIT.md), you keep your own compose file and change one volume block.

## Two independent layers

The storage layer knows nothing about Paperless. It provides a directory that happens to be backed by cloud storage — usable for anything, not just document management.

| Layer | What it is | File |
|---|---|---|
| **Storage** | rclone with its web GUI, doing the FUSE mount | `storage.yml` |
| **Paperless** | optional, for new installations | `paperless.yml` |

## How it works

Paperless reads document files rarely: search runs against the database (which holds the OCR text) and list views render thumbnails. The actual file is only opened on view or download. This template therefore:

- keeps **database, search index, thumbnails** on local disk — they need real locking and must never live on a cloud mount,
- mounts the **document store** from cloud storage with `rclone mount --vfs-cache-mode full`,
- publishes that mount from the rclone container to the host (`rshared`) and into the Paperless container (`rslave`),
- runs a **watchdog** that stops Paperless whenever the mount is missing.

Measured on a small home server (single measurements, orders of magnitude): first open of a ~600 KB document ~1.8 s, cached open ~20 ms, new document consumed and uploaded in ~20 s end to end.

## Works with any rclone backend

The provider is fully abstracted by rclone: the mount, the VFS cache, the propagation settings and the watchdog are identical for every one of the [70+ supported backends](https://rclone.org/overview/) — S3-compatible stores, Backblaze B2, OneDrive, Google Drive, WebDAV, SFTP, Proton Drive, and so on. Switching providers means picking a different remote in the GUI; nothing else in this template changes.

What differs per backend:

| Concern | Notes |
|---|---|
| Unattended auth | Must work without interactive prompts. Proton with 2FA breaks after ~35 min (see below); S3 key pairs or service accounts are unproblematic. |
| Change notifications | Some backends push changes; Proton does not (`poll-interval is not supported`) — relevant only if `consume/` is cloud-backed. |
| Maturity | S3/B2 backends are battle-tested; Proton Drive is explicitly beta in rclone. |
| Encryption | Proton offers end-to-end encryption out of the box; for other backends, layer [rclone crypt](https://rclone.org/crypt/) on top if needed. |

Tested with Proton Drive; an S3-compatible store is the more robust choice if you do not need Proton's end-to-end encryption.

## The four critical details

**1. The media directory must be a shared mount point.** Docker only propagates a mount out of a container when the bind source is itself a mount point with shared propagation. On a plain directory it silently downgrades `propagation: rshared` to slave and nothing ever reaches the host. `setup.sh` handles this and installs a systemd unit so it survives reboots. This is the one step that needs root.

**2. FUSE mounts must be created under `/mnt/inner`, not on `/data` directly.** Hosts that ship an AppArmor profile for `fusermount3` (Ubuntu does) only permit FUSE mounts on an allow-list of mount point patterns — `/mnt/**`, `/media/**`, `$HOME/**`, `/tmp/**` — matched against the path *as seen inside the container*. Mounting straight onto `/data/...` fails with `fusermount3: mount failed: Permission denied`, even in a privileged container; the kernel audit log shows `apparmor="DENIED" ... info="failed mntpnt match" profile="fusermount3"`. A plain bind mount is not fusermount3 and not covered by the profile — so `bind-publish.sh` mounts FUSE on the allowed `/mnt/inner` path and binds it onto the shared `/data`, from where it propagates to the host. Verified end to end on Ubuntu 25.10 (files visible and readable in a second container as uid 1000, recovery after a killed mount without restarting the consumer).

**3. `propagation: rslave` on the Paperless side.** Docker defaults to `rprivate`, so a mount created *after* the container started never reaches it — after any rclone restart the container is stuck on `Transport endpoint is not connected` until recreated. With `rslave` it picks the new mount up immediately (verified: restart counter unchanged).

**4. Stop on missing mount.** When the mount is down, the media path is a plain empty directory. Paperless would happily consume documents into it; the moment the mount returns, those files are shadowed by the mount point — present on disk, invisible to everything. The watchdog stops the webserver first and only starts it again once the mount is verified alive.

## Choosing the cloud account

Use a **dedicated cloud account** holding nothing but these documents. It must be able to sign in unattended:

- **no 2FA** on that dedicated account (recommended), **or**
- store the TOTP seed in the rclone config — which defeats 2FA for that account, and is only acceptable because the account is dedicated.

With Proton Drive specifically: a session established with a one-time 2FA code dies after ~35 minutes and cannot re-authenticate (`422 .../auth/v4/2fa`). This is why the account choice matters.

## Security note on the web UI

The GUI can read your cloud credentials and create mounts. `storage.yml` therefore binds it to `127.0.0.1` only. Reach it over an SSH tunnel, or put a reverse proxy with authentication in front of it. Do not expose those ports to the network.

## Settings explained (`paperless.env.example`)

| Setting | Why |
|---|---|
| `PAPERLESS_ARCHIVE_FILE_GENERATION=never` | Skips the second (PDF/A) copy of every document; the original is served instead. Halves the offloaded volume. Search is unaffected — the text lives in the database. |
| `PAPERLESS_SANITY_TASK_CRON=disable` | The scheduled sanity check reads **every file** to verify checksums — i.e. downloads the entire collection. Run `document_sanity_checker` manually instead when needed. |
| `PAPERLESS_CONSUMER_POLLING_INTERVAL` | Only if `consume/` is also cloud-backed: inotify cannot see changes made from outside on a FUSE mount. |

## What can go wrong

- **Upload window.** A newly consumed document lives only in the local VFS cache until rclone uploads it (seconds). If the machine dies inside that window, the database row exists but the file is gone.
- **Cache overshoot.** `--vfs-cache-max-size` is enforced by a cleanup pass roughly once per minute. During bursts the cache can temporarily hold far more — budget for the peak, not the limit.
- **Full-store operations.** `document_exporter`, thumbnail regeneration and re-OCR read everything → full download. Back up the database and index instead; the documents are already in the cloud. If you need real redundancy, add an independent second copy (e.g. `rclone copy` to another remote) — the cloud store is primary storage here, not a backup.
- **Proton Drive backend is beta** in rclone. Under rapid successive API calls it returned inconsistent directory listings (throttling). S3-compatible backends are more mature.

## Running rclone on the host instead

If you would rather not run rclone in a container — no GUI, no shared mount point needed — `systemd/rclone-paperless-media.service` mounts directly on the host. Paperless still needs `propagation: rslave`. This is the variant the measurements were taken with.

## Background

Full write-up with measurements and methodology: [rafaelpfister.ch](https://rafaelpfister.ch/blog/paperless-dokumente-proton-drive-auslagern) ([English](https://rafaelpfister.ch/en/blog/offloading-paperless-documents-to-proton-drive)).

## License

MIT

# paperless-cloud-storage

Run [Paperless-ngx](https://github.com/paperless-ngx/paperless-ngx) on a small disk by keeping the document store in cloud storage, mounted via [rclone](https://rclone.org/). Only the database, search index, thumbnails and a bounded cache stay local — the collection can grow without the disk growing with it.

> **Status: experimental.** Verified working in both directions (serving documents and consuming new ones, integrity check passes), but without long-term production data yet. Read [What can go wrong](#what-can-go-wrong) before trusting it with documents you cannot lose.

## Setup

On the server, inside the cloned repository:

```bash
cd paperless-cloud-storage
sudo ./setup.sh      # once, prepares the host (the only step that needs root)
./wizard.sh          # guided: pick provider, credentials, verified round trip
```

The wizard asks which provider you use, tests the connection with a real upload/download round trip, writes the mount definition and starts the storage container. When it prints its final ✔, the cloud directory is live on the host.

Then add Paperless: **new install** → `docker compose -f paperless.yml up -d`. **Existing install** → [docs/RETROFIT.md](docs/RETROFIT.md), you keep your own compose file and change one volume block.

There is deliberately **no web interface**: anyone able to run the commands above is faster answering three questions in the terminal than tunnelling to a browser UI, and it removes an attack surface that would sit in front of your cloud credentials. (We tried rclone's web GUI first; the tunnel/CORS/session friction was worse than the CLI it was meant to replace.)

## Which providers work?

**Any of rclone's [70+ backends](https://rclone.org/overview/).** The mount layer — VFS cache, mount propagation, publishing, watchdog — is identical for all of them; only the credential handshake differs. The wizard has tailored prompts for the common cases (Proton Drive, S3-compatible, Backblaze B2, WebDAV, SFTP) and a **"Not in the list"** option that drops into rclone's own configuration dialog for everything else (including OAuth providers like Google Drive or OneDrive — follow the printed `rclone authorize` instructions), then continues with the same verification and mount steps.

What differs per backend:

| Concern | Notes |
|---|---|
| Unattended auth | Must work without interactive prompts. Proton with 2FA breaks after ~35 min (see below); S3 key pairs or service accounts are unproblematic. OAuth tokens refresh automatically once authorized. |
| Change notifications | Some backends push changes; Proton does not (`poll-interval is not supported`) — relevant only if `consume/` is cloud-backed. |
| Maturity | S3/B2 backends are battle-tested; Proton Drive is explicitly beta in rclone. |
| Encryption | Proton offers end-to-end encryption out of the box; for other backends, layer [rclone crypt](https://rclone.org/crypt/) on top if needed. |

Tested with Proton Drive; an S3-compatible store is the more robust choice if you do not need Proton's end-to-end encryption.

## How it works

Paperless reads document files rarely: search runs against the database (which holds the OCR text) and list views render thumbnails. The actual file is only opened on view or download. This template therefore:

- keeps **database, search index, thumbnails** on local disk — they need real locking and must never live on a cloud mount,
- mounts the **document store** from cloud storage with `rclone mount --vfs-cache-mode full`, driven by `mounts.conf` (written by the wizard, read at every container start — mounts survive restarts),
- publishes the mounts from the rclone container to the host (`rshared`) and into the Paperless container (`rslave`),
- **self-heals**: a dead mount makes the storage container exit and restart, and Paperless picks the fresh mount up without a restart of its own,
- runs a **watchdog** that stops Paperless whenever the mount is missing.

Measured on a small home server (single measurements, orders of magnitude): first open of a ~600 KB document ~1.8 s, cached open ~20 ms, new document consumed and uploaded in ~20 s end to end.

## The four critical details

**1. The media directory must be a shared mount point.** Docker only propagates a mount out of a container when the bind source is itself a mount point with shared propagation. On a plain directory it silently downgrades `propagation: rshared` to slave and nothing ever reaches the host. `setup.sh` handles this and installs a systemd unit so it survives reboots. This is the one step that needs root.

**2. FUSE mounts must be created under `/mnt/inner`, not on `/data` directly.** Hosts that ship an AppArmor profile for `fusermount3` (Ubuntu does) only permit FUSE mounts on an allow-list of mount point patterns — `/mnt/**`, `/media/**`, `$HOME/**`, `/tmp/**` — matched against the path *as seen inside the container*. Mounting straight onto `/data/...` fails with `fusermount3: mount failed: Permission denied`, even in a privileged container; the kernel audit log shows `apparmor="DENIED" ... info="failed mntpnt match" profile="fusermount3"`. A plain bind mount is not fusermount3 and not covered by the profile — so `mount-runner.sh` mounts FUSE on the allowed `/mnt/inner` path and binds it onto the shared `/data`, from where it propagates to the host. Verified end to end on Ubuntu 25.10.

**3. `propagation: rslave` on the Paperless side.** Docker defaults to `rprivate`, so a mount created *after* the container started never reaches it — after any rclone restart the container is stuck on `Transport endpoint is not connected` until recreated. With `rslave` it picks the new mount up immediately (verified: restart counter unchanged).

**4. Stop on missing mount.** When the mount is down, the media path is a plain empty directory. Paperless would happily consume documents into it; the moment the mount returns, those files are shadowed by the mount point — present on disk, invisible to everything. The watchdog stops the webserver first and only starts it again once the mount is verified alive.

## Choosing the cloud account

Use a **dedicated cloud account** holding nothing but these documents. It must be able to sign in unattended:

- **no 2FA** on that dedicated account (recommended), **or**
- store the TOTP seed in the rclone config — which defeats 2FA for that account, and is only acceptable because the account is dedicated.

With Proton Drive specifically: a session established with a one-time 2FA code dies after ~35 minutes and cannot re-authenticate (`422 .../auth/v4/2fa`). This is why the account choice matters.

## Settings explained (`paperless.env.example`)

| Setting | Why |
|---|---|
| `PAPERLESS_ARCHIVE_FILE_GENERATION=never` | Skips the second (PDF/A) copy of every document; the original is served instead. Halves the offloaded volume. Search is unaffected — the text lives in the database. |
| `PAPERLESS_SANITY_TASK_CRON=disable` | The scheduled sanity check reads **every file** to verify checksums — i.e. downloads the entire collection. Run `document_sanity_checker` manually instead when needed. |
| `PAPERLESS_CONSUMER_POLLING_INTERVAL` | Only if `consume/` is also cloud-backed: inotify cannot see changes made from outside on a FUSE mount. |

## What can go wrong

- **Upload window.** A newly consumed document lives only in the local VFS cache until rclone uploads it (seconds). If the machine dies inside that window, the database row exists but the file is gone.
- **Cache overshoot.** `VFS_CACHE_MAX` is enforced by a cleanup pass roughly once per minute. During bursts the cache can temporarily hold far more — budget for the peak, not the limit.
- **Full-store operations.** `document_exporter`, thumbnail regeneration and re-OCR read everything → full download. Back up the database and index instead; the documents are already in the cloud. If you need real redundancy, add an independent second copy (e.g. `rclone copy` to another remote) — the cloud store is primary storage here, not a backup.
- **Proton Drive backend is beta** in rclone. Under rapid successive API calls it returned inconsistent directory listings (throttling). S3-compatible backends are more mature.

## Running rclone on the host instead

If you would rather not run rclone in a container, `systemd/rclone-paperless-media.service` mounts directly on the host — no shared mount point needed, but you configure the remote with `rclone config` yourself. Paperless still needs `propagation: rslave`. This is the variant the measurements were taken with.

## Background

Full write-up with measurements and methodology: [rafaelpfister.ch](https://rafaelpfister.ch/blog/paperless-dokumente-proton-drive-auslagern) ([English](https://rafaelpfister.ch/en/blog/offloading-paperless-documents-to-proton-drive)).

## License

MIT

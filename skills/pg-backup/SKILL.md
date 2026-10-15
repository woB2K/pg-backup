---
name: pg-backup
description: Set up, verify or restore PostgreSQL backups with the pg-backup Docker image (ghcr.io/wob2k/pg-backup), which ships pg_dump, restic and rclone to back up a database and upload folders to Google Drive, S3 or other storage. Use when the user asks to add database backups to a docker compose project, back up Postgres or uploaded files, mentions pg-backup, restic or rclone backups, or needs to check, troubleshoot or restore such a backup.
---

# pg-backup

pg-backup is a sidecar service for a docker compose project. On a cron schedule it dumps PostgreSQL with `pg_dump`, optionally backs up folders, encrypts and deduplicates everything with restic, and uploads it through rclone (Google Drive by default). Full documentation, in Russian: https://github.com/woB2K/pg-backup (raw: https://raw.githubusercontent.com/woB2K/pg-backup/main/README.md).

## What you do and what the human does

You prepare the project: compose service, env template, validation and a handoff checklist. The human finishes on the server, because three steps need them:

- `rclone config` is interactive and needs a browser login to Google on their own computer.
- `BACKUP_PASSWORD` is a secret. They generate it, store it in `.env` on the server and keep a copy in their password manager.
- The commands run on the production server, where the real `.env` lives.

Never write real secrets into tracked files, never print or read the values in a real `.env`, and never run `restore apply` or `restore files apply` without the user's explicit confirmation in this conversation: both replace production data.

## 1. Inspect the project

Find out, before editing anything:

1. **Compose files.** Look for `docker-compose.yml`, `compose.yaml` and per-environment variants (`docker-compose.prod.yml`). Ask which one production uses if it isn't obvious.
2. **Where PostgreSQL runs:**
   - A service in the same compose file (image `postgres:NN`, `postgis/postgis:NN-…`, `bitnami/postgresql:NN`…) → standard setup.
   - Another compose project, the host, or a managed service (Supabase, Neon, RDS…) → see "Other database locations" below.
   - MySQL, MariaDB, MongoDB, SQLite → stop and tell the user pg-backup supports only PostgreSQL.
3. **PostgreSQL major version.** It is the image tag: `postgres:17-alpine` → `17`. Supported: 15, 16, 17, 18. If the tag is `latest` or missing, ask the user to pin a version; pg-backup needs to know it.
4. **Credential variable names.** Usually `POSTGRES_USER`, `POSTGRES_PASSWORD`, `POSTGRES_DB`, but reuse whatever the project already has. Note the name of the database service; it becomes `PGHOST`.
5. **Healthcheck** on the database service. It decides between `service_healthy` and `service_started`.
6. **Uploaded files on disk.** Check volumes and bind mounts of the app service and the framework:

   | Framework | Usual folder |
   |---|---|
   | Strapi | `public/uploads`, e.g. `/opt/app/public/uploads` |
   | Directus | `/directus/uploads` |
   | Django | `MEDIA_ROOT` |
   | Rails, Active Storage Disk service | `storage/`, e.g. `/rails/storage` |
   | Laravel | `storage/app` |

   If uploads go to S3 or another object storage, there is nothing to mount.
7. **Env template.** Find `.env.example`, `.env.docker.example` or similar, and how the project documents operations.

## 2. Add the service

```yaml
services:
  backup:
    image: ghcr.io/wob2k/pg-backup:16
    restart: unless-stopped
    init: true
    environment:
      PGHOST: db
      PGUSER: ${POSTGRES_USER:?set POSTGRES_USER in .env}
      PGPASSWORD: ${POSTGRES_PASSWORD:?set POSTGRES_PASSWORD in .env}
      PGDATABASE: ${POSTGRES_DB:?set POSTGRES_DB in .env}
      RESTIC_REPOSITORY: ${BACKUP_REPOSITORY:?set BACKUP_REPOSITORY in .env}
      RESTIC_PASSWORD: ${BACKUP_PASSWORD:?set BACKUP_PASSWORD in .env}
      BACKUP_SCHEDULE: '${BACKUP_SCHEDULE:-0 1 * * *}'
      BACKUP_PING_URL: ${BACKUP_PING_URL:-}
    volumes:
      - backup-state:/var/lib/backup
    depends_on:
      db:
        condition: service_healthy

volumes:
  backup-state:
```

Adapt it:

- Image tag = the PostgreSQL major version from step 1.
- For production, pin the image by digest. The container holds the database password, the encryption key and the storage token, so a new image should arrive only through a reviewed change, not on the next pull of a floating tag. Find the latest release with `git ls-remote --tags https://github.com/woB2K/pg-backup`, get its digest with `docker buildx imagetools inspect ghcr.io/wob2k/pg-backup:<major>-<version> --format '{{json .Manifest.Digest}}'` and write `image: ghcr.io/wob2k/pg-backup:<major>-<version>@sha256:<digest>`. If Docker isn't available locally, keep `:<major>-<version>` and tell the user to pin the digest later.
- `PGHOST` = the database service name. `PG*` values = the project's variable names.
- No healthcheck on the database → `condition: service_started`, or add a `pg_isready` healthcheck if the project is fine with that.
- Uploads: mount the same named volume or host folder into `backup` **without `:ro`**, under `/data/<name>`, and set `BACKUP_PATHS` to those paths separated by spaces. Paths can't contain spaces.
- Keep the `backup-state` volume name unique within the file; it holds the rclone token and restic cache.

### Other database locations

- **Another compose project:** join its network (`networks: [database]` plus a top-level `database: { external: true, name: <project>_default }`), set `PGHOST` to its service name and remove `depends_on`.
- **On the host:** `PGHOST: host.docker.internal` plus `extra_hosts: [host.docker.internal:host-gateway]`, remove `depends_on`. On Linux, PostgreSQL must listen on the Docker bridge and allow it in `pg_hba.conf`.
- **Managed service:** `PGHOST`, `PGPORT`, `PGSSLMODE: require`, remove `depends_on`. Warn the user that `restore apply` renames databases, which managed services often forbid; restore there means extracting the dump and running `pg_restore` by hand.
- **Several databases:** one service per database. They can share one repository, password and `backup-state` volume, because `BACKUP_NAME` (default `PGDATABASE`) keeps snapshots apart. Stagger `BACKUP_SCHEDULE` by at least 30 minutes, or pruning collides with `repository is already locked`.

### Other storage

Google Drive is the default. Any rclone remote works (`rclone:<remote>:<folder>`), and restic speaks S3 and B2 natively: `RESTIC_REPOSITORY: s3:https://…/bucket/path` with `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY` passed through `environment`.

## 3. Env template

Add to the project's env template, never to a real `.env`:

```env
BACKUP_REPOSITORY=rclone:gdrive:<project>-backup
BACKUP_PASSWORD=
BACKUP_PING_URL=
BACKUP_SCHEDULE='0 1 * * *'
```

Use a folder name unique to this project. The schedule is UTC: if you know the user's time zone, suggest a value that falls at night for them.

## 4. Validate

Compose checks every variable in the file, even for one service, so validate with a temporary env file **outside the repository** that has dummy values for every `${VAR:?…}` in the compose file:

```bash
docker compose --env-file /tmp/pg-backup-check.env config --quiet
```

It must print nothing. Warnings like `The "x" variable is not set` mean a `$` inside some value is being interpolated. Delete the temporary file afterwards. If Docker is available, `docker compose --env-file … pull backup` confirms the image tag exists.

If the project documents its infrastructure (README, ops docs, architecture notes), add a short section: what the service does, the repository folder, and a link to https://github.com/woB2K/pg-backup for setup and restore.

## 5. Hand off to the human

Finish with a checklist adapted to the project: the real compose folder on the server, the repository folder name, `sudo` if their deploy tool keeps `.env` readable only by root. Commands run on the server, in the folder with the production `docker-compose.yml` and `.env`:

1. Deploy the change, then add `BACKUP_PASSWORD` to the server's `.env`, or to the deploy panel's environment if a panel manages the stack. Generate it with `openssl rand -hex 32` (macOS, Linux) or in PowerShell: `$b = New-Object byte[] 32; [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($b); -join ($b | ForEach-Object { $_.ToString('x2') })`. Save a copy without quotes in a password manager.
2. `docker compose config --quiet` prints nothing.
3. `docker compose run --rm backup rclone config` with these answers: `n`, name `gdrive`, storage `drive`, empty `client_id` and `client_secret`, scope `drive.file`, empty `service_account_file`, advanced config `n`, auto config `n`.
4. rclone prints `rclone authorize "drive" "…"`. On a computer with a browser, install rclone (macOS: `brew install rclone`; Windows: `winget install Rclone.Rclone` and a new terminal; Linux: `sudo -v ; curl https://rclone.org/install.sh | sudo bash`), run that command and sign in. Paste the JSON between `--->` and `<---End paste` into `config_token>` on the server. Then: Shared Drive `n`, keep `y`, quit `q`.
5. `docker compose run --rm backup restic init`. On Google Drive it takes a few minutes with no output.
6. `docker compose run --rm backup backup`, then `docker compose run --rm backup restore check`. Row counts should match the app.
7. `docker compose up -d`, or redeploy from the panel.
8. Recommended: a Cron check on healthchecks.io with the same schedule, time zone UTC, grace 1 hour. Put its URL in `BACKUP_PING_URL` and redeploy.

## Everyday commands

| Task | Command |
|---|---|
| List snapshots | `docker compose run --rm backup restic snapshots` |
| Back up now | `docker compose run --rm backup backup` |
| Verify the database restores (safe) | `docker compose run --rm backup restore check [snapshot]` |
| Verify files restore (safe) | `docker compose run --rm backup restore files check [snapshot]` |
| Restore the database | stop the app, then `docker compose run --rm backup restore apply [snapshot]`, then `docker compose up -d` |
| Restore files | `docker compose run --rm backup restore files apply [snapshot]` |
| Logs | `docker compose logs backup` |

`restore apply` loads the snapshot into `<db>_restore`, swaps it in with one transaction only on success and keeps the old database as `<db>_before_restore`. It asks the operator to type the database name; that prompt is the human's confirmation, so don't pipe the answer in for them.

## Troubleshooting

| Symptom | Cause and fix |
|---|---|
| `required variable X is missing a value` | Commands run where the real `.env` isn't: a laptop or another checkout. Run them on the server, in the folder the deploy uses (`docker compose ls` shows it) |
| `open …/.env: permission denied` | The deploy tool keeps `.env` owned by root. Prefix commands with `sudo` and leave the file's permissions alone |
| `The "x" variable is not set` warnings | A value in `.env` contains `$`, even inside double quotes. Regenerate the secret as hex or use single quotes. Changing a live secret changes what the app uses, so check the consequences first: a database password also has to change inside PostgreSQL |
| `server version mismatch` from `pg_dump` | The pg-backup tag is older than the database. Bump the tag to the database's major version |
| `didn't find section in config file` | The rclone remote name differs from the one in `BACKUP_REPOSITORY`, or `rclone config` was never run for this volume |
| `restic init` seems to hang | Normal on Google Drive: it creates about 260 folders. Wait a few minutes |
| `repository is already locked` | Two runs overlap, often several databases on the same schedule. Stagger the schedules. Run `restic unlock` only after making sure no backup is running |
| `restore` can't find `latest` | `BACKUP_NAME` or `PGDATABASE` changed. Snapshots are filed under the old name: set `BACKUP_NAME` back to it, or pass a snapshot ID |
| A run fails after adding `BACKUP_PATHS` | A listed folder isn't mounted into the `backup` container |

# pg-backup

[Русский](README.md) | **English**

[![image](https://github.com/woB2K/pg-backup/actions/workflows/image.yml/badge.svg)](https://github.com/woB2K/pg-backup/actions/workflows/image.yml)

Nightly PostgreSQL backups, and optionally your uploaded files, to Google Drive or any other storage. Everything is encrypted with [restic](https://restic.net) before it leaves the server. Add one service to your `docker-compose.yml`:

```yaml
image: ghcr.io/wob2k/pg-backup:16
```

- **Encrypted before upload.** The storage only ever sees random bytes.
- **Deduplicated.** Each night uploads only what changed, not the whole dump.
- **Retention** out of the box: 7 daily, 4 weekly and 6 monthly snapshots.
- **Verified.** Every run checks repository integrity, and `restore check` proves a snapshot really restores without touching production.
- **Safe restore.** The snapshot is loaded next to the live database and swapped in only when it restored cleanly. The old database is kept.
- **Files too.** Upload folders are backed up in the same run: Strapi, Directus, Django media, Rails Active Storage and so on.
- **Monitoring.** Pings [healthchecks.io](https://healthchecks.io) on start, success and failure.
- **PostgreSQL 15–18** on `linux/amd64` and `linux/arm64`.

## Contents

- [How it works](#how-it-works)
- [Requirements](#requirements)
- [Quick start](#quick-start)
- [With Claude Code](#with-claude-code)
- [Configuration](#configuration)
- [Recipes](#recipes): uploaded files, a database in another compose project, on the host, managed Postgres, several databases, other storage
- [Everyday commands](#everyday-commands)
- [Restore](#restore)
- [Disaster recovery](#disaster-recovery)
- [Pitfalls](#pitfalls)
- [Under the hood](#under-the-hood)
- [Development](#development)

## How it works

```
your server (docker compose)
 ├─ db ──────── your PostgreSQL
 └─ backup ──── sleeps until BACKUP_SCHEDULE, then:
      1. pg_dump → takes a consistent dump of the database
      2. restic  → splits it into chunks, encrypts them, skips chunks it already has
      3. rclone  → uploads the new chunks to Google Drive
      4. the same for folders in BACKUP_PATHS, if set
      5. forgets old snapshots and checks the repository
                          ↓
            Google Drive / my-app-backup
```

There are two secrets, and they do different jobs:

| | What it is | Where it lives | If you lose it |
|---|---|---|---|
| Google token | rclone's permission to use your Drive (OAuth) | `rclone.conf` in the `backup-state` volume | No harm done. Run `rclone config` again, about five minutes |
| `BACKUP_PASSWORD` | restic's encryption key | Your `.env`, plus **a copy outside the server** | Every backup becomes unreadable, forever |

Google hands out the token through a browser login. Servers usually have no browser, so you authorize once on your own computer (macOS, Windows or Linux) and paste the token into the server.

## Requirements

- A server with Docker Engine and Docker Compose v2.
- PostgreSQL 15–18 that the container can reach. The simplest setup is a database in the same `docker-compose.yml`, but [other setups](#recipes) work too.
- A Google account, or any other storage that [rclone or restic supports](#other-storage).
- Once, during setup: any computer with a web browser.

## Quick start

All `docker compose` commands below run **on the server**, in the folder with your project's `docker-compose.yml`.

### 1. Add the service

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

Adjust it to your project:

- **The tag is your PostgreSQL major version.** A database on `postgres:17` needs `pg-backup:17`. An older `pg_dump` refuses to dump a newer server.
- **In production, pin the image by digest.** The container holds the database password, the encryption key and the storage token. With the floating `:16` tag, any new version arrives on the next pull. With a digest, an update becomes an explicit change in your repository:

  ```yaml
  image: ghcr.io/wob2k/pg-backup:16-1.0.0@sha256:<digest>
  ```

  The latest version is in the [repository tags](https://github.com/woB2K/pg-backup/tags), and `docker buildx imagetools inspect ghcr.io/wob2k/pg-backup:16-1.0.0` shows its digest. The tag is there only for readability: Docker pulls exactly the image with that digest.
- `PGHOST` is the name of the database service in your compose file: `db`, `postgres`, `database` or whatever yours is called.
- `POSTGRES_*` are the variable names your project already uses.
- `condition: service_healthy` needs a healthcheck on the database service. If it has none, add one or use `service_started`.
- `PGUSER` should own the database or be a superuser, because `restore apply` renames databases. With the official `postgres` image, the `POSTGRES_USER` user already is a superuser.

### 2. Environment variables

Add to the `.env` next to `docker-compose.yml`:

```env
BACKUP_REPOSITORY=rclone:gdrive:my-app-backup
BACKUP_PASSWORD=
BACKUP_PING_URL=
BACKUP_SCHEDULE='0 1 * * *'
```

- `BACKUP_REPOSITORY` is the folder on Drive. **Use a separate folder for each project.**
- `BACKUP_PASSWORD` is a long random password with letters and digits only:

  | OS | Command |
  |---|---|
  | macOS, Linux | `openssl rand -hex 32` |
  | Windows (PowerShell) | `$b = New-Object byte[] 32; [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($b); -join ($b \| ForEach-Object { $_.ToString('x2') })` |

  Save a copy in your password manager **right away**. Copy it without quotes.
- `BACKUP_SCHEDULE` is a cron expression in **UTC**. `0 1 * * *` is 01:00 UTC; convert it to your night time.

### 3. Connect Google Drive

This is done once per project. On the server:

```bash
docker compose run --rm backup rclone config
```

| Prompt | Answer |
|---|---|
| `n/s/q>` | `n` |
| `name>` | `gdrive` (must match the name in `BACKUP_REPOSITORY`) |
| `Storage>` | `drive` |
| `client_id>` | Enter, leave empty. See [Pitfalls](#pitfalls) |
| `client_secret>` | Enter |
| `scope>` | `drive.file` |
| `service_account_file>` | Enter |
| `Edit advanced config?` | `n` |
| `Use web browser to automatically authenticate rclone with remote?` | `n` |

rclone prints a command like `rclone authorize "drive" "eyJ…"` and waits at `config_token>`. **Leave that terminal open** and run the command on any computer with a browser.

**Install rclone on that computer**

| OS | Command |
|---|---|
| macOS | `brew install rclone`, or without Homebrew: `curl -O https://downloads.rclone.org/rclone-current-osx-arm64.zip && unzip rclone-current-osx-arm64.zip` (`osx-amd64` on Intel Macs) |
| Windows | `winget install Rclone.Rclone`, then open a **new** terminal |
| Linux | `sudo -v ; curl https://rclone.org/install.sh \| sudo bash` |

Downloading with `curl` on macOS avoids Gatekeeper. If you downloaded the zip in a browser and macOS refuses to run the binary, run `xattr -d com.apple.quarantine ./rclone` in its folder. You can also download any build by hand from [rclone.org/downloads](https://rclone.org/downloads/).

**Authorize**

Paste the command from the server, keeping the long string as it is:

| OS | Command |
|---|---|
| macOS, Linux | `rclone authorize "drive" "eyJ…"`, or `./rclone-*-osx-arm64/rclone authorize "drive" "eyJ…"` for the zip build on a Mac |
| Windows | `rclone authorize "drive" "eyJ…"` |

A browser opens: sign in to Google and allow access. The terminal then prints a JSON token between `Paste the following into your remote machine --->` and `<---End paste`. Copy the whole JSON into `config_token>` on the server. It is a key to your Drive, so don't paste it anywhere else.

Finish on the server:

| Prompt | Answer |
|---|---|
| `Configure this as a Shared Drive (Team Drive)?` | `n` |
| `Keep this "gdrive" remote?` | `y` |
| `e/n/d/r/c/s/q>` | `q` |

### 4. Create the repository

```bash
docker compose run --rm backup restic init
```

On Google Drive this takes a few minutes: restic creates about 260 folders and prints nothing until the end. Don't interrupt it; it finishes with `created restic repository`.

### 5. First backup and restore test

```bash
docker compose run --rm backup backup
```

```bash
docker compose run --rm backup restore check
```

`restore check` loads the snapshot into a temporary database, prints row counts per table and drops it. Compare the numbers with what you see in your app.

### 6. Start the schedule

```bash
docker compose up -d
```

The rclone config lives in the volume, so a backup container that is already running picks it up without a restart.

### 7. Monitoring (strongly recommended)

Without monitoring you find out that backups broke on the day you need one.

1. On [healthchecks.io](https://healthchecks.io) (free tier, or self-hosted), create a check of type **Cron** with the same expression as `BACKUP_SCHEDULE`, time zone UTC, grace time 1 hour.
2. Put its ping URL into `BACKUP_PING_URL` and run `docker compose up -d` again.

The container pings `/start` before each run, the URL itself on success and `/fail` on error. healthchecks.io emails you when a run fails or doesn't happen at all.

## With Claude Code

The repository ships a skill for [Claude Code](https://claude.com/claude-code): [`skills/pg-backup/SKILL.md`](skills/pg-backup/SKILL.md). With it, Claude inspects your project, finds the database, its version and upload folders, adds the service to compose and the variables to your `.env` template, validates the config and hands you a checklist of what's left to do on the server. Signing in to Google and creating the password are still up to you.

**Install it for all your projects:**

| OS | Command |
|---|---|
| macOS, Linux | `mkdir -p ~/.claude/skills/pg-backup && curl -fsSL https://raw.githubusercontent.com/woB2K/pg-backup/main/skills/pg-backup/SKILL.md -o ~/.claude/skills/pg-backup/SKILL.md` |
| Windows (PowerShell) | `New-Item -ItemType Directory -Force "$HOME\.claude\skills\pg-backup" \| Out-Null; Invoke-WebRequest https://raw.githubusercontent.com/woB2K/pg-backup/main/skills/pg-backup/SKILL.md -OutFile "$HOME\.claude\skills\pg-backup\SKILL.md"` |

Run the same command to update the skill.

**For one project and the whole team:** put the file into the project as `.claude/skills/pg-backup/SKILL.md` and commit it.

**Without installing:** just tell Claude Code in your project: "Set up database backups following https://raw.githubusercontent.com/woB2K/pg-backup/main/skills/pg-backup/SKILL.md".

With the skill installed, "add database backups to Google Drive" is enough. It also helps you check a backup, troubleshoot an error or restore.

## Configuration

| Variable | Default | Description |
|---|---|---|
| `PGHOST` | | **Required.** Database host |
| `PGDATABASE` | | **Required.** Database name |
| `PGUSER`, `PGPASSWORD` | | Database credentials |
| `PGPORT`, `PGSSLMODE` and other [libpq variables](https://www.postgresql.org/docs/current/libpq-envars.html) | | Passed to `pg_dump`, `pg_restore` and `psql` as is |
| `RESTIC_REPOSITORY` | | **Required.** Where snapshots go, for example `rclone:gdrive:my-app-backup` |
| `RESTIC_PASSWORD` | | **Required.** Encryption password |
| `BACKUP_SCHEDULE` | `0 1 * * *` | Cron expression, **UTC** |
| `BACKUP_PING_URL` | | healthchecks.io ping URL |
| `BACKUP_PATHS` | | Folders inside the container to back up with the database, separated by spaces |
| `BACKUP_NAME` | `$PGDATABASE` | Snapshot host in restic and dump file name `<name>.dump` |
| `BACKUP_KEEP_DAILY` | `7` | Daily snapshots to keep |
| `BACKUP_KEEP_WEEKLY` | `4` | Weekly snapshots to keep |
| `BACKUP_KEEP_MONTHLY` | `6` | Monthly snapshots to keep |

Every other variable reaches restic and rclone as well, for example `AWS_ACCESS_KEY_ID` for an S3 repository.

## Recipes

### App and database in one compose file

This is the [Quick start](#quick-start) setup. It fits any stack that keeps its data in PostgreSQL: Node.js with Prisma or TypeORM, NestJS, Next.js, Nuxt, Strapi, Django, Rails, Laravel, Go, .NET. The application's language doesn't matter, only the database does.

### Uploaded files

If your app stores uploads on disk, a database backup alone isn't enough: after a restore, records point to files that don't exist. Mount the same folder into `backup` and list it in `BACKUP_PATHS`.

With a named volume:

```yaml
services:
  app:
    volumes:
      - uploads:/opt/app/public/uploads

  backup:
    environment:
      BACKUP_PATHS: /data/uploads
    volumes:
      - backup-state:/var/lib/backup
      - uploads:/data/uploads

volumes:
  uploads:
  backup-state:
```

With a bind mount, mount the same host folder: `./public/uploads:/data/uploads`.

Where uploads usually live inside the app container (check your own project):

| Project | Folder |
|---|---|
| Strapi | `public/uploads` in the app folder, e.g. `/opt/app/public/uploads` |
| Directus | `/directus/uploads` |
| Django | wherever `MEDIA_ROOT` points |
| Rails, Active Storage Disk service | `storage/`, e.g. `/rails/storage` |
| Laravel | `storage/app` |

Notes:

- Separate several folders with spaces: `BACKUP_PATHS: /data/uploads /data/avatars`. Paths can't contain spaces.
- Each run makes two snapshots, one for the database and one for the files. Retention applies to each separately.
- Don't mount with `:ro`, otherwise `restore files apply` has nowhere to write.
- If a folder is missing (you forgot the mount), the run fails and pings `/fail`. That is on purpose: silently backing up nothing is worse.
- If you change `BACKUP_PATHS`, `latest` for files only counts snapshots with the new set of folders. Older snapshots stay available by ID.

### Database in another compose project

Attach `backup` to the database project's network. `docker network ls` shows its name, usually `<project>_default`.

```yaml
services:
  backup:
    environment:
      PGHOST: db
    networks:
      - database

networks:
  database:
    external: true
    name: other-project_default
```

Remove `depends_on`: compose can't wait for a service from another project.

### Database installed on the host

```yaml
services:
  backup:
    environment:
      PGHOST: host.docker.internal
    extra_hosts:
      - host.docker.internal:host-gateway
```

Remove `depends_on`. On Linux, PostgreSQL must also accept connections from the Docker network: set `listen_addresses` in `postgresql.conf` and allow the Docker subnet in `pg_hba.conf`. With Docker Desktop on macOS and Windows, connections usually arrive from the host itself and work without these changes.

### Managed PostgreSQL

Supabase, Neon, Amazon RDS, DigitalOcean and similar services:

```yaml
services:
  backup:
    environment:
      PGHOST: db.example.com
      PGPORT: 5432
      PGSSLMODE: require
```

Remove `depends_on`. Pick the tag that matches the server's major version.

Backups and `restore check` work as long as the user may create databases. `restore apply` renames databases, which managed services often forbid. Restore by hand instead: [extract the dump](#without-docker) and run `pg_restore` against the target database. Your provider probably keeps its own backups too. This gives you an independent copy that you control.

### Several databases

Use one service per database. They can share one repository, one password and one Google authorization; `BACKUP_NAME`, which defaults to the database name, keeps their snapshots apart.

```yaml
x-backup: &backup
  image: ghcr.io/wob2k/pg-backup:16
  restart: unless-stopped
  init: true
  volumes:
    - backup-state:/var/lib/backup

x-backup-env: &backup-env
  PGHOST: db
  PGUSER: ${POSTGRES_USER}
  PGPASSWORD: ${POSTGRES_PASSWORD}
  RESTIC_REPOSITORY: ${BACKUP_REPOSITORY}
  RESTIC_PASSWORD: ${BACKUP_PASSWORD}

services:
  backup-app:
    <<: *backup
    environment:
      <<: *backup-env
      PGDATABASE: app
      BACKUP_SCHEDULE: '0 1 * * *'

  backup-analytics:
    <<: *backup
    environment:
      <<: *backup-env
      PGDATABASE: analytics
      BACKUP_SCHEDULE: '30 1 * * *'
```

Run `rclone config` and `restic init` once, through either service. **Stagger the schedules.** Cleanup locks the repository, so of two simultaneous runs one fails with `repository is already locked`.

### Other storage

Google Drive is only an example. Anything rclone supports works the same way: Dropbox, OneDrive, Backblaze B2, any S3-compatible storage, SFTP, WebDAV, a NAS. In `rclone config`, pick a different `Storage>` type and point the repository at that remote:

```env
BACKUP_REPOSITORY=rclone:dropbox:my-app-backup
```

restic also talks to S3 and B2 directly, without rclone. Pass the credentials as environment variables:

```yaml
environment:
  RESTIC_REPOSITORY: s3:https://s3.eu-central-1.amazonaws.com/my-bucket/my-app
  AWS_ACCESS_KEY_ID: ${AWS_ACCESS_KEY_ID}
  AWS_SECRET_ACCESS_KEY: ${AWS_SECRET_ACCESS_KEY}
```

## Everyday commands

| Task | Command |
|---|---|
| List snapshots | `docker compose run --rm backup restic snapshots` |
| Back up now | `docker compose run --rm backup backup` |
| Check that the database restores | `docker compose run --rm backup restore check [snapshot]` |
| Check that files restore | `docker compose run --rm backup restore files check [snapshot]` |
| Logs of scheduled runs | `docker compose logs backup` |
| Update the image | If pinned by digest, change the tag and digest in compose. Then `docker compose pull backup && docker compose up -d backup` |

Without `snapshot`, the latest one is used. `restic snapshots` lists the IDs.

`restore check` and `restore files check` never touch production: they restore into a temporary database or folder, print what they found and clean up. Run them once a month. A backup that has never been restored doesn't count as a backup.

## Restore

### Database

Stop everything that connects to the database: PostgreSQL won't rename a database with open connections.

```bash
docker compose stop app
```

```bash
docker compose run --rm backup restore apply [snapshot]
```

```bash
docker compose up -d
```

`restore apply` asks you to type the database name, loads the snapshot into `<db>_restore` and, only if that succeeded, swaps the databases in one transaction. The previous database stays next to it as `<db>_before_restore`. If anything fails before the swap, production is untouched.

When you're sure everything is fine, drop the old copy:

```bash
docker compose exec db dropdb -U <user> <db>_before_restore
```

### Files

```bash
docker compose run --rm backup restore files apply [snapshot]
```

Files return to their original paths. Changed and deleted files are restored. Files created after the snapshot are left as they are.

## Disaster recovery

You need two things: access to the storage and `BACKUP_PASSWORD`.

1. Deploy the project on a new server, with the same `BACKUP_PASSWORD` and `BACKUP_REPOSITORY` in `.env`.
2. Start only the database: `docker compose up -d db`.
3. Run `rclone config` as in [step 3](#3-connect-google-drive), **with the same `client_id`** as before (empty by default).
4. Run `docker compose run --rm backup restore apply`, plus `restore files apply` if you back up files.
5. Start the rest: `docker compose up -d`.

### Without Docker

You can get a plain `pg_restore` dump on any computer:

1. Download the repository folder from the Google Drive website. Drive may split a big folder into several zip files; extract them all into one folder.
2. Install restic:

   | OS | Command |
   |---|---|
   | macOS | `brew install restic` |
   | Windows | `winget install restic.restic` |
   | Linux | `apt install restic`, `dnf install restic`, or a binary from [GitHub releases](https://github.com/restic/restic/releases) |

3. Restore the dump. restic asks for the password:

   ```bash
   restic -r ./my-app-backup restore latest --path /<db>.dump --target ./restored
   ```

4. You now have `./restored/<db>.dump`. Load it with `pg_restore -d <database> ./restored/<db>.dump`.

## Pitfalls

- **The image is older than the database.** After upgrading PostgreSQL, bump the `pg-backup` tag in the same change. Otherwise `pg_dump` refuses to run and every night pings `/fail`.
- **`$` in `.env` values.** Compose substitutes variables even inside double quotes: `"abc$xyz"` becomes `"abc"`, with a warning like `The "xyz" variable is not set`. Generate hex secrets or wrap the value in single quotes. `docker compose config --quiet` should print nothing.
- **Running commands in the wrong place.** Compose validates the whole file, even when you run one service, and reads `.env` from the current folder. Run the commands on the server, in the folder whose `.env` holds the real values. If a deployment panel manages the stack:
  - work in the folder where the panel keeps it (`docker compose ls` shows it);
  - prefix commands with `sudo` if that `.env` is readable only by root;
  - change variables in the panel, not in the file, which the panel may overwrite.
- **Manual changes in the storage.** Don't move, rename or delete anything inside the repository folder. Deleting a single pack file breaks every snapshot that uses it.
- **The empty `client_id` is shared.** Scope `drive.file` gives rclone access only to files it created, never your whole Drive. But every rclone token with the empty `client_id` sees every folder rclone created in your account. Other projects' backups stay unreadable without their passwords, but a leaked token can delete them. To isolate projects, create your own client ID ([rclone guide](https://rclone.org/drive/#making-your-own-client-id)) and keep it with your password: without the same `client_id` the files are invisible.
- **Schedules are in UTC.** The container has no local time zone.

## Under the hood

| File | Role |
|---|---|
| `Dockerfile` | `postgres:<version>-alpine` plus rclone, restic and curl. The PostgreSQL version is the `PG_MAJOR` build argument |
| `entrypoint.sh` | Without arguments: writes a crontab from `BACKUP_SCHEDULE` and runs `crond`. With arguments: runs them, which is how `docker compose run --rm backup <command>` works |
| `backup.sh` | One run: dump, files, retention, `restic check`, pings |
| `restore.sh` | `restore [files] check\|apply [snapshot]` |
| `test/` | Smoke test against a live PostgreSQL with a local repository instead of Drive |
| `skills/pg-backup/SKILL.md` | Claude Code skill: adding the backup to a project, verifying, restoring, troubleshooting |

Design decisions:

- **`pg_dump`, not a copy of the data volume.** Files of a running PostgreSQL give an inconsistent copy that may not start. A dump is consistent and restores with the standard `pg_restore`.
- **A separate container, not a job inside the app.** A crashed app shouldn't stop backups.
- **restic over rclone, not plain dump files.** restic encrypts, deduplicates, handles retention and verifies integrity. rclone is only the transport.
- **Uncompressed dump (`--compress=0`).** A compressed dump is entirely new bytes every day, which defeats deduplication. restic splits the uncompressed dump into chunks that repeat from day to day and compresses them itself.
- **`--stdin-from-command`, not a pipe.** If `pg_dump` fails halfway, restic doesn't save a truncated snapshot. With `pg_dump | restic backup --stdin` it would, and the snapshot would look fine.
- **Fixed `--host`.** restic groups snapshots by host, and a container gets a new hostname every time it is recreated. Without a fixed host, retention would stop deleting old snapshots and `restore` wouldn't find `latest`. Database and file snapshots are told apart by path: `/<name>.dump` versus `BACKUP_PATHS`.
- **`restore apply` doesn't touch production until the last step.** See [Restore](#restore).
- **The cron job reads its environment from a file.** The entrypoint writes the container's variables to `/run/backup.env` with mode 600 and the job sources it, so it doesn't depend on what `crond` passes to jobs.

What's inside the repository folder:

| Path | Contents |
|---|---|
| `config` | Repository ID and format version, encrypted |
| `keys/` | The master key, encrypted with a key derived from your password. This is why `restic key passwd` changes the password without re-encrypting any data |
| `data/00…ff/` | Pack files: data chunks compressed with zstd and encrypted with AES-256. Each file is named after the hash of its contents |
| `index/` | Which chunk lives in which pack file |
| `snapshots/` | One file per snapshot: time, host, paths and a pointer to the root |
| `locks/` | Locks held during operations, so a scheduled run and a manual one don't collide |

## Development

The smoke test starts PostgreSQL and a local repository instead of Drive, then runs the schedule, `restore check` and `restore apply` for both the database and files:

```bash
sh test/smoke.sh
```

```bash
PG_MAJOR=18 sh test/smoke.sh
```

On Windows, run it from Git Bash or WSL.

CI runs shellcheck and the smoke test on PostgreSQL 15–18 for every pull request and push to `main`. Images are published only from version tags:

```bash
git tag v1.1.0 && git push origin v1.1.0
```

For each PostgreSQL version, CI builds `linux/amd64` and `linux/arm64` images and publishes two tags:

| Tag | Meaning |
|---|---|
| `16` | Latest release for PostgreSQL 16. Updates on `docker compose pull` |
| `16-1.1.0` | Pinned release. Use it if you want updates only when you change the tag. In production, add the digest too, because tags can be overwritten |

To support a new PostgreSQL major version, add it to the `smoke` and `publish` matrices in `.github/workflows/image.yml`.

## License

[Unlicense](LICENSE): public domain, use it however you like.

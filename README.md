# pg-backup

**Русский** | [English](README.en.md)

[![image](https://github.com/woB2K/pg-backup/actions/workflows/image.yml/badge.svg)](https://github.com/woB2K/pg-backup/actions/workflows/image.yml)

Ночные бэкапы PostgreSQL и, если нужно, загруженных файлов на Google Drive или в любое другое хранилище. Перед отправкой всё шифруется через [restic](https://restic.net). Подключается к проекту одним сервисом в `docker-compose.yml`:

```yaml
image: ghcr.io/wob2k/pg-backup:16
```

- **Шифрование до отправки.** Хранилище видит только случайные байты.
- **Дедупликация.** Каждую ночь уходит только то, что изменилось, а не весь дамп.
- **Ротация из коробки:** 7 дневных, 4 недельных и 6 месячных снимков.
- **Проверка.** Каждый прогон проверяет целостность репозитория, а `restore check` доказывает, что снимок реально восстанавливается, не трогая прод.
- **Безопасное восстановление.** Снимок разворачивается рядом с рабочей базой и подменяет её, только если встал без ошибок. Старая база сохраняется.
- **Файлы.** В том же прогоне бэкапятся папки с загрузками: Strapi, Directus, Django media, Rails Active Storage и так далее.
- **Мониторинг.** Пинги в [healthchecks.io](https://healthchecks.io) на старте, при успехе и при ошибке.
- **PostgreSQL 15–18**, `linux/amd64` и `linux/arm64`.

## Содержание

- [Как это работает](#как-это-работает)
- [Что нужно](#что-нужно)
- [Быстрый старт](#быстрый-старт)
- [Через Claude Code](#через-claude-code)
- [Переменные](#переменные)
- [Рецепты](#рецепты): файлы, база в другом compose, на хосте, managed Postgres, несколько баз, другие хранилища
- [Повседневное](#повседневное)
- [Восстановление](#восстановление)
- [Если сервера больше нет](#если-сервера-больше-нет)
- [Грабли](#грабли)
- [Как устроено](#как-устроено)
- [Разработка](#разработка)

## Как это работает

```
сервер (docker compose проекта)
 ├─ db ──────── PostgreSQL проекта
 └─ backup ──── спит до BACKUP_SCHEDULE, потом:
      1. pg_dump → снимает консистентный дамп базы
      2. restic  → режет его на куски, шифрует, пропускает уже залитые
      3. rclone  → отвозит новые куски на Google Drive
      4. то же для папок из BACKUP_PATHS, если они заданы
      5. удаляет старые снимки и проверяет репозиторий
                          ↓
            Google Drive / my-app-backup
```

Секретов два, и они про разное:

| | Что это | Где живёт | Если потерять |
|---|---|---|---|
| Токен Google | Разрешение rclone работать с твоим Drive (OAuth) | `rclone.conf` в volume `backup-state` | Не страшно: заново пройти `rclone config`, минут пять |
| `BACKUP_PASSWORD` | Ключ шифрования restic | `.env` проекта и **копия вне сервера** | Все бэкапы навсегда превращаются в мусор |

Токен Google выдаёт через вход в браузере. На сервере браузера обычно нет, поэтому авторизация один раз проходит на твоём компьютере (macOS, Windows или Linux), а токен вставляется на сервер.

## Что нужно

- Сервер с Docker Engine и Docker Compose v2.
- PostgreSQL 15–18, до которого контейнер может достучаться. Проще всего, когда база в том же `docker-compose.yml`, но [другие варианты](#рецепты) тоже работают.
- Google-аккаунт или любое другое хранилище, которое [поддерживают rclone или restic](#другие-хранилища).
- Один раз, при настройке: любой компьютер с браузером.

## Быстрый старт

Все команды `docker compose` ниже выполняются **на сервере**, в папке с `docker-compose.yml` проекта.

### 1. Добавить сервис

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

Что подогнать под проект:

- **Тег — мажорная версия PostgreSQL проекта.** База на `postgres:17` → `pg-backup:17`. `pg_dump` старее сервера снимать дамп откажется.
- **На проде лучше закрепить образ по дайджесту.** Контейнер держит пароль базы, ключ шифрования и токен хранилища, а с плавающим тегом `:16` любая новая версия приедет при следующем pull. С дайджестом обновление станет явной правкой в твоём репо:

  ```yaml
  image: ghcr.io/wob2k/pg-backup:16-1.0.0@sha256:<дайджест>
  ```

  Последняя версия есть в [тегах репозитория](https://github.com/woB2K/pg-backup/tags), а дайджест показывает `docker buildx imagetools inspect ghcr.io/wob2k/pg-backup:16-1.0.0`. Тег в такой записи нужен только для читаемости: Docker скачает ровно образ с этим дайджестом.
- `PGHOST` — имя сервиса базы в compose: `db`, `postgres`, `database` или как он у тебя называется.
- `POSTGRES_*` — те имена переменных, которые уже есть в проекте.
- `condition: service_healthy` работает, только если у базы есть healthcheck. Нет его — добавь или поставь `service_started`.
- `PGUSER` должен быть владельцем базы или суперпользователем: `restore apply` переименовывает базы. У официального образа `postgres` пользователь из `POSTGRES_USER` — суперпользователь, так что обычно всё уже так.

### 2. Переменные окружения

Добавь в `.env` рядом с `docker-compose.yml`:

```env
BACKUP_REPOSITORY=rclone:gdrive:my-app-backup
BACKUP_PASSWORD=
BACKUP_PING_URL=
BACKUP_SCHEDULE='0 1 * * *'
```

- `BACKUP_REPOSITORY` — папка на Drive. **У каждого проекта своя.**
- `BACKUP_PASSWORD` — длинный случайный пароль, только буквы и цифры:

  | ОС | Команда |
  |---|---|
  | macOS, Linux | `openssl rand -hex 32` |
  | Windows (PowerShell) | `$b = New-Object byte[] 32; [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($b); -join ($b \| ForEach-Object { $_.ToString('x2') })` |

  **Сразу** сохрани копию в менеджер паролей. Копируй без кавычек.
- `BACKUP_SCHEDULE` — cron-выражение в **UTC**. `0 1 * * *` — это 01:00 UTC; переведи в свою ночь.

### 3. Подключить Google Drive

Делается один раз на проект. На сервере:

```bash
docker compose run --rm backup rclone config
```

| Вопрос | Ответ |
|---|---|
| `n/s/q>` | `n` |
| `name>` | `gdrive` (должно совпадать с именем в `BACKUP_REPOSITORY`) |
| `Storage>` | `drive` |
| `client_id>` | Enter, оставить пустым. См. [Грабли](#грабли) |
| `client_secret>` | Enter |
| `scope>` | `drive.file` |
| `service_account_file>` | Enter |
| `Edit advanced config?` | `n` |
| `Use web browser to automatically authenticate rclone with remote?` | `n` |

rclone напечатает команду вида `rclone authorize "drive" "eyJ…"` и встанет на `config_token>`. **Терминал на сервере не закрывай**, а команду выполни на любом компьютере с браузером.

**Поставить rclone на этот компьютер**

| ОС | Команда |
|---|---|
| macOS | `brew install rclone` или без Homebrew: `curl -O https://downloads.rclone.org/rclone-current-osx-arm64.zip && unzip rclone-current-osx-arm64.zip` (на Intel-маках `osx-amd64`) |
| Windows | `winget install Rclone.Rclone`, потом открыть **новый** терминал |
| Linux | `sudo -v ; curl https://rclone.org/install.sh \| sudo bash` |

На macOS скачивание через `curl` обходит Gatekeeper. Если скачал zip в браузере и macOS не даёт запустить бинарник, выполни в его папке `xattr -d com.apple.quarantine ./rclone`. Любую сборку можно скачать и руками с [rclone.org/downloads](https://rclone.org/downloads/).

**Авторизоваться**

Вставь команду с сервера, длинную строку не меняй:

| ОС | Команда |
|---|---|
| macOS, Linux | `rclone authorize "drive" "eyJ…"`, для zip-сборки на маке — `./rclone-*-osx-arm64/rclone authorize "drive" "eyJ…"` |
| Windows | `rclone authorize "drive" "eyJ…"` |

Откроется браузер: войди в Google и разреши доступ. В терминале появится JSON-токен между `Paste the following into your remote machine --->` и `<---End paste`. Скопируй его целиком в `config_token>` на сервере. Это ключ от твоего Drive, больше никуда его не вставляй.

Закончить на сервере:

| Вопрос | Ответ |
|---|---|
| `Configure this as a Shared Drive (Team Drive)?` | `n` |
| `Keep this "gdrive" remote?` | `y` |
| `e/n/d/r/c/s/q>` | `q` |

### 4. Создать репозиторий

```bash
docker compose run --rm backup restic init
```

На Google Drive это занимает несколько минут: restic создаёт около 260 папок и до конца ничего не пишет. Не прерывай, закончит строкой `created restic repository`.

### 5. Первый бэкап и проверка восстановления

```bash
docker compose run --rm backup backup
```

```bash
docker compose run --rm backup restore check
```

`restore check` разворачивает снимок во временную базу, печатает число строк по таблицам и удаляет её. Сравни цифры с тем, что видишь в приложении.

### 6. Включить расписание

```bash
docker compose up -d
```

Конфиг rclone лежит в volume, поэтому уже запущенный контейнер подхватит его без перезапуска.

### 7. Мониторинг (очень советую)

Без мониторинга о сломавшемся бэкапе узнаешь в тот день, когда он понадобится.

1. На [healthchecks.io](https://healthchecks.io) (есть бесплатный тариф, можно и поднять у себя) заведи проверку типа **Cron** с тем же выражением, что в `BACKUP_SCHEDULE`, таймзона UTC, grace 1 час.
2. Её ping URL положи в `BACKUP_PING_URL` и снова выполни `docker compose up -d`.

Контейнер пингует `/start` перед прогоном, сам URL при успехе и `/fail` при ошибке. healthchecks.io пришлёт письмо, если прогон упал или вообще не случился.

## Через Claude Code

В репозитории есть скилл для [Claude Code](https://claude.com/claude-code): [`skills/pg-backup/SKILL.md`](skills/pg-backup/SKILL.md). С ним Claude сам изучит проект, найдёт базу, её версию и папки с загрузками, добавит сервис в compose и переменные в шаблон `.env`, проверит конфиг и выдаст тебе чеклист того, что осталось сделать на сервере. Входить в Google и придумывать пароль всё равно придётся тебе.

**Поставить для всех своих проектов:**

| ОС | Команда |
|---|---|
| macOS, Linux | `mkdir -p ~/.claude/skills/pg-backup && curl -fsSL https://raw.githubusercontent.com/woB2K/pg-backup/main/skills/pg-backup/SKILL.md -o ~/.claude/skills/pg-backup/SKILL.md` |
| Windows (PowerShell) | `New-Item -ItemType Directory -Force "$HOME\.claude\skills\pg-backup" \| Out-Null; Invoke-WebRequest https://raw.githubusercontent.com/woB2K/pg-backup/main/skills/pg-backup/SKILL.md -OutFile "$HOME\.claude\skills\pg-backup\SKILL.md"` |

Обновить скилл — та же команда.

**Для одного проекта и всей команды:** положи файл в проект как `.claude/skills/pg-backup/SKILL.md` и закоммить.

**Без установки:** просто скажи Claude Code в проекте: «Подключи бэкапы базы по гайду https://raw.githubusercontent.com/woB2K/pg-backup/main/skills/pg-backup/SKILL.md».

Со скиллом достаточно написать «подключи бэкапы базы на Google Drive». Он же поможет проверить бэкап, разобраться с ошибкой или восстановиться.

## Переменные

| Переменная | По умолчанию | Что это |
|---|---|---|
| `PGHOST` | | **Обязательна.** Хост базы |
| `PGDATABASE` | | **Обязательна.** Имя базы |
| `PGUSER`, `PGPASSWORD` | | Логин и пароль базы |
| `PGPORT`, `PGSSLMODE` и другие [переменные libpq](https://www.postgresql.org/docs/current/libpq-envars.html) | | Передаются в `pg_dump`, `pg_restore` и `psql` как есть |
| `RESTIC_REPOSITORY` | | **Обязательна.** Куда класть снимки, например `rclone:gdrive:my-app-backup` |
| `RESTIC_PASSWORD` | | **Обязательна.** Пароль шифрования |
| `BACKUP_SCHEDULE` | `0 1 * * *` | cron-выражение, **UTC** |
| `BACKUP_PING_URL` | | Ping URL проверки на healthchecks.io |
| `BACKUP_PATHS` | | Папки внутри контейнера, которые бэкапить вместе с базой, через пробел |
| `BACKUP_NAME` | `$PGDATABASE` | Хост снимков в restic и имя файла дампа `<name>.dump` |
| `BACKUP_KEEP_DAILY` | `7` | Сколько хранить дневных снимков |
| `BACKUP_KEEP_WEEKLY` | `4` | Сколько хранить недельных |
| `BACKUP_KEEP_MONTHLY` | `6` | Сколько хранить месячных |

Все остальные переменные тоже доходят до restic и rclone. Например, `AWS_ACCESS_KEY_ID` для репозитория в S3.

## Рецепты

### Приложение и база в одном compose

Это вариант из [быстрого старта](#быстрый-старт). Подходит для любого стека, который хранит данные в PostgreSQL: Node.js с Prisma или TypeORM, NestJS, Next.js, Nuxt, Strapi, Django, Rails, Laravel, Go, .NET. Язык приложения не важен, важна только база.

### Загруженные файлы

Если приложение хранит загрузки на диске, одного бэкапа базы мало: после восстановления записи будут ссылаться на файлы, которых нет. Смонтируй ту же папку в `backup` и укажи её в `BACKUP_PATHS`.

С именованным volume:

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

С bind mount монтируй ту же папку хоста: `./public/uploads:/data/uploads`.

Где обычно лежат загрузки внутри контейнера приложения (сверься со своим проектом):

| Проект | Папка |
|---|---|
| Strapi | `public/uploads` в папке приложения, например `/opt/app/public/uploads` |
| Directus | `/directus/uploads` |
| Django | куда указывает `MEDIA_ROOT` |
| Rails, Active Storage с Disk service | `storage/`, например `/rails/storage` |
| Laravel | `storage/app` |

Что важно:

- Несколько папок — через пробел: `BACKUP_PATHS: /data/uploads /data/avatars`. Пробелов в путях быть не должно.
- Каждый прогон делает два снимка: базы и файлов. Ротация у них раздельная.
- Не монтируй с `:ro`, иначе `restore files apply` будет некуда писать.
- Если папки нет (забыл смонтировать), прогон упадёт и пингнёт `/fail`. Это нарочно: молча бэкапить пустоту хуже.
- Если поменять `BACKUP_PATHS`, `latest` для файлов считается только по снимкам с новым набором папок. Старые снимки остаются доступны по ID.

### База в другом compose-проекте

Подключи `backup` к сети проекта с базой. Имя сети покажет `docker network ls`, обычно это `<проект>_default`.

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

`depends_on` убери: compose не умеет ждать сервис из другого проекта.

### База установлена прямо на хосте

```yaml
services:
  backup:
    environment:
      PGHOST: host.docker.internal
    extra_hosts:
      - host.docker.internal:host-gateway
```

`depends_on` убери. На Linux PostgreSQL ещё должен принимать подключения из сети Docker: `listen_addresses` в `postgresql.conf` и подсеть Docker в `pg_hba.conf`. С Docker Desktop на macOS и Windows подключение обычно приходит с самого хоста и работает без этих правок.

### Managed PostgreSQL

Supabase, Neon, Amazon RDS, DigitalOcean и похожие сервисы:

```yaml
services:
  backup:
    environment:
      PGHOST: db.example.com
      PGPORT: 5432
      PGSSLMODE: require
```

`depends_on` убери. Тег выбирай по мажорной версии сервера.

Бэкап и `restore check` работают, если пользователю можно создавать базы. `restore apply` переименовывает базы, а managed-сервисы это часто запрещают. Тогда восстанавливай руками: [достань дамп](#без-docker) и выполни `pg_restore` в нужную базу. Свои бэкапы у провайдера, скорее всего, тоже есть. Этот даёт независимую копию, которую контролируешь ты.

### Несколько баз

По сервису на базу. Репозиторий, пароль и авторизация Google у них могут быть общими: снимки разводит `BACKUP_NAME`, который по умолчанию равен имени базы.

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

`rclone config` и `restic init` — один раз, через любой из сервисов. **Разнеси расписания.** Очистка блокирует репозиторий, и из двух одновременных прогонов один упадёт с `repository is already locked`.

### Другие хранилища

Google Drive — только пример. Так же работает всё, что умеет rclone: Dropbox, OneDrive, Backblaze B2, любое S3-совместимое хранилище, SFTP, WebDAV, NAS. В `rclone config` выбери другой `Storage>` и укажи этот remote в репозитории:

```env
BACKUP_REPOSITORY=rclone:dropbox:my-app-backup
```

С S3 и B2 restic умеет работать и напрямую, без rclone. Ключи передаются через переменные окружения:

```yaml
environment:
  RESTIC_REPOSITORY: s3:https://s3.eu-central-1.amazonaws.com/my-bucket/my-app
  AWS_ACCESS_KEY_ID: ${AWS_ACCESS_KEY_ID}
  AWS_SECRET_ACCESS_KEY: ${AWS_SECRET_ACCESS_KEY}
```

## Повседневное

| Что | Команда |
|---|---|
| Список снимков | `docker compose run --rm backup restic snapshots` |
| Бэкап прямо сейчас | `docker compose run --rm backup backup` |
| Проверить, что база восстанавливается | `docker compose run --rm backup restore check [snapshot]` |
| Проверить, что файлы восстанавливаются | `docker compose run --rm backup restore files check [snapshot]` |
| Логи ночных прогонов | `docker compose logs backup` |
| Обновить образ | Закреплён по дайджесту — поменяй тег и дайджест в compose. Потом `docker compose pull backup && docker compose up -d backup` |

Без `snapshot` берётся последний снимок. ID показывает `restic snapshots`.

`restore check` и `restore files check` прод не трогают: восстанавливают во временную базу или папку, печатают, что нашли, и убирают за собой. Запускай раз в месяц. Бэкап, который ни разу не восстанавливали, бэкапом не считается.

## Восстановление

### База

Останови всё, что подключено к базе: PostgreSQL не даст переименовать базу с открытыми подключениями.

```bash
docker compose stop app
```

```bash
docker compose run --rm backup restore apply [snapshot]
```

```bash
docker compose up -d
```

`restore apply` попросит ввести имя базы для подтверждения, развернёт снимок в `<db>_restore` и, только если всё встало, одной транзакцией поменяет базы местами. Прежняя база останется рядом как `<db>_before_restore`. Если что-то упадёт до обмена, прод не тронут.

Когда убедишься, что всё на месте, удали старую копию:

```bash
docker compose exec db dropdb -U <user> <db>_before_restore
```

### Файлы

```bash
docker compose run --rm backup restore files apply [snapshot]
```

Файлы возвращаются по исходным путям. Изменённые и удалённые восстанавливаются, а появившиеся после снимка остаются как есть.

## Если сервера больше нет

Нужны две вещи: доступ к хранилищу и `BACKUP_PASSWORD`.

1. Разверни проект на новом сервере, в `.env` — те же `BACKUP_PASSWORD` и `BACKUP_REPOSITORY`.
2. Подними только базу: `docker compose up -d db`.
3. Пройди `rclone config`, как в [шаге 3](#3-подключить-google-drive), **с тем же `client_id`**, что и раньше (по умолчанию пустым).
4. Выполни `docker compose run --rm backup restore apply`, а если бэкапишь файлы — ещё и `restore files apply`.
5. Подними остальное: `docker compose up -d`.

### Без Docker

Обычный дамп для `pg_restore` можно достать на любом компьютере:

1. Скачай папку репозитория с сайта Google Drive. Большую папку Drive может разбить на несколько zip-архивов — распакуй их все в одну папку.
2. Поставь restic:

   | ОС | Команда |
   |---|---|
   | macOS | `brew install restic` |
   | Windows | `winget install restic.restic` |
   | Linux | `apt install restic`, `dnf install restic` или бинарник с [GitHub releases](https://github.com/restic/restic/releases) |

3. Восстанови дамп. restic спросит пароль:

   ```bash
   restic -r ./my-app-backup restore latest --path /<db>.dump --target ./restored
   ```

4. Получишь `./restored/<db>.dump`. Загрузи его: `pg_restore -d <база> ./restored/<db>.dump`.

## Грабли

- **Образ старше базы.** Обновил PostgreSQL — в той же правке подними тег `pg-backup`. Иначе `pg_dump` откажется работать, и каждую ночь будет приходить `/fail`.
- **`$` в значениях `.env`.** Compose подставляет переменные даже внутри двойных кавычек: из `"abc$xyz"` получится `"abc"` и варнинг `The "xyz" variable is not set`. Генерируй секреты в hex или бери значение в одинарные кавычки. `docker compose config --quiet` должен молчать.
- **Команды не там.** Compose проверяет весь файл, даже когда запускаешь один сервис, и читает `.env` из текущей папки. Запускай команды на сервере, в той папке, где `.env` с боевыми значениями. Если стеком управляет панель деплоя, то:
  - работай в папке, где панель держит стек (её покажет `docker compose ls`);
  - добавляй `sudo`, если этот `.env` читается только root;
  - меняй переменные в самой панели, а не в файле: панель может его перезаписать.
- **Ручные правки в хранилище.** Внутри папки репозитория ничего не двигай, не переименовывай и не удаляй. Удалишь один pack-файл — сломаются все снимки, которые на него ссылаются.
- **Пустой `client_id` общий.** Scope `drive.file` даёт rclone доступ только к созданным им файлам, а не ко всему Drive. Но все токены rclone с пустым `client_id` видят все папки, которые rclone создал в твоём аккаунте. Бэкапы других проектов без их паролей не прочитать, а вот удалить утёкшим токеном можно. Чтобы изолировать проекты, заведи свой client ID ([гайд rclone](https://rclone.org/drive/#making-your-own-client-id)) и храни его вместе с паролем: без того же `client_id` файлы будут не видны.
- **Расписание в UTC.** Локальной таймзоны в контейнере нет.

## Как устроено

| Файл | Что делает |
|---|---|
| `Dockerfile` | `postgres:<версия>-alpine` + rclone, restic и curl. Версия Postgres — build-arg `PG_MAJOR` |
| `entrypoint.sh` | Без аргументов — пишет crontab из `BACKUP_SCHEDULE` и запускает `crond`. С аргументами — выполняет их, на этом работает `docker compose run --rm backup <команда>` |
| `backup.sh` | Один прогон: дамп, файлы, ротация, `restic check`, пинги |
| `restore.sh` | `restore [files] check\|apply [snapshot]` |
| `test/` | Smoke-тест на живом PostgreSQL с локальным репозиторием вместо Drive |
| `skills/pg-backup/SKILL.md` | Скилл для Claude Code: подключение к проекту, проверка, восстановление, разбор ошибок |

Почему так:

- **`pg_dump`, а не копия volume с данными.** Файлы работающего PostgreSQL дают неконсистентный слепок, который может не подняться. Дамп консистентен и разворачивается штатным `pg_restore`.
- **Отдельный контейнер, а не задача в приложении.** Упавшее приложение не должно останавливать бэкап.
- **restic поверх rclone, а не просто файлы дампов.** restic шифрует, дедуплицирует, держит ротацию и проверяет целостность. rclone — только транспорт.
- **Дамп без сжатия (`--compress=0`).** Сжатый дамп каждый день — целиком новые байты, и дедупликация не работает. Несжатый restic режет на куски, которые повторяются изо дня в день, и сжимает сам.
- **`--stdin-from-command`, а не pipe.** Если `pg_dump` упадёт посреди потока, restic не сохранит обрезанный снимок. С `pg_dump | restic backup --stdin` снимок бы сохранился и выглядел нормальным.
- **Фиксированный `--host`.** restic группирует снимки по хосту, а hostname контейнера меняется при каждом пересоздании. Без фиксированного хоста ротация перестанет удалять старые снимки, а `restore` не найдёт `latest`. Снимки базы и файлов различаются по пути: `/<name>.dump` против `BACKUP_PATHS`.
- **`restore apply` не трогает прод до последнего шага** — см. [Восстановление](#восстановление).
- **Окружение cron-задачи — из файла.** Entrypoint пишет переменные контейнера в `/run/backup.env` с правами 600, а задача подключает его перед запуском. Так она не зависит от того, что `crond` передаёт задачам.

Что лежит в папке репозитория:

| Путь | Что внутри |
|---|---|
| `config` | ID репозитория и версия формата, зашифрованы |
| `keys/` | Мастер-ключ, зашифрованный ключом из пароля. Поэтому `restic key passwd` меняет пароль, не перешифровывая данные |
| `data/00…ff/` | Pack-файлы: куски данных, сжатые zstd и зашифрованные AES-256. Имя файла — хеш содержимого |
| `index/` | Какой кусок в каком pack-файле лежит |
| `snapshots/` | По файлу на снимок: время, хост, пути, ссылка на корень |
| `locks/` | Блокировки на время операции, чтобы ночной прогон и ручной запуск не подрались |

## Разработка

Smoke-тест поднимает PostgreSQL и локальный репозиторий вместо Drive и прогоняет расписание, `restore check` и `restore apply` для базы и для файлов:

```bash
sh test/smoke.sh
```

```bash
PG_MAJOR=18 sh test/smoke.sh
```

На Windows запускай из Git Bash или WSL.

CI гоняет shellcheck и smoke на PostgreSQL 15–18 на каждый PR и пуш в `main`. Образы публикуются только по тегу версии:

```bash
git tag v1.1.0 && git push origin v1.1.0
```

Для каждой версии PostgreSQL CI собирает образы под `linux/amd64` и `linux/arm64` и публикует два тега:

| Тег | Что значит |
|---|---|
| `16` | Последний релиз для PostgreSQL 16. Обновляется при `docker compose pull` |
| `16-1.1.0` | Зафиксированный релиз. Бери его, если хочешь обновляться только сменой тега. Для прода — вместе с дайджестом, потому что тег можно перезаписать |

Новая мажорная версия PostgreSQL — добавить её в матрицы `smoke` и `publish` в `.github/workflows/image.yml`.

## Лицензия

[Unlicense](LICENSE): общественное достояние, используй как хочешь.

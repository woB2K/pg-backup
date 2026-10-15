# pg-backup

Ночной бэкап Postgres и, при желании, папок с файлами в зашифрованный репозиторий [restic](https://restic.net) на Google Drive. Подключается к любому проекту на docker compose одним сервисом:

```yaml
image: ghcr.io/wob2k/pg-backup:16
```

## Как это работает

```
сервер (docker compose проекта)
 ├─ db ──────── база проекта
 └─ backup ──── спит до BACKUP_SCHEDULE, потом:
      1. pg_dump → снимает базу в один файл
      2. restic  → режет на куски, шифрует, не заливает повторы
      3. rclone  → отвозит куски на Google Drive
      4. то же для папок из BACKUP_PATHS, если они заданы
      5. удаляет старые снимки и проверяет целостность репозитория
                          ↓
            Google Drive / <проект>-backup
```

Ключей два, и они про разное:

| | Что это | Где живёт | Если потерять |
|---|---|---|---|
| Токен Google | Пропуск rclone на Drive (OAuth) | `rclone.conf` в volume `backup-state` | Не страшно: заново пройти `rclone config`, минут пять |
| `BACKUP_PASSWORD` | Ключ шифрования restic | env проекта и **копия вне сервера** | Все бэкапы навсегда превращаются в мусор |

Токен выдаётся через браузер. На сервере браузера нет, поэтому авторизация проходит на маке, а токен вставляется на сервер руками — как OAuth callback через копипаст.

## Подключить к проекту

### 1. Сервис в `docker-compose.yml`

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

Что сверить с проектом:

- **Тег — мажорная версия Postgres проекта.** База на `postgres:17-alpine` → `pg-backup:17`. Есть 15, 16, 17 и 18.
- `PGHOST` — имя сервиса базы в этом compose: `db`, `postgres` или как он там назван.
- `POSTGRES_*` — те имена переменных, что уже есть в проекте.
- `service_healthy` работает, только если у базы есть healthcheck. Нет его — добавь или поставь `service_started`.
- `PGUSER` должен быть владельцем базы или суперпользователем: `restore apply` переименовывает базы. У официального образа postgres пользователь из `POSTGRES_USER` — суперпользователь, так что обычно всё уже так.

### 2. Переменные в `.env`

```env
BACKUP_REPOSITORY=rclone:gdrive:<проект>-backup
BACKUP_PASSWORD=
BACKUP_PING_URL=
BACKUP_SCHEDULE='0 1 * * *'
```

- `BACKUP_REPOSITORY` — **у каждого проекта своя папка** на Drive.
- `BACKUP_PASSWORD` — `openssl rand -hex 32`. Сразу сохрани копию вне сервера, в менеджер паролей. Копируй **без кавычек**: compose их снимает, и restic получает пароль без них.

### 3. Первая настройка на сервере

Команды запускаются на сервере из папки с `docker-compose.yml` проекта. Под Komodo — из папки стека и через `sudo`, см. [Komodo](#komodo).

**Подключить Google Drive.** Один раз на проект:

```bash
docker compose run --rm backup rclone config
```

| Вопрос | Ответ |
|---|---|
| `n/s/q>` | `n` |
| `name>` | `gdrive` |
| `Storage>` | `drive` |
| `client_id>` | Enter — **оставить пустым**, см. [Если сервера больше нет](#если-сервера-больше-нет) |
| `client_secret>` | Enter |
| `scope>` | `drive.file` |
| `service_account_file>` | Enter |
| `Edit advanced config?` | `n` |
| `Use web browser to automatically authenticate…?` | `n` |

rclone напечатает `rclone authorize "drive" "eyJ…"` и встанет на `config_token>`. Окно на сервере не закрывай, а на маке скачай rclone бинарником (через brew на Sonoma он собирается из исходников) и выполни эту команду:

```bash
cd ~/Downloads && curl -O https://downloads.rclone.org/rclone-current-osx-arm64.zip && unzip -o rclone-current-osx-arm64.zip
```

```bash
./rclone-*-osx-arm64/rclone authorize "drive" "eyJ…"
```

Откроется браузер — войди в Google и разреши доступ. В терминале мака появится JSON между `Paste the following into your remote machine --->` и `<---End paste`: скопируй его целиком в `config_token>` на сервере. Дальше:

| Вопрос | Ответ |
|---|---|
| `Configure this as a Shared Drive?` | `n` |
| `Keep this "gdrive" remote?` | `y` |
| `e/n/d/r/c/s/q>` | `q` |

**Создать репозиторий:**

```bash
docker compose run --rm backup restic init
```

На Drive это занимает несколько минут: restic создаёт около 260 папок и до конца ничего не пишет. Не прерывай — закончит строкой `created restic repository`.

**Первый бэкап и проверка, что он восстанавливается:**

```bash
docker compose run --rm backup backup
```

```bash
docker compose run --rm backup restore check
```

Сравни число строк в таблицах с тем, что видишь в приложении.

**Включить расписание:** `docker compose up -d`, под Komodo — Redeploy. Конфиг rclone лежит в volume, поэтому уже запущенный контейнер подхватит его без перезапуска.

**healthchecks.io.** Заведи проверку типа Cron с тем же выражением, что в `BACKUP_SCHEDULE`, таймзона UTC, grace 1 час. Её URL положи в `BACKUP_PING_URL` и передеплой. Сервис пингует `/start` перед прогоном, сам URL после успеха и `/fail` при ошибке. Без этого о сломавшемся бэкапе узнаешь в момент, когда он понадобится.

## Переменные

| Переменная | По умолчанию | Что |
|---|---|---|
| `PGHOST`, `PGUSER`, `PGPASSWORD`, `PGDATABASE` | — | Подключение к базе, стандартные переменные libpq. `PGHOST` и `PGDATABASE` обязательны |
| `RESTIC_REPOSITORY` | — | Обязательна. Куда класть снимки: `rclone:gdrive:<папка>` |
| `RESTIC_PASSWORD` | — | Обязательна. Пароль шифрования |
| `BACKUP_SCHEDULE` | `0 1 * * *` | cron в **UTC**: `0 1 * * *` — это 04:00 МСК и 08:00 по UTC+7. Ночь по UTC+7 — `0 20 * * *` |
| `BACKUP_PING_URL` | — | URL проверки на healthchecks.io |
| `BACKUP_PATHS` | — | Папки внутри контейнера, которые бэкапить вместе с базой, через пробел |
| `BACKUP_NAME` | `$PGDATABASE` | Хост снимков в restic и имя файла дампа `<name>.dump` |
| `BACKUP_KEEP_DAILY`, `BACKUP_KEEP_WEEKLY`, `BACKUP_KEEP_MONTHLY` | 7, 4, 6 | Сколько снимков хранить |

## Файлы

Например, uploads у Strapi: без них после восстановления базы в медиатеке будут битые картинки. Смонтируй тот же volume в `backup` и перечисли путь в `BACKUP_PATHS`:

```yaml
services:
  strapi:
    volumes:
      - uploads:/opt/app/public/uploads

  backup:
    image: ghcr.io/wob2k/pg-backup:16
    environment:
      BACKUP_PATHS: /data/uploads
    volumes:
      - backup-state:/var/lib/backup
      - uploads:/data/uploads

volumes:
  uploads:
  backup-state:
```

Если uploads — bind mount вроде `./public/uploads:/opt/app/public/uploads`, монтируй тот же путь: `./public/uploads:/data/uploads`.

- Каждый прогон делает два снимка — базы и файлов, ротация у них раздельная.
- Пути без пробелов. Если поменять `BACKUP_PATHS`, `latest` для файлов отсчитывается от нового набора путей, а старые снимки остаются доступны по ID.
- Монтируй без `:ro`, иначе `restore files apply` некуда будет писать.
- Забыл смонтировать папку — прогон упадёт и пингнёт `/fail`. Это нарочно: молча бэкапить пустоту хуже.

## Komodo

Всё, обо что споткнулись при настройке MyDay:

- Файлы стека лежат в `/etc/komodo/stacks/<стек>`, а не в твоём клоне репозитория. Все команды — оттуда. Проверить, где стек: `docker compose ls`, колонка CONFIG FILES.
- `.env` там принадлежит root, поэтому команды через `sudo`: `sudo docker compose run --rm backup …`. Права на файл не меняй — Komodo всё равно перезапишет его при деплое.
- Переменные правь в Environment стека в UI и жми Redeploy. Правки `.env` на диске Komodo затрёт.
- Если имя проекта в `docker compose ls` совпадает с проектом, но папка другая — не запускай команды из своего клона. Compose поднимет зависимости по своему файлу и может пересоздать базу с чужими настройками.

## Повседневное

| Что | Команда |
|---|---|
| Список снимков | `docker compose run --rm backup restic snapshots` |
| Бэкап вне расписания | `docker compose run --rm backup backup` |
| Проверить снимок базы | `docker compose run --rm backup restore check [snapshot]` |
| Проверить снимок файлов | `docker compose run --rm backup restore files check [snapshot]` |
| Логи ночных прогонов | `docker compose logs backup` |
| Обновить образ | `docker compose pull backup && docker compose up -d backup`, под Komodo — Pull и Redeploy |

`restore check` разворачивает снимок во временную базу `<db>_check`, печатает число строк по таблицам и удаляет её. `restore files check` восстанавливает файлы во временную папку и печатает их количество и размер. Прод не трогает ни одна из них. Запускай раз в месяц: бэкап, который ни разу не восстанавливали, бэкапом не считается.

Без `snapshot` берётся последний снимок. ID есть в `restic snapshots`.

## Восстановление

**База:**

```bash
docker compose stop app
```

```bash
docker compose run --rm backup restore apply [snapshot]
```

```bash
docker compose up -d
```

`restore apply` спросит имя базы для подтверждения, развернёт снимок в `<db>_restore` и, только если всё встало без ошибок, одной транзакцией поменяет базы местами. Прежняя база остаётся рядом как `<db>_before_restore`. Если что-то упадёт до обмена, прод не тронут. Приложение останавливается заранее, потому что переименовать базу, к которой есть подключения, Postgres не даст.

Когда убедишься, что всё на месте:

```bash
docker compose exec db dropdb -U <user> <db>_before_restore
```

**Файлы:**

```bash
docker compose run --rm backup restore files apply [snapshot]
```

Файлы возвращаются по исходным путям: изменённые и удалённые восстанавливаются, а появившиеся после снимка остаются на месте.

## Если сервера больше нет

Нужны только Google-аккаунт и `BACKUP_PASSWORD`.

1. Развернуть проект, в `.env` — те же `BACKUP_PASSWORD` и `BACKUP_REPOSITORY`.
2. `docker compose up -d db`.
3. `rclone config`, как при первой настройке, **с пустым `client_id`**. Со scope `drive.file` Google показывает приложению только файлы, созданные тем же OAuth-клиентом: с другим `client_id` репозиторий будет не виден.
4. `restore apply`, если были файлы — `restore files apply`, затем `docker compose up -d`.

Совсем без сервера: скачай папку репозитория из веб-интерфейса Drive, возьми бинарник restic с [GitHub releases](https://github.com/restic/restic/releases) и достань дамп:

```bash
restic -r ./<проект>-backup dump --path /<db>.dump latest /<db>.dump > <db>.dump
```

Дальше обычный `pg_restore`.

## Грабли

- **Версия образа не ниже версии базы.** `pg_dump` старее сервера откажется снимать дамп, и каждую ночь будет приходить `/fail`. Поднимаешь Postgres в проекте — в том же коммите поднимай тег `pg-backup`.
- **`$` в значениях `.env`.** Compose подставляет переменные даже внутри `"..."`: из `"abc$n"` получится `"abc"` и варнинг `The "n" variable is not set`. Генерируй секреты через `openssl rand -hex 32` или бери значение в одинарные кавычки. Проверка — `docker compose config --quiet` должен молчать.
- **Compose проверяет переменные всего файла,** даже когда запускаешь один сервис. Поэтому команды работают только там, где лежит боевой `.env`, — на сервере, а не на маке из dev-папки.
- **В папке на Drive руками ничего не трогать.** Удалишь один pack-файл — сломаются все снимки, которые на него ссылаются.
- **Токены rclone не изолируют проекты друг от друга.** `drive.file` отрезает остальной Drive, но все токены с пустым `client_id` видят все папки, созданные rclone. Прочитать чужой бэкап без его пароля нельзя, а удалить — можно.

## Как устроено

| Файл | Что делает |
|---|---|
| `Dockerfile` | `postgres:<версия>-alpine` + rclone, restic и curl. Версия Postgres — build-arg `PG_MAJOR` |
| `entrypoint.sh` | Без аргументов — пишет crontab из `BACKUP_SCHEDULE` и запускает `crond`. С аргументами — выполняет их, на этом работают `docker compose run --rm backup <команда>` |
| `backup.sh` | Один прогон: дамп, файлы, ротация, `restic check`, пинги |
| `restore.sh` | `restore [files] check\|apply [snapshot]` |
| `test/` | Smoke-тест на живом Postgres с локальным репозиторием вместо Drive |

Почему так:

- **`pg_dump`, а не копия volume.** Файлы работающего Postgres дают неконсистентный слепок, который может не подняться. Дамп консистентен и разворачивается штатным `pg_restore`.
- **Отдельный контейнер, а не задача в приложении.** Упавшее приложение не должно останавливать бэкап.
- **restic поверх rclone, а не просто файлы на Drive.** restic шифрует, дедуплицирует, держит ротацию и проверяет целостность. rclone — только транспорт.
- **Дамп без сжатия (`--compress=0`).** Сжатый дамп каждый день — целиком новые байты, и дедупликация не работает. Несжатый restic режет на куски, которые совпадают между днями, и сжимает сам.
- **`--stdin-from-command`, а не pipe.** Если `pg_dump` упадёт посреди потока, restic не сохранит обрезанный снимок. С `pg_dump | restic backup --stdin` снимок бы сохранился и выглядел нормальным.
- **Фиксированный `--host`.** restic группирует снимки по хосту, а hostname контейнера меняется при каждом пересоздании. Без фиксированного хоста ротация перестанет удалять старые снимки, а `restore` не найдёт `latest`. Снимки базы и файлов различаются по пути: `/<name>.dump` против `BACKUP_PATHS`.
- **`restore apply` не трогает прод до последнего шага** — см. [Восстановление](#восстановление).
- **Окружение cron — из файла.** Чтобы не зависеть от того, что `crond` передаёт задачам, entrypoint пишет переменные контейнера в `/run/backup.env` с правами 600, и задача подключает его перед запуском.

Что лежит в папке на Drive:

| Что | Внутри |
|---|---|
| `config` | ID репозитория и версия формата, зашифрованы |
| `keys/` | Мастер-ключ, зашифрованный ключом из пароля. Поэтому смена пароля (`restic key passwd`) не перешифровывает данные |
| `data/00…ff/` | Pack-файлы: куски данных, сжатые zstd и зашифрованные AES-256. Имя файла — хеш содержимого |
| `index/` | Какой кусок в каком pack-файле лежит |
| `snapshots/` | По файлу на снимок: время, хост, пути, ссылка на корень |
| `locks/` | Блокировки на время операции, чтобы ночной прогон и ручной запуск не подрались |

## Разработка и выпуск

Локальная проверка — поднимает Postgres и локальный репозиторий вместо Drive, прогоняет расписание и `restore check|apply` для базы и файлов:

```bash
sh test/smoke.sh
```

```bash
PG_MAJOR=18 sh test/smoke.sh
```

CI (`.github/workflows/image.yml`) на каждый PR и пуш в `main` гоняет shellcheck и smoke на Postgres 15–18. Образы публикуются только по тегу версии:

```bash
git tag v1.1.0 && git push origin v1.1.0
```

CI соберёт образы под amd64 и arm64 и опубликует для каждой версии Postgres два тега: плавающий `:16` и фиксированный `:16-1.1.0`. Проекты на `:16` получат новую версию при следующем pull. Нужна стабильность — фиксируй `:16-1.1.0`.

- Новая мажорная версия Postgres — добавить её в матрицы `smoke` и `publish`.
- Репозиторий приватный, образ публичный: секретов в нём нет, а серверу не нужен логин в GHCR. После самой первой публикации видимость пакета переключается руками: Package settings → Change visibility → Public.

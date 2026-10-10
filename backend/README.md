# Backend Musica

Zig **0.16.0**, HTTP-сервер `httpz`, PostgreSQL через `pg.zig`, MinIO через
S3 PutObject/GetObject/DeleteObject с подписью AWS Signature V4, HLS через FFmpeg. Обе Zig-зависимости закреплены
на конкретных коммитах для Zig 0.16.

## Импорт Spotify

Фича `spotify_int` принимает нормализованные метаданные из Spotify account data.
Frontend читает `Playlists.json` (`playlists[].items[].track`) и `YourLibrary.json`
(`tracks[]`), показывает предварительный итог и отправляет один запрос.

```http
POST /api/spotify/import
Content-Type: application/json

{
  "playlists": [{
    "title": "Мой Spotify mix",
    "description": "",
    "tracks": [{ "title": "Get Lucky", "artist": "Daft Punk", "spotify_uri": "spotify:track:2Foc5Q5nqNiosCNqttzHof" }]
  }],
  "library": [{ "title": "Get Lucky", "artist": "Daft Punk", "spotify_uri": "spotify:track:2Foc5Q5nqNiosCNqttzHof" }]
}
```

Обе коллекции необязательны, но нужен хотя бы один трек. Нужна обычная сессия
пользователя. Ответ `202`: `{ "id": "UUID импорта", "tracks": 1, "playlists": ["UUID"] }`.
До 100 плейлистов, 5000 записей треков суммарно и 4 МБ нормализованного JSON.
Создание плейлистов, треков, привязок и jobs выполняется одной транзакцией.
Плейлисты приватные; каждый трек также привязан к пользовательскому Uploads.
Совпадения по Spotify URI объединяются в пределах запроса, без URI — по названию
и исполнителю без учёта ASCII-регистра. Следующий импорт создаёт новые записи.

`GET /api/spotify/imports/:id` возвращает владельцу `{id, tracks}` с полями
`id`, `title`, `artist`, `download` (queued/processing/completed/failed),
`status` (pending/ready/streamed) и `preparation` (состояние HLS job или null).
`POST /api/spotify/imports/:id/retry` повторно ставит неудачные скачивания в очередь.
Для неудачного HLS используется обычный `POST /api/tracks/:id/hls`; кнопка
повтора во frontend вызывает его автоматически. Технические причины остаются в логах.

Каждый уникальный трек получает отдельную `public.jobs` с kind `spotify_download`,
dedupe_key = track UUID; import_id, user_id и метаданные находятся в payload.
Один worker на ноде скачивает последовательно, аренда — 120 секунд с продлением
каждые 15 секунд. Ошибки скачивания повторяются до трёх попыток с задержкой 30 секунд;
отсутствующий yt-dlp и неверные данные сразу переводят задание в failed.
После остановки ноды просроченное задание подхватывается другой нодой.
Для публикации оригинала повторно проверяются attempt_id и действующая аренда.
Во время активного скачивания удаление трека и ручная загрузка получают `409`.
Удаление неактивного трека также удаляет его download job.

yt-dlp запускается напрямую, без shell, с поиском `ytsearch1:<исполнитель> <название>`
и фиксированным временным именем `source.%(ext)s`. Используются `-x --audio-format mp3
--audio-quality 256K --embed-metadata --embed-thumbnail --convert-thumbnails jpg
--write-thumbnail`, bestaudio/best и настроенный FFmpeg. Обложка встраивается в MP3,
если она есть у найденного видео; отдельная картинка трека в API пока не добавляется.
Качество источника и точное совпадение версии композиции поиском не гарантируются.
Временный каталог каждой попытки удаляется после выполнения. MP3 публикуется через
`tracks_service.uploadForJob`: те же S3-резервация/очистка и переход pending → ready,
что при ручной загрузке, затем ставится prepare_hls и трек переходит в streamed.
Повтор после уже успешной публикации продолжает HLS, без повторного скачивания.
Миграции для этой фичи не нужны: используется существующая общая таблица jobs.

Docker-образ включает FFmpeg, Node.js 22 и yt-dlp **2026.08.19** с зависимостями для
обложек и YouTube JS. Версия задаётся build-аргументом `YTDLP_VERSION`.
Для локального запуска установите Node.js 22+ и yt-dlp с FFmpeg/FFprobe.
Команды установки из корня репозитория:

```powershell
py -m venv backend/.venv
backend/.venv/Scripts/python.exe -m pip install "yt-dlp[default]==2026.08.19" mutagen pillow
```

В `backend/.env` укажите абсолютные пути (без кавычек вокруг значения):

```dotenv
YTDLP_PATH=D:\source\musica\backend\.venv\Scripts\yt-dlp.exe
FFMPEG_PATH=C:\Program Files\FFmpeg\bin\ffmpeg.exe
SPOTIFY_WORKER_ENABLED=true
SPOTIFY_TIMEOUT_SECONDS=900
# SPOTIFY_TMP_DIR=D:\temp\musica-spotify
```

`FFMPEG_PATH` передаётся также в `--ffmpeg-location`; FFprobe должен находиться рядом.
По умолчанию yt-dlp ищется в PATH, timeout — 900 секунд (1–3600), worker включён.
Временный корень берётся из SPOTIFY_TMP_DIR, затем TEMP или /tmp/musica-spotify.
Контейнер использует /tmp/musica-spotify. Нодам нужны доступ к Интернету,
общим PostgreSQL и MinIO; общая локальная файловая система не требуется.

Формат выгрузки описан в [Spotify](https://support.spotify.com/in-en/article/understanding-your-data/),
параметры и требования загрузчика — в [документации yt-dlp](https://github.com/yt-dlp/yt-dlp#readme).
Интеграционные проверки используют локальную фикстуру и не скачивают музыку:
`python backend/tests/api_integration.py`; parser frontend: `npm run test:spotify`.

## Архитектура

```text
src/
  main.zig                    Инициализация и регистрация фич
  config.zig                  Конфигурация из окружения
  app.zig                     Общие зависимости и HTTP-ошибки
  helpers/
    api.zig                   HTTP-ошибки и разбор JSON
  infrastructure/
    database.zig              Database/Connection, скрытый драйвер и пул PostgreSQL
    repositories/             SQL auth, playlists, tracks, streaming
    jobs/                     Общая модель Job и репозиторий jobs
    s3.zig                    S3-клиент для MinIO
  features/
    playlists/                Пользовательские плейлисты, доступ и обложки
    streaming/                HLS: маршруты, очередь PostgreSQL и фоновый воркер
    spotify_int/              Импорт Spotify, скачивание yt-dlp отдельными jobs
    health/routes.zig         Проверка доступности процесса
    tracks/
      routes.zig              HTTP-контракт
      model.zig               DTO и валидация
      service.zig             Создание, загрузка и удаление трека; управление транзакциями
      operations.zig          Переиспользуемое удаление внутри открытой транзакции
      repository.zig          API хранения без драйвера и SQL
migrations/                   SQL для ручного применения
```

Новые ручки добавляйте в соответствующую фичу. Маршруты работают с HTTP,
service координирует операции, feature/repository задаёт API хранения.
Его реализация находится в infrastructure/repositories: здесь SQL-запросы.
Сервисы получают и освобождают соединения, управляют begin/commit/rollback и
объединяют операции репозиториев в одну транзакцию. Репозитории принимают Connection
и не открывают транзакции. Структуры Upload и ImageUpload удалены.
`tracks/operations.remove` проверяет владельца и активные задания, ставит файлы
на очистку и удаляет запись трека. Вызывающий сервис управляет транзакцией:
`tracks/service.remove` использует операцию для прямого удаления,
`playlists/service.removeTrack` — для удаления из `Uploads`.
Драйвер `pg`, его Pool/Conn, разбор SQLSTATE и чтение переменных PG* находятся
только в infrastructure/database.zig. App содержит Database по значению и владеет
её пулом: инициализация выполняется при создании App, освобождение — после остановки
HTTP-сервера и фоновых задач. Сервисы заимствуют `&app.db`.
Database — структура с init/deinit, владеющая `*pg.Pool`;
Connection остаётся opaque-типом. Фичи используют методы Database и API репозиториев,
не обращаясь к полю pool. Для замены БД
меняются infrastructure-реализации, API фич и сервисы сохраняются.

Общая очередь находится в `infrastructure/jobs/`: `model.zig` описывает `Job`,
`Payload` и состояния, `repository.zig` выполняет запросы к единой таблице `jobs`.
Job содержит id, строковый kind, необязательный dedupe_key, state, attempt_id,
attempts, max_attempts, lease_until, available_at, created_at, updated_at и payload.
Времена в модели — UTC в миллисекундах Unix. Payload — произвольный JSON;
`Job.decodePayload(T, arena)` проверяет его по схеме обработчика во время выполнения.
Таблица и репозиторий не содержат колонок или типов конкретных фич.

Сервисы используют виды `prepare_hls`, `delete_s3_objects`, `upload_track`;
их схемы payload находятся в моделях фич. Воркеры выбирают только свой kind.
Общий репозиторий поддерживает постановку, получение, захват задания, продление
аренды, завершение, повтор и отмену. Для синхронного PUT аренда берётся через acquire,
для фоновых обработчиков — через claim с `FOR UPDATE SKIP LOCKED`.
Изменение результата требует совпадения attempt_id и действующей аренды;
срок действия проверяет часы PostgreSQL. Уникальная пара (kind, dedupe_key)
предотвращает дублирование операций над одним ресурсом. Для независимых заданий
dedupe_key не задаётся. max_attempts ограничивает повторы после ошибок обработчика;
NULL позволяет повторять их без ограничения.
`helpers/api.zig` задаёт общий перевод ошибок в HTTP-статусы и JSON,
включая проверки ID, файлов, Content-Type/Content-Encoding и неизвестные маршруты.
Маршруты возвращают ошибки через `api.failure`; статусы и JSON-коды задаются
только в этом helper-е.
Он также разбирает JSON-тела с лимитом размера. Для треков лимит остаётся
16 KiB, для плейлистов и авторизации — 32 KiB. Infrastructure-репозитории
вызывают Connection.text/exec напрямую. Infrastructure копирует текстовые
результаты в переданный allocator до освобождения буфера драйвера.
Infrastructure-репозитории сохраняют перевод общих ошибок
в ошибки своей фичи, например блокировки трека в `upload_in_progress`.

## Запуск через Docker Compose

Из корня репозитория скопируйте `.env.docker.example` в `.env` и замените
пароли. В PowerShell:

```powershell
Copy-Item .env.docker.example .env
```

Compose запускает три сервиса: PostgreSQL 17, MinIO и backend.
PostgreSQL и MinIO хранят данные в именованных volumes. Порты опубликованы
на `127.0.0.1`: backend `8080`, S3 API `9000`, консоль MinIO `9001`.
PostgreSQL доступен внутри сети Compose; для SQL используйте `docker compose exec`.

Сначала запустите хранилища и дождитесь их healthcheck:

```sh
docker compose up -d --build --wait postgres minio
```

Примените начальную миграцию **вручную**, один раз, к пустой БД. Если в `.env`
изменены `PGUSER` или `PGDATABASE`, замените `musica` в командах:

```sh
docker compose exec postgres psql -U musica -d musica -v ON_ERROR_STOP=1 -f /migrations/001_init.sql
```

Создайте бакет вручную через MinIO client внутри контейнера:

```sh
docker compose exec minio sh -c 'mc alias set local http://127.0.0.1:9000 "$MINIO_ROOT_USER" "$MINIO_ROOT_PASSWORD" >/dev/null && mc mb --ignore-existing "local/$S3_BUCKET"'
```

Теперь соберите и запустите backend:

```sh
docker compose up -d --build --wait
docker compose ps
docker compose logs -f backend
```

API: <http://localhost:8080/api/health>. Консоль MinIO: <http://localhost:9001>,
логин и пароль — `S3_ACCESS_KEY_ID` и `S3_SECRET_ACCESS_KEY` из `.env`.
В этом локальном Compose backend использует root keys MinIO.
Переменные `BACKEND_PORT`, `MINIO_API_PORT`, `MINIO_CONSOLE_PORT` меняют порты
на хосте; внутри сети адреса остаются `postgres:5432` и `minio:9000`.

Остановка: `docker compose down`. Volumes сохраняются. Значения PostgreSQL
в `.env` создают БД и пользователя только при первом запуске пустого volume;
смена пароля в файле не меняет пароль существующей БД.

Dockerfile собирает backend и выполняет тесты с Zig 0.16.0, затем копирует
ReleaseSafe-бинарник в отдельный runtime-образ. Поддерживаются Linux amd64 и arm64;
backend запускается с UID/GID `10001`. Архив Zig проверяется по SHA-256 из
[официального индекса](https://ziglang.org/download/index.json).
Миграции не запускаются автоматически и не подключены к init-скриптам PostgreSQL.

Образ MinIO также собирается локально: [Dockerfile](../docker/minio/Dockerfile)
использует официальные исходники MinIO `RELEASE.2025-09-07T16-13-09Z` и
`mc` `RELEASE.2025-08-13T08-35-41Z`, проверяя точные коммиты.
Это позволяет запускать Compose без недоступных готовых образов MinIO.
Первая сборка требует загрузки Go-зависимостей и занимает больше времени;
последующие сборки используют Docker-кеш.

## Подготовка и конфигурация без Docker

Нужны PostgreSQL 14+ и MinIO с доступным S3 API. Создайте БД `musica`,
пользователя с правами на неё и приватный бакет **`uploads`** в MinIO.
`uploads` — имя бакета без ведущего `/`, оригиналы новых треков размещаются
по ключу `tracks/<uuid>/source/<uuid-попытки>`, HLS — под `tracks/<uuid>/hls/<attempt-id>/`.
Backend не создаёт бакет и не применяет миграции при запуске.

Переменные описаны в [`.env.example`](.env.example). Файлы `.env` автоматически
не читаются: передайте значения через окружение процесса или ваш менеджер сервисов.
Обязательны `PGPASSWORD`, `S3_ACCESS_KEY_ID`, `S3_SECRET_ACCESS_KEY`.

HTTP-сервер заранее выделяет четыре буфера по 64 КиБ для тел запросов
(всего 256 КиБ). Их размер не зависит от `MAX_UPLOAD_BYTES`: большие тела
выделяются по необходимости. При загрузке файл пока целиком хранится в памяти.

| Переменная | По умолчанию |
| --- | --- |
| `HTTP_HOST`, `HTTP_PORT` | `127.0.0.1`, `8080` |
| `PGHOST` | `127.0.0.1` |
| `PGPORT` | `5432` |
| `PGDATABASE`, `PGUSER` | `musica` |
| `S3_ENDPOINT` | `http://127.0.0.1:9000` |
| `S3_REGION` | `us-east-1` |
| `S3_BUCKET` | `media` (Compose задаёт `uploads`) |
| `MAX_UPLOAD_BYTES` | `67108864` (64 MiB), максимум 512 MiB |
| `AUTH_COOKIE_SECURE` | `false`; установите `true` при HTTPS |

`S3_ENDPOINT` указывает на S3 API, а не на web console MinIO. Поддерживаются
HTTP/HTTPS и path-style URL; endpoint должен быть без пути, query и credentials.
Имена бакетов допускают строчные латинские буквы, цифры и дефис.
S3-пользователю нужны `s3:PutObject`, `s3:GetObject` для треков и обложек,
а также `s3:DeleteObject` для треков в настроенном бакете и исторических бакетах.
Этот клиент использует постоянные access/secret keys, без STS session token.
Соединение PostgreSQL в текущей сборке без TLS; используйте локальную или
доверенную сеть между backend и БД.

После ручного применения миграций запустите backend. Пример в PowerShell
из каталога `backend/`:

```powershell
$env:PGHOST = '127.0.0.1'
$env:PGPORT = '5432'
$env:PGDATABASE = 'musica'
$env:PGUSER = 'musica'
$env:PGPASSWORD = 'ваш-пароль-БД'
$env:S3_ACCESS_KEY_ID = 'ваш-access-key'
$env:S3_SECRET_ACCESS_KEY = 'ваш-secret-key'
zig build run
```

Backend подключает пул из четырёх соединений PostgreSQL при запуске.
Если подключиться не удалось, запуск завершается с ошибкой. HTTP по умолчанию
слушает `127.0.0.1:8080`. `HTTP_HOST` принимает IP-адрес, `HTTP_PORT` — порт;
в контейнере используется `0.0.0.0:8080`. Для self-hosting используйте reverse proxy.
Задача VS Code `Backend: run` наследует окружение самого VS Code:
запустите редактор из терминала с уже заданными переменными.

## Ручные миграции

Схема объединена в `migrations/001_init.sql`, рассчитанный на пустую БД после
сброса. Выполните его вручную один раз из каталога `backend/`:

```sh
psql -h 127.0.0.1 -p 5432 -U musica -d musica -v ON_ERROR_STOP=1 -f migrations/001_init.sql
```

Замените параметры подключения при необходимости. Пароль `psql` запрашивает
интерактивно либо читает из `PGPASSWORD`. Файл создаёт актуальную схему целиком
в одной транзакции: пользователей, сессии, плейлисты, связи, треки, enum статуса,
триггер дефолтного `Uploads` и общую очередь `public.jobs` с индексами и ограничениями.
Таблицы приложения, enum и функция триггера размещаются в `musica`, очередь —
в `public.jobs`. SQL-запросы явно указывают схему и не зависят от `search_path`
подключения.

Старые миграции удалены. Повторное применение к уже созданной схеме не предусмотрено.
Backend не сбрасывает БД и не применяет миграцию автоматически. Новые изменения
схемы добавляйте следующими файлами с последовательными номерами.

## Пользователи и сессии

`POST /api/auth/register` создаёт пользователя, приватный дефолтный плейлист
`Uploads` и сессию в одной транзакции. `POST /api/auth/login` создаёт новую
сессию. Тело обоих запросов:

```json
{"username":"alice","password":"long-password-123"}
```

Имя: 3–64 символа `a-z`, `0-9`, `_`. Пароль: 12–1024 байта UTF-8.
Ответ регистрации `201`, входа `200`:

```json
{"user_id":"UUID","token":"64-символа-hex","token_type":"Bearer","expires_in":2592000}
```

Передавайте токен в `Authorization: Bearer <token>`. Сессия действует 30 дней.
Вход/регистрация также устанавливают `musica_session` с `HttpOnly`,
`SameSite=Strict`, `Path=/api`. Браузер может использовать эту cookie
вместо Bearer, в том числе для нативного HLS. При HTTPS задайте
`AUTH_COOKIE_SECURE=true`. Для cookie-запросов, меняющих данные, присутствующий
`Origin` должен совпадать с `Host`; reverse proxy должен сохранять исходный Host.
Bearer имеет приоритет, токены в query не используются.
`POST /api/auth/logout` отзывает текущую сессию и очищает cookie (`204`).
`GET /api/users/me` возвращает `id`, `username`, `default_playlist_id`.
Сессии и ссылки используют 256 случайных бит; в БД хранятся только SHA-256-хеши
токенов. Пароли хешируются Argon2id (19 MiB, 2 прохода, 1 поток), по
[рекомендации OWASP](https://cheatsheetseries.owasp.org/cheatsheets/Password_Storage_Cheat_Sheet.html).
Для внешнего доступа используйте HTTPS и ограничение частоты запросов
регистрации/входа на reverse proxy. Регистрация сейчас открыта; приглашения
и восстановление пароля пока отсутствуют. Истёкшие сессии можно удалять вручную:
`DELETE FROM musica.sessions WHERE expires_at <= now();`.

## Плейлисты и доступ

`POST /api/playlists` с Bearer-токеном создаёт плейлист текущего пользователя:

```json
{
  "title": "Любимые треки",
  "description": "Музыка для вечера",
  "tags": ["chill", "live"],
  "visibility": "private"
}
```

Обязательно только `title`: 1–256 символов. Описание по умолчанию пустое,
до 4096 символов. Теги по умолчанию `[]`: до 32 непустых тегов, каждый до
64 символов, без пробелов по краям и повторов. Доступ по умолчанию `private`.
Ответ `201`: `{"id":"UUID","visibility":"private"}`.

| Запрос | Назначение |
| --- | --- |
| `GET /api/playlists` | Свои плейлисты и плейлисты с назначенной ролью: метаданные, `role`, `track_count`; сначала Uploads, затем название |
| `GET /api/playlists/:id` | Метаданные и список треков |
| `PUT /api/playlists/:id` | Заменить название, описание, теги и видимость; тело как при создании, ответ `204` |
| `DELETE /api/playlists/:id` | Удалить обычный плейлист, его связи и доступ участников; только владелец (`204`) |
| `PUT /api/playlists/:id/image` | Загрузить обложку байтами PNG/JPEG/WebP, до 5 MiB |
| `GET /api/playlists/:id/image` | Получить обложку с проверкой доступа к плейлисту; без обложки `404` |
| `PUT /api/playlists/:id/tracks/:track_id` | Добавить свой трек в плейлист, повторный запрос безопасен (`204`) |
| `DELETE /api/playlists/:id/tracks/:track_id` | Обычный плейлист: убрать связь; Uploads: удалить свой трек целиком (`204`) |
| `DELETE /api/tracks/:id` | Удалить свой трек, все связи и поставить файлы на очистку (`204`) |
| `PUT /api/playlists/:id/members/:user_id` | Назначить/изменить роль: `{"role":"viewer"}` или `{"role":"editor"}` (`204`) |
| `DELETE /api/playlists/:id/members/:user_id` | Отозвать доступ участника (`204`) |
| `POST /api/playlists/:id/share-link` | Создать или заменить ссылку для `unlisted`; ответ `{"path":"/api/shared/playlists/<token>"}` |
| `DELETE /api/playlists/:id/share-link` | Отозвать ссылку (`204`) |
| `GET /api/shared/playlists/:token` | Просмотр плейлиста по ссылке без входа |

Удаление плейлиста сохраняет сами треки, в том числе в `Uploads`; обложка
ставится на очистку через `delete_s3_objects` в той же транзакции.
Ссылка доступа перестаёт работать. Дефолтный `Uploads` удалить нельзя:
`409 default_playlist_protected`. Чужой или отсутствующий плейлист возвращает
`404 not_found`; повторное удаление также возвращает `404`.

`private` доступен владельцу и назначенным участникам. `public` доступен
на просмотр без входа по ID. `unlisted` доступен владельцу, участникам и
обладателям секретной ссылки; одного ID недостаточно. При уходе из `unlisted`
ссылка отзывается. Генерация новой ссылки также отзывает предыдущую.
Приватные и недоступные плейлисты возвращают `404`, чтобы не раскрывать наличие.

`viewer` может просматривать плейлист, `editor` — также изменять метаданные,
обложку и состав треков. Только владелец управляет участниками и ссылками.
Публичность и ссылка дают только просмотр. Дефолтный плейлист всегда приватный;
удаление из него удаляет сам трек. Каждый новый трек добавляется туда,
а `playlist_ids` задаёт дополнительные плейлисты с правами владельца или редактора.

Обложки сохраняются в приватный бакет из `S3_BUCKET` под `playlists/<id>/<random>`.

Список `/api/playlists` требует входа; публичные плейлисты других пользователей
без назначенной роли в него не включаются. В треках ответа есть `owner_id`.

Полное удаление трека атомарно удаляет его запись, все связи и задачу HLS.
При активном PUT возвращается `409 upload_in_progress`, при действующей аренде
HLS — `409 track_preparation_in_progress`; повторите удаление после завершения.
Фоновый воркер каждой ноды очищает оригинал, опубликованный манифест и сегменты
по сохранённым бакету/ключам. При сбое MinIO задача повторяется через 30 секунд;
после падения ноды — после истечения 120-секундной аренды. DELETE объекта
идемпотентен. HTTP `204` означает, что запись удалена и очистка поставлена в очередь,
а не что MinIO уже ответил. Очередь работает и при `HLS_WORKER_ENABLED=false`.
В логах очистки указываются ID задания и попытки, число объектов, завершение
или причина ошибки; в Debug также выводится прогресс по объектам.
Незавершённые префиксы прежних HLS-попыток пока требуют отдельной очистки.
Ответ загрузки содержит `image_key` и `bucket`; `GET` плейлиста тоже возвращает
`image_key`. Сейчас отдельной ручки скачивания обложки нет. Проверяется MIME
и сигнатура файла, полноценное декодирование изображения не выполняется.
Старые обложки и объекты, оставшиеся после сбоя коммита БД, автоматически
не удаляются; для них потребуется очистка хранилища.

## Создание трека

`POST /api/tracks`, `Content-Type: application/json`, Bearer-токен:

```json
{
  "playlist_ids": [
    "11111111-1111-4111-8111-111111111111",
    "22222222-2222-4222-8222-222222222222"
  ],
  "title": "Название трека",
  "artist": "Исполнитель"
}
```

`playlist_ids` необязателен: отсутствие поля или `[]` добавляет трек только
в дефолтный плейлист текущего пользователя. `null` не принимается.
Можно передать до 100 UUID дополнительных плейлистов с правом редактирования.
Повторы запрещены, включая разные регистры одного UUID. Указание дефолтного
плейлиста не создаёт повторную связь.
`title` и `artist` — непустые UTF-8
строки до 256 символов; пробелы по краям удаляются. Лимит JSON — 16 KiB.
Ответ **201**:

```json
{"id":"UUID-созданного-трека","status":"pending"}
```

Трек и все связи с плейлистами создаются в одной транзакции, без файла.
При создании записываются `storage_bucket` из текущего `S3_BUCKET` и
`object_key = tracks/<uuid>/source`. Статус остаётся `pending`, а `content_type`,
`size_bytes` и `uploaded_at` — `NULL` до успешной загрузки. Наличие пути
не означает, что объект уже существует в S3.
Если хотя бы один плейлист не найден, ни трек, ни связи не сохраняются.
Невалидный JSON или метаданные → `400`,
неизвестный плейлист → `404`, неподходящий Content-Type → `415`.

## Загрузка файла

`PUT /api/tracks/:id/file` с Bearer-токеном владельца трека:
передавайте **сами байты файла** в теле запроса. Чужие треки возвращают `404`.
Используйте `Content-Type: audio/mpeg`, `audio/flac`, `audio/wav`, `audio/ogg`,
`audio/aac`, `audio/mp4`, `audio/webm` или `application/octet-stream`.
Поддерживаются также `audio/x-flac`, `audio/x-wav`, `application/ogg`.
Multipart/form-data и сжатое Content-Encoding не принимаются.

Пример двух запросов в PowerShell:

```powershell
$token = 'токен-из-регистрации-или-входа'
$metadata = @{ title = 'Песня'; artist = 'Исполнитель' } | ConvertTo-Json
$track = Invoke-RestMethod -Method Post -Uri http://127.0.0.1:8080/api/tracks `
  -Headers @{ Authorization = "Bearer $token" } `
  -ContentType 'application/json; charset=utf-8' -Body ([Text.Encoding]::UTF8.GetBytes($metadata))
curl.exe --fail-with-body -X PUT "http://127.0.0.1:8080/api/tracks/$($track.id)/file" `
  -H "Authorization: Bearer $token" -H 'Content-Type: audio/mpeg' --data-binary '@track.mp3'
```

Backend отправляет файл в MinIO как S3 PUT, затем сохраняет метаданные объекта
в PostgreSQL. Ответ **200**:

```json
{
  "id": "UUID-трека",
  "status": "ready",
  "bucket": "uploads",
  "object_key": "tracks/UUID-трека/source/UUID-попытки",
  "size_bytes": 123456,
  "content_type": "audio/mpeg"
}
```

Файл буферизуется в памяти, потоковая загрузка пока не реализована. Формат
аудио определяется переданным MIME; содержимое файла пока не декодируется.

| Код | Ситуация |
| --- | --- |
| `400` | Некорректный ID, пустое тело или невалидные метаданные |
| `401` | Нет действительной сессии |
| `404` | Плейлист или трек не найден |
| `409` | Трек уже загружен или другой PUT сейчас загружает этот трек |
| `413` | Превышен лимит тела запроса |
| `415` | Неподдерживаемый Content-Type/Content-Encoding |
| `500` | В ReleaseSafe/ReleaseFast/ReleaseSmall: внутренняя ошибка без раскрытия причины |
| `502` | Только Debug: ошибка S3/MinIO |
| `503` | Только Debug: ошибка PostgreSQL, включая отсутствие применённых миграций |
| `504` | Только Debug: S3-операция превысила 60 секунд |

Ошибки ручек возвращаются в форме `{"error":"код_ошибки"}`. Ошибка размера
тела, обнаруженная самим HTTP-сервером до маршрута, может иметь другой формат.
В Debug сбои инфраструктуры возвращают `database_unavailable`,
`storage_unavailable` или `storage_timeout`. Во всех Release-сборках они
возвращают одинаковые `500` и `{"error":"internal_error"}`. Причина остаётся
в серверных логах; для SQL дополнительно записывается SQLSTATE, когда он
доступен. Текст SQL, параметры запросов и сообщения PostgreSQL не логируются.
Ошибки валидации, авторизации, доступа и конфликты сохраняют свои коды.

Перед запуском backend после сброса БД вручную примените `001_init.sql`.
HLS, удаление объектов и аренды загрузки используют общую таблицу `public.jobs`.

Каждая попытка пишет в `<сохранённый object_key>/<uuid-попытки>`.
Для нового трека это `tracks/<id>/source/<uuid-попытки>`. Поздний ответ
старой попытки не может перезаписать или опубликовать результат новой загрузки.
Сохранённый бакет используется и для исторических треков; уже загруженные объекты
не перемещаются. PUT возвращает фактические `bucket` и `object_key`, которые HLS
читает из БД.

До S3 PUT в `jobs` сохраняется отложенное задание `delete_s3_objects` на очистку.
Успешная публикация отменяет его в той же транзакции, что обновляет трек.
Если запрос завершился ошибкой, потерял аренду или процесс остановился, фоновый
обработчик удалит объект незавершённой попытки после 120 секунд.
Обложки загружаются аналогично: соединение освобождается перед S3, права редактора
проверяются повторно при сохранении ссылки на изображение. Неопубликованные
обложки также попадают в очистку. PostgreSQL и S3 не образуют общую транзакцию;
при потере ответа коммита трек может уже стать `ready`, и повторный PUT вернёт `409`.

`GET /api/health` сохраняет прежний контракт и проверяет доступность процесса,
а не текущую готовность PostgreSQL или MinIO. Для воспроизведения доступны HLS-ручки ниже.

## HLS и несколько нод

Состояние трека: `pending` → `ready` → `streamed`. `ready` означает, что
загружен оригинал; `streamed` выставляется только после сохранения всех HLS
объектов. Состояние задачи хранится отдельно: `queued / processing / completed / failed`.
Оригинал сохраняется для повторной подготовки и не перезаписывается.

| Метод и путь | Поведение |
| --- | --- |
| `POST /api/tracks/:id/hls` | Владелец запускает подготовку: `202` со статусом задачи; для уже готового трека `200` |
| `GET /api/tracks/:id/hls/status` | `200`, например `{"status":"ready","preparation":"processing"}` |
| `GET /api/tracks/:id/hls/index.m3u8` | VOD-манифест, `application/vnd.apple.mpegurl` |
| `GET /api/tracks/:id/hls/segments/segment-000000.ts` | Готовый сегмент, `video/mp2t` |

POST не требует JSON-тела. Повторный POST для queued/processing идемпотентен,
для failed ставит задачу заново. Для pending возвращается `409 track_not_uploaded`.
До готовности GET манифеста/сегмента возвращает `409 hls_not_ready`.
Поле `preparation` использует общие состояния jobs: `queued`, `processing`,
`completed`, `failed`; до создания задачи — `null`. При успешном завершении
подготовки трек получает `status: "streamed"` и `preparation: "completed"`.
Номер отсутствующего сегмента возвращает `404`. При ошибке подготовки трек остаётся `ready`,
задача становится `failed`, подробности записываются только в лог.

```powershell
curl.exe -X POST "http://127.0.0.1:8080/api/tracks/$track/hls" -H "Authorization: Bearer $token"
curl.exe "http://127.0.0.1:8080/api/tracks/$track/hls/status" -H "Authorization: Bearer $token"
curl.exe "http://127.0.0.1:8080/api/tracks/$track/hls/index.m3u8" -H "Authorization: Bearer $token"
```

Каждый GET проверяет доступ: владелец трека, участник связанного плейлиста,
публичный плейлист или действующая ссылка unlisted-плейлиста. Для приватного
воспроизведения HLS-клиент передаёт Bearer либо cookie-сессию в запросах манифеста
и всех сегментов. Для доступа по ссылке передайте `?share_token=<token>`
к манифесту; backend добавит этот параметр в относительные URL сегментов.
Отзыв ссылки/участника действует и для последующих запросов сегментов.
Все ответы имеют `Cache-Control: no-store`; произвольные S3-пути не принимаются.

В каждом процессе по умолчанию работает один фоновый воркер. Он скачивает
оригинал, запускает FFmpeg: AAC 192 kbit/s, stereo, 48 kHz, MPEG-TS, сегменты
около 6 секунд и VOD-манифест. Исходный MP3 и другие поддерживаемые аудиоформаты
определяются FFmpeg; невалидный файл приводит к failed. FFmpeg запускается
без shell, с ограничением протоколов и демультиплексоров. Docker-образ включает
FFmpeg; для локального запуска установите его и добавьте в PATH или задайте путь.

Для Windows укажите путь к файлу, например
`FFMPEG_PATH=C:/Program Files/FFmpeg/bin/ffmpeg.exe`, а не каталог `bin`.
Debug-конфигурация VS Code читает `backend/.env`; после изменения перезапустите
отладку. Отсутствующий executable даёт `FfmpegNotFound` с путём в логе,
задача становится failed без автоматических повторов. После исправления
конфигурации повторите POST подготовки.

| Окружение | По умолчанию | Назначение |
| --- | --- | --- |
| `FFMPEG_PATH` | `ffmpeg` | Исполняемый файл FFmpeg |
| `HLS_WORKER_ENABLED` | `true` | `false` отключает воркер, сохраняя HTTP-ручки |
| `HLS_TIMEOUT_SECONDS` | `900` | Дедлайн всей подготовки, максимум 3600 секунд |
| `HLS_TMP_DIR` | Windows: `TEMP`; иначе `/tmp/musica-hls` | Доступный для записи временный каталог |

Воркеры забирают задачи через короткий `FOR UPDATE SKIP LOCKED`, получают
60-секундную аренду и токен попытки, продлевают аренду каждые 10 секунд.
После падения ноды задача доступна другой ноде по истечении аренды.
Конвертация и S3 не удерживают транзакцию БД. Сегменты, затем манифест
загружаются в сохранённый бакет исходника по префиксу
`tracks/<id>/hls/<attempt-id>/`. Транзакция публикации проверяет актуальный
токен и аренду, одновременно выставляет `streamed` и фиксирует этот префикс.
Опоздавшая попытка не может изменить результат новой.

Ошибки конвертации и дедлайн требуют повторного POST; временные ошибки
хранилища повторяются автоматически до трёх попыток с задержкой 30 секунд.
Сбой процесса восстанавливается по аренде, а не по счётчику попыток.
Лимиты: 10000 сегментов, сегмент до 2 MiB, манифест до 1 MiB; оригинал
ограничен `MAX_UPLOAD_BYTES`. Оригинал и ответы GET читаются с ограничением
в память; загрузка сегментов выполняется последовательно.

Сессии и задачи находятся в PostgreSQL, файлы — в MinIO: любую HTTP-ноду
можно использовать для воспроизведения, sticky sessions не нужны.
Локальный каталог попытки удаляется после завершения/отмены; после аварийного
завершения процесса он может остаться. Незавершённые S3-префиксы не публикуются,
но их автоматическая очистка пока не реализована. Все ноды должны использовать
одни PostgreSQL/MinIO и иметь доступ к историческим бакетам.

Реализация использует [HLS muxer FFmpeg](https://ffmpeg.org/ffmpeg-formats.html#hls)
и [блокировки PostgreSQL](https://www.postgresql.org/docs/18/sql-select.html#SQL-FOR-UPDATE-SHARE).

## Отладка в VS Code на Windows

Откройте корень репозитория в VS Code. Нужны Zig 0.16.0 в `PATH` и
расширение [C/C++](https://marketplace.visualstudio.com/items?itemName=ms-vscode.cpptools).
Расширение Zig рекомендуется для работы с исходниками.

Создайте локальный файл настроек из корня проекта, если его ещё нет:

```powershell
Copy-Item backend/.env.example backend/.env
```

В `backend/.env` задайте реальные `PGPASSWORD`, `S3_ACCESS_KEY_ID` и
`S3_SECRET_ACCESS_KEY`, а также адреса сервисов. Для хранилищ из Compose
используйте `PGHOST=127.0.0.1`, опубликованный `PGPORT` и
`S3_ENDPOINT=http://127.0.0.1:9000` (или ваш опубликованный порт MinIO).
Учётные данные должны совпадать с корневым `.env` Compose.
Запустите только хранилища: `docker compose up -d --wait postgres minio`.
Миграции применяются вручную, как описано выше.

В панели Run and Debug выберите **Backend: debug (Windows)**, поставьте
breakpoint в `src/main.zig` или обработчике маршрута и нажмите **F5**.
Перед запуском задача **Backend: build Debug** выполняет
`zig build -Doptimize=Debug --prefix zig-out/debug`. EXE и PDB находятся
в `backend/zig-out/debug/bin/`; отладчик запускает EXE напрямую.
Для breakpoint в HTTP-обработчике отправьте соответствующий запрос к API.

Настройки из `backend/.env` загружает отладчик VS Code через `envFile`;
обычный `zig build run` по-прежнему наследует окружение процесса.
Файл с секретами исключён из Git. Если порт backend занят другим процессом
или контейнером, остановите его либо задайте другой `HTTP_PORT` в `backend/.env`.
**Shift+F5** останавливает отлаживаемый backend.

Описание параметров отладчика: [документация VS Code](https://code.visualstudio.com/docs/cpp/launch-json-reference).

## Проверки

Из `backend/`:

```sh
zig fmt --check build.zig src
zig build
zig build test --summary all
zig build test -Dtest-filter="HLS publication" --summary all
zig build test -Doptimize=ReleaseSafe --summary all
zig build -Doptimize=ReleaseSafe
```

При открытом корне репозитория панель VS Code **Testing → Run Test** использует
`.vscode/settings.json`: `zig build test --build-file backend/build.zig
-Dtest-filter=<имя теста>`. Прямой `zig test <файл>` не подключает модули из
build.zig и может запрещать относительные импорты за пределами каталога файла.
Расширение показывает тесты открытых Zig-файлов; для полного набора используйте
задачу `Backend: test` либо команду `zig build test --summary all`.

Тесты проверяют валидацию и HTTP-ошибки, UTC-даты, подпись SigV4 на фиксированном
независимом примере, бинарный PUT, отказ хранилища и отмену зависшего запроса
на локальном тестовом сервере.
Они не требуют PostgreSQL или MinIO. Для сквозной проверки запустите оба сервиса,
примените миграции вручную, выполните запросы выше и проверьте строку `tracks`,
её связи в `track_playlists` и объект в бакете `uploads`.

Автоматическая интеграционная проверка из корня репозитория:

```sh
python backend/tests/api_integration.py
python backend/tests/api_integration.py --optimize ReleaseSafe

# Реальный FFmpeg и несколько нод (образ собирается в ReleaseSafe):
docker build -t musica-backend:hls-test backend
python backend/tests/api_integration.py --optimize ReleaseSafe --backend-image musica-backend:hls-test
```

Нужны Python 3, работающий Docker Compose и Zig 0.16. Скрипт создаёт отдельный
случайно названный проект с пустой PostgreSQL, применяет `001_init.sql` только в нём,
проверяет обращения к `public.jobs` при наличии одноимённой таблицы раньше в
`search_path`, сессии, права, дефолтные плейлисты, изменение
метаданных, обложки, шаринг и откат создания трека, затем удаляет тестовые
контейнеры и volume. Пользовательская БД не затрагивается. S3 здесь заменён
локальным HTTP-сервером; для проверки настоящего MinIO используйте ручной сценарий.
Проверяются также ответы и логи при сбоях БД и S3: диагностические в Debug,
без указания инфраструктуры в Release.

С `--backend-image` скрипт дополнительно генерирует настоящий MP3, проверяет
AAC-сегменты через ffprobe, работу двух воркеров и отдельной HTTP-ноды,
восстановление истёкшей аренды и отказ публикации старой попытки, права
на сегменты, отзыв ссылки, ошибку конвертации и повторный запуск.
Дополнительно проверяются cookie/CSRF, список плейлистов, чтение обложки,
два режима удаления, очистка оригинала/HLS и повтор после отказа MinIO.
Выбирайте `--optimize`, соответствующий режиму сборки образа. SigV4 PUT, GET и DELETE
проверяются тестовым S3-сервером независимо через Python hashlib/hmac.

Протокол S3 опирается на [PutObject](https://docs.aws.amazon.com/AmazonS3/latest/API/API_PutObject.html)
и [GetObject](https://docs.aws.amazon.com/AmazonS3/latest/API/API_GetObject.html)
и [AWS Signature V4](https://docs.aws.amazon.com/IAM/latest/UserGuide/reference_sigv-create-signed-request.html).
Драйвер PostgreSQL: [pg.zig](https://github.com/karlseguin/pg.zig).

S3 владеет одним HTTP-клиентом с пулом соединений для параллельных запросов.
Настройки S3 и их проверка находятся в `infrastructure/s3.zig` (`Settings.load`).
Общий `Config` содержит `s3: Settings`; `S3.init` принимает только настройки S3.
После первого запроса экземпляр нельзя копировать. Бакет для конкретной операции
передаётся через методы `putInBucket`, `getInBucket`, `deleteInBucket`.
`S3.deinit()` вызывается после остановки HTTP-сервера и фоновых воркеров.

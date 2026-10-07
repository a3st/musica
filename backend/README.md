# Backend Musica

Zig **0.16.0**, HTTP-сервер `httpz`, PostgreSQL через `pg.zig`, MinIO через
S3 PutObject/GetObject с подписью AWS Signature V4, HLS через FFmpeg. Обе Zig-зависимости закреплены
на конкретных коммитах для Zig 0.16.

## Архитектура

```text
src/
  main.zig                    Инициализация и регистрация фич
  config.zig                  Конфигурация из окружения
  app.zig                     Общие зависимости и HTTP-ошибки
  helpers/
    api.zig                   HTTP-ошибки и разбор JSON
    sql.zig                   Выполнение запросов и ошибки PostgreSQL
  infrastructure/
    database.zig              Пул PostgreSQL
    s3.zig                    S3-клиент для MinIO
  features/
    playlists/                Пользовательские плейлисты, доступ и обложки
    streaming/                HLS: маршруты, очередь PostgreSQL и фоновый воркер
    health/routes.zig         Проверка доступности процесса
    tracks/
      routes.zig              HTTP-контракт
      model.zig               DTO и валидация
      service.zig             Создание и загрузка трека
      repository.zig          Параметризованные SQL-запросы
migrations/                   SQL для ручного применения
```

Новые ручки добавляйте в соответствующую фичу. Маршруты работают с HTTP,
service координирует операции, repository работает с PostgreSQL,
infrastructure содержит подключения к внешним сервисам.
`helpers/api.zig` задаёт общий перевод ошибок в HTTP-статусы и JSON,
включая проверки ID, файлов, Content-Type/Content-Encoding и неизвестные маршруты.
Маршруты возвращают ошибки через `api.failure`; статусы и JSON-коды задаются
только в этом helper-е.
Он также разбирает JSON-тела с лимитом размера. Для треков лимит остаётся
16 KiB, для плейлистов и авторизации — 32 KiB. `helpers/sql.zig`
выполняет параметризованные запросы, переводит ошибки PostgreSQL и копирует
текстовые результаты в переданный allocator до освобождения буфера драйвера.
Repositories сохраняют управление транзакциями и перевод общих SQL-ошибок
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

Примените миграции **вручную**, один раз, в указанном порядке. Если в `.env`
изменены `PGUSER` или `PGDATABASE`, замените `musica` в командах:

```sh
docker compose exec postgres psql -U musica -d musica -v ON_ERROR_STOP=1 -f /migrations/001_create_albums.sql
docker compose exec postgres psql -U musica -d musica -v ON_ERROR_STOP=1 -f /migrations/002_create_tracks.sql
docker compose exec postgres psql -U musica -d musica -v ON_ERROR_STOP=1 -f /migrations/003_track_albums.sql
docker compose exec postgres psql -U musica -d musica -v ON_ERROR_STOP=1 -f /migrations/004_users_and_albums.sql
docker compose exec postgres psql -U musica -d musica -v ON_ERROR_STOP=1 -c "SET musica.pending_bucket = 'uploads'" -f /migrations/005_pending_track_storage.sql
docker compose exec postgres psql -U musica -d musica -v ON_ERROR_STOP=1 -f /migrations/006_albums_to_playlists.sql
docker compose exec postgres psql -U musica -d musica -v ON_ERROR_STOP=1 -f /migrations/007_remove_playlist_artist.sql
docker compose exec postgres psql -U musica -d musica -v ON_ERROR_STOP=1 -f /migrations/008_track_status_enum.sql
docker compose exec postgres psql -U musica -d musica -v ON_ERROR_STOP=1 -f /migrations/009_track_hls.sql
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

Образ MinIO также собирается локально: [Dockerfile](docker/minio/Dockerfile)
использует официальные исходники MinIO `RELEASE.2025-09-07T16-13-09Z` и
`mc` `RELEASE.2025-08-13T08-35-41Z`, проверяя точные коммиты.
Это позволяет запускать Compose без недоступных готовых образов MinIO.
Первая сборка требует загрузки Go-зависимостей и занимает больше времени;
последующие сборки используют Docker-кеш.

## Подготовка и конфигурация без Docker

Нужны PostgreSQL 14+ и MinIO с доступным S3 API. Создайте БД `musica`,
пользователя с правами на неё и приватный бакет **`uploads`** в MinIO.
`uploads` — имя бакета без ведущего `/`, оригиналы новых треков размещаются
по ключу `tracks/<uuid>/source`, HLS — под `tracks/<uuid>/hls/<attempt-id>/`.
Backend не создаёт бакет и не применяет миграции при запуске.

Переменные описаны в [`.env.example`](.env.example). Файлы `.env` автоматически
не читаются: передайте значения через окружение процесса или ваш менеджер сервисов.
Обязательны `PGPASSWORD`, `S3_ACCESS_KEY_ID`, `S3_SECRET_ACCESS_KEY`.

| Переменная | По умолчанию |
| --- | --- |
| `HTTP_HOST`, `HTTP_PORT` | `127.0.0.1`, `8080` |
| `PGHOST` | `127.0.0.1` |
| `PGPORT` | `5432` |
| `PGDATABASE`, `PGUSER` | `musica` |
| `S3_ENDPOINT` | `http://127.0.0.1:9000` |
| `S3_REGION` | `us-east-1` |
| `S3_BUCKET` | `uploads` |
| `MAX_UPLOAD_BYTES` | `67108864` (64 MiB), максимум 512 MiB |

`S3_ENDPOINT` указывает на S3 API, а не на web console MinIO. Поддерживаются
HTTP/HTTPS и path-style URL; endpoint должен быть без пути, query и credentials.
Имена бакетов допускают строчные латинские буквы, цифры и дефис.
S3-пользователю требуется разрешение `s3:PutObject` для `uploads/tracks/*`
и `uploads/playlists/*` (обложки).
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

Выполните файлы **один раз, по порядку** из каталога `backend/`:

```sh
psql -h 127.0.0.1 -p 5432 -U musica -d musica -v ON_ERROR_STOP=1 -f migrations/001_create_albums.sql
psql -h 127.0.0.1 -p 5432 -U musica -d musica -v ON_ERROR_STOP=1 -f migrations/002_create_tracks.sql
psql -h 127.0.0.1 -p 5432 -U musica -d musica -v ON_ERROR_STOP=1 -f migrations/003_track_albums.sql
psql -h 127.0.0.1 -p 5432 -U musica -d musica -v ON_ERROR_STOP=1 -f migrations/004_users_and_albums.sql
psql -h 127.0.0.1 -p 5432 -U musica -d musica -v ON_ERROR_STOP=1 -c "SET musica.pending_bucket = 'uploads'" -f migrations/005_pending_track_storage.sql
psql -h 127.0.0.1 -p 5432 -U musica -d musica -v ON_ERROR_STOP=1 -f migrations/006_albums_to_playlists.sql
psql -h 127.0.0.1 -p 5432 -U musica -d musica -v ON_ERROR_STOP=1 -f migrations/007_remove_playlist_artist.sql
psql -h 127.0.0.1 -p 5432 -U musica -d musica -v ON_ERROR_STOP=1 -f migrations/008_track_status_enum.sql
psql -h 127.0.0.1 -p 5432 -U musica -d musica -v ON_ERROR_STOP=1 -f migrations/009_track_hls.sql
```

В командах указаны стандартные параметры: замените их при необходимости.
Пароль `psql` запрашивает интерактивно либо читает из `PGPASSWORD`.
Каждый файл выполняется в транзакции. Повторное выполнение не предусмотрено;
учёт применённых миграций ведите вручную. `gen_random_uuid()` — встроенная
функция PostgreSQL, отдельное расширение не требуется.

В существующей БД выполните только ещё не применённые миграции.
`003_track_albums.sql` переносит существующие связи в `track_albums`,
затем удаляет `tracks.album_id`. `004_users_and_albums.sql` добавляет
пользователей, сессии, владельцев плейлистов и треков, участников и настройки доступа.
`005_pending_track_storage.sql` сохраняет бакет и предполагаемый ключ для
старых `pending`-треков. В команде `SET musica.pending_bucket` укажите
**прежний** `S3_BUCKET`, куда могли загружаться их файлы. Если были разные
бакеты, сначала выясните расположение объектов: старая схема его не сохраняла.
Без этой настройки миграция при наличии `pending`-записей завершится ошибкой.
Пути и метаданные существующих `ready`-треков сохраняются.
`006_albums_to_playlists.sql` переименовывает `albums` в `playlists`,
`track_albums` в `track_playlists`, `album_members` в `playlist_members`
и поля связей `album_id` в `playlist_id`, обновляет триггер дефолтной коллекции.
Исторические миграции не изменены. Выполните все ещё не применённые миграции
перед запуском новой версии backend.
ID, связи, настройки доступа, роли, токены ссылок и ключи обложек сохраняются.
`007_remove_playlist_artist.sql` удаляет старое поле `playlists.artist`
вместе с его ограничением. У плейлиста нет исполнителя; `tracks.artist`
сохраняется. Значения удаляемого поля не переносятся.

`008_track_status_enum.sql` меняет тип `tracks.status` с `text` на PostgreSQL
enum `track_status`. В Zig используется `TrackStatus`. Значения и JSON API
сохраняются: `pending` — ожидается исходный файл, `ready` — исходный файл
загружен. Метаданные и пути существующих треков сохраняются. Миграция берёт
эксклюзивную блокировку `tracks`; выполняйте её в окно обслуживания.

`009_track_hls.sql` добавляет `streamed`, поля готового HLS и очередь
`track_hls_jobs`. Исходные файлы и статусы старых треков сохраняются.
Сначала примените миграции, затем запустите новую версию backend.

API переименован: `/api/albums` → `/api/playlists`,
`/api/shared/albums/:token` → `/api/shared/playlists/:token`,
`album_ids` → `playlist_ids`, `default_album_id` → `default_playlist_id`.
Старые URL больше не обслуживаются; для существующих ссылок замените
`/api/shared/albums/` на `/api/shared/playlists/`, сохранив токен.
Это переименование существующих коллекций: `Uploads` остаётся дефолтным
приватным плейлистом, отдельная библиотека пользователя пока не выделена.
Таблица `track_playlists` сохраняет одну связь на пару трек/плейлист;
порядок и повторные вхождения через `playlist_items` пока не реализованы.
Один трек имеет одну запись и один файл независимо от числа плейлистов;
пары трек/плейлист уникальны. Удаление трека удаляет его связи, удаление
плейлиста со связанными треками запрещено.

Старые плейлисты и треки сохраняются с `owner_id = NULL` и недоступны через
новый API. После регистрации нужного пользователя назначьте ему старые записи
вручную. Например, замените UUID и выполните в транзакции:

```sql
BEGIN;
UPDATE playlists SET owner_id = 'UUID-пользователя' WHERE id = 'UUID-старого-плейлиста';
UPDATE tracks SET owner_id = 'UUID-пользователя' WHERE id = 'UUID-старого-трека';
INSERT INTO track_playlists (track_id, playlist_id)
SELECT t.id, a.id FROM tracks t JOIN playlists a ON a.owner_id = t.owner_id AND a.is_default
WHERE t.id = 'UUID-старого-трека'
ON CONFLICT DO NOTHING;
COMMIT;
```

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
`POST /api/auth/logout` отзывает текущую сессию (`204`).
`GET /api/users/me` возвращает `id`, `username`, `default_playlist_id`.
Сессии и ссылки используют 256 случайных бит; в БД хранятся только SHA-256-хеши
токенов. Пароли хешируются Argon2id (19 MiB, 2 прохода, 1 поток), по
[рекомендации OWASP](https://cheatsheetseries.owasp.org/cheatsheets/Password_Storage_Cheat_Sheet.html).
Для внешнего доступа используйте HTTPS и ограничение частоты запросов
регистрации/входа на reverse proxy. Регистрация сейчас открыта; приглашения
и восстановление пароля пока отсутствуют. Истёкшие сессии можно удалять вручную:
`DELETE FROM sessions WHERE expires_at <= now();`.

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
| `GET /api/playlists/:id` | Метаданные и список треков |
| `PUT /api/playlists/:id` | Заменить название, описание, теги и видимость; тело как при создании, ответ `204` |
| `PUT /api/playlists/:id/image` | Загрузить обложку байтами PNG/JPEG/WebP, до 5 MiB |
| `PUT /api/playlists/:id/tracks/:track_id` | Добавить свой трек в плейлист, повторный запрос безопасен (`204`) |
| `DELETE /api/playlists/:id/tracks/:track_id` | Убрать связь с плейлистом, сохранив трек и файл (`204`) |
| `PUT /api/playlists/:id/members/:user_id` | Назначить/изменить роль: `{"role":"viewer"}` или `{"role":"editor"}` (`204`) |
| `DELETE /api/playlists/:id/members/:user_id` | Отозвать доступ участника (`204`) |
| `POST /api/playlists/:id/share-link` | Создать или заменить ссылку для `unlisted`; ответ `{"path":"/api/shared/playlists/<token>"}` |
| `DELETE /api/playlists/:id/share-link` | Отозвать ссылку (`204`) |
| `GET /api/shared/playlists/:token` | Просмотр плейлиста по ссылке без входа |

`private` доступен владельцу и назначенным участникам. `public` доступен
на просмотр без входа по ID. `unlisted` доступен владельцу, участникам и
обладателям секретной ссылки; одного ID недостаточно. При уходе из `unlisted`
ссылка отзывается. Генерация новой ссылки также отзывает предыдущую.
Приватные и недоступные плейлисты возвращают `404`, чтобы не раскрывать наличие.

`viewer` может просматривать плейлист, `editor` — также изменять метаданные,
обложку и состав треков. Только владелец управляет участниками и ссылками.
Публичность и ссылка дают только просмотр. Дефолтный плейлист всегда приватный;
удалять из него связи с треками нельзя. Каждый новый трек добавляется туда,
а `playlist_ids` задаёт дополнительные плейлисты с правами владельца или редактора.

Обложки сохраняются в приватный бакет `uploads` под `playlists/<id>/<random>`.
Старые обложки остаются по сохранённым ключам `albums/<id>/<random>`;
миграция не перемещает объекты S3 и не меняет их ключи.
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
  "object_key": "tracks/UUID-трека/source",
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

Загрузка держит `SELECT ... FOR UPDATE NOWAIT` до завершения S3 и коммита БД.
После ошибки S3 транзакция откатывается, трек остаётся `pending`: PUT можно
повторить. Для `ready` и `streamed` повторная загрузка запрещена.
Загрузка использует сохранённые в БД бакет и ключ; смена `S3_BUCKET` влияет
только на новые треки. В ответе PUT возвращается фактически использованный
бакет, даже если он отличается от текущей конфигурации. Backend должен иметь
доступ к прежнему бакету на текущем `S3_ENDPOINT`.
Сохранённый путь также позволит удалять оставшиеся объекты при очистке
заброшенных `pending`-треков; сама задача очистки пока не реализована.

Схема `tracks/<id>/source` используется для новых записей. У ранее созданных
треков сохранённый `object_key` не меняется: PUT и HLS читают путь из БД.
Существующие объекты автоматически не перемещаются, миграция SQL не требуется.
Для переноса старого оригинала сначала нужно скопировать объект в новый ключ,
проверить копию и согласованно обновить `tracks.object_key`; одно изменение БД
без копирования файла нарушит доступ к оригиналу.

PostgreSQL и S3 не образуют общую транзакцию. При успешном S3 PUT и ошибке
обновления/коммита БД объект может остаться в бакете. Повторный PUT для
`pending` использует тот же ключ и заменяет такой объект. При потере ответа
коммита запись может уже стать `ready`; повторный PUT тогда вернёт `409`.

`GET /api/health` сохраняет прежний контракт и проверяет доступность процесса,
а не текущую готовность PostgreSQL или MinIO. Для воспроизведения доступны HLS-ручки ниже.

## HLS и несколько нод

Состояние трека: `pending` → `ready` → `streamed`. `ready` означает, что
загружен оригинал; `streamed` выставляется только после сохранения всех HLS
объектов. Состояние задачи хранится отдельно: `queued / processing / ready / failed`.
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
Состояние не начатой задачи — `preparation: null`. Номер отсутствующего
сегмента возвращает `404`. При ошибке подготовки трек остаётся `ready`,
задача становится `failed`, подробности записываются только в лог.

```powershell
curl.exe -X POST "http://127.0.0.1:8080/api/tracks/$track/hls" -H "Authorization: Bearer $token"
curl.exe "http://127.0.0.1:8080/api/tracks/$track/hls/status" -H "Authorization: Bearer $token"
curl.exe "http://127.0.0.1:8080/api/tracks/$track/hls/index.m3u8" -H "Authorization: Bearer $token"
```

Каждый GET проверяет доступ: владелец трека, участник связанного плейлиста,
публичный плейлист или действующая ссылка unlisted-плейлиста. Для приватного
воспроизведения HLS-клиент должен передавать Bearer в запросах манифеста
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

```sh
zig fmt --check build.zig src
zig build
zig build test --summary all
zig build test -Doptimize=ReleaseSafe --summary all
zig build -Doptimize=ReleaseSafe
```

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
случайно названный проект с пустой PostgreSQL, применяет миграции только в нём,
проверяет перенос старых связей, сессии, права, дефолтные плейлисты, изменение
метаданных, обложки, шаринг и откат создания трека, затем удаляет тестовые
контейнеры и volume. Пользовательская БД не затрагивается. S3 здесь заменён
локальным HTTP-сервером; для проверки настоящего MinIO используйте ручной сценарий.
Проверяются также ответы и логи при сбоях БД и S3: диагностические в Debug,
без указания инфраструктуры в Release.

С `--backend-image` скрипт дополнительно генерирует настоящий MP3, проверяет
AAC-сегменты через ffprobe, работу двух воркеров и отдельной HTTP-ноды,
восстановление истёкшей аренды и отказ публикации старой попытки, права
на сегменты, отзыв ссылки, ошибку конвертации и повторный запуск.
Выбирайте `--optimize`, соответствующий режиму сборки образа. SigV4 PUT и GET
проверяются тестовым S3-сервером независимо через Python hashlib/hmac.

Протокол S3 опирается на [PutObject](https://docs.aws.amazon.com/AmazonS3/latest/API/API_PutObject.html)
и [GetObject](https://docs.aws.amazon.com/AmazonS3/latest/API/API_GetObject.html)
и [AWS Signature V4](https://docs.aws.amazon.com/IAM/latest/UserGuide/reference_sigv-create-signed-request.html).
Драйвер PostgreSQL: [pg.zig](https://github.com/karlseguin/pg.zig).

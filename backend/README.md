# Backend Musica

Zig **0.16.0**, HTTP-сервер `httpz`, PostgreSQL через `pg.zig`, MinIO через
S3 PutObject с подписью AWS Signature V4. Обе Zig-зависимости закреплены
на конкретных коммитах для Zig 0.16.

## Архитектура

```text
src/
  main.zig                    Инициализация и регистрация фич
  config.zig                  Конфигурация из окружения
  app.zig                     Общие зависимости и HTTP-ошибки
  infrastructure/
    database.zig              Пул PostgreSQL
    s3.zig                    S3-клиент для MinIO
  features/
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

## Подготовка и конфигурация

Нужны PostgreSQL 14+ и MinIO с доступным S3 API. Создайте БД `musica`,
пользователя с правами на неё и приватный бакет **`uploads`** в MinIO.
`uploads` — имя бакета без ведущего `/`, объекты размещаются под `tracks/<uuid>`.
Backend не создаёт бакет и не применяет миграции при запуске.

Переменные описаны в [`.env.example`](.env.example). Файлы `.env` автоматически
не читаются: передайте значения через окружение процесса или ваш менеджер сервисов.
Обязательны `PGPASSWORD`, `S3_ACCESS_KEY_ID`, `S3_SECRET_ACCESS_KEY`.

| Переменная | По умолчанию |
| --- | --- |
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
S3-пользователю требуется разрешение `s3:PutObject` для `uploads/tracks/*`.
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
Если подключиться не удалось, запуск завершается с ошибкой. HTTP слушает
`127.0.0.1:8080`; для self-hosting используйте reverse proxy.
Задача VS Code `Backend: run` наследует окружение самого VS Code:
запустите редактор из терминала с уже заданными переменными.

## Ручные миграции

Выполните файлы **один раз, по порядку** из каталога `backend/`:

```sh
psql -h 127.0.0.1 -p 5432 -U musica -d musica -v ON_ERROR_STOP=1 -f migrations/001_create_albums.sql
psql -h 127.0.0.1 -p 5432 -U musica -d musica -v ON_ERROR_STOP=1 -f migrations/002_create_tracks.sql
```

В командах указаны стандартные параметры: замените их при необходимости.
Пароль `psql` запрашивает интерактивно либо читает из `PGPASSWORD`.
Каждый файл выполняется в транзакции. Повторное выполнение не предусмотрено;
учёт применённых миграций ведите вручную. `gen_random_uuid()` — встроенная
функция PostgreSQL, отдельное расширение не требуется.

Ручки альбомов пока нет. Создайте тестовый альбом SQL-запросом и сохраните ID:

```sql
INSERT INTO albums (title, artist)
VALUES ('Первый альбом', 'Исполнитель')
RETURNING id;
```

## Создание трека

`POST /api/tracks`, `Content-Type: application/json`:

```json
{
  "album_id": "11111111-1111-4111-8111-111111111111",
  "title": "Название трека",
  "artist": "Исполнитель"
}
```

`album_id` — UUID существующего альбома. `title` и `artist` — непустые UTF-8
строки до 256 символов; пробелы по краям удаляются. Лимит JSON — 16 KiB.
Ответ **201**:

```json
{"id":"UUID-созданного-трека","status":"pending"}
```

Сначала создаётся запись в БД без файла. Невалидный JSON или метаданные → `400`,
неизвестный альбом → `404`, неподходящий Content-Type → `415`.

## Загрузка файла

`PUT /api/tracks/:id/file`: передавайте **сами байты файла** в теле запроса.
Используйте `Content-Type: audio/mpeg`, `audio/flac`, `audio/wav`, `audio/ogg`,
`audio/aac`, `audio/mp4`, `audio/webm` или `application/octet-stream`.
Поддерживаются также `audio/x-flac`, `audio/x-wav`, `application/ogg`.
Multipart/form-data и сжатое Content-Encoding не принимаются.

Пример двух запросов в PowerShell:

```powershell
$albumId = 'UUID-из-RETURNING-id'
$metadata = @{ album_id = $albumId; title = 'Песня'; artist = 'Исполнитель' } | ConvertTo-Json
$track = Invoke-RestMethod -Method Post -Uri http://127.0.0.1:8080/api/tracks `
  -ContentType 'application/json; charset=utf-8' -Body ([Text.Encoding]::UTF8.GetBytes($metadata))
curl.exe --fail-with-body -X PUT "http://127.0.0.1:8080/api/tracks/$($track.id)/file" `
  -H 'Content-Type: audio/mpeg' --data-binary '@track.mp3'
```

Backend отправляет файл в MinIO как S3 PUT, затем сохраняет метаданные объекта
в PostgreSQL. Ответ **200**:

```json
{
  "id": "UUID-трека",
  "status": "ready",
  "bucket": "uploads",
  "object_key": "tracks/UUID-трека",
  "size_bytes": 123456,
  "content_type": "audio/mpeg"
}
```

Файл буферизуется в памяти, потоковая загрузка пока не реализована. Формат
аудио определяется переданным MIME; содержимое файла пока не декодируется.

| Код | Ситуация |
| --- | --- |
| `400` | Некорректный ID, пустое тело или невалидные метаданные |
| `404` | Альбом или трек не найден |
| `409` | Трек уже загружен или другой PUT сейчас загружает этот трек |
| `413` | Превышен лимит тела запроса |
| `415` | Неподдерживаемый Content-Type/Content-Encoding |
| `502` | Ошибка S3/MinIO |
| `503` | Ошибка PostgreSQL, включая отсутствие применённых миграций |
| `504` | S3-операция превысила 60 секунд |

Ошибки ручек возвращаются в форме `{"error":"код_ошибки"}`. Ошибка размера
тела, обнаруженная самим HTTP-сервером до маршрута, может иметь другой формат.

Загрузка держит `SELECT ... FOR UPDATE NOWAIT` до завершения S3 и коммита БД.
После ошибки S3 транзакция откатывается, трек остаётся `pending`: PUT можно
повторить. Для `ready` повторная загрузка запрещена.

PostgreSQL и S3 не образуют общую транзакцию. При успешном S3 PUT и ошибке
обновления/коммита БД объект может остаться в бакете. Повторный PUT для
`pending` использует тот же ключ и заменяет такой объект. При потере ответа
коммита запись может уже стать `ready`; повторный PUT тогда вернёт `409`.

`GET /api/health` сохраняет прежний контракт и проверяет доступность процесса,
а не текущую готовность PostgreSQL или MinIO. Авторизация и скачивание пока
не реализованы.

## Проверки

```sh
zig fmt --check build.zig src
zig build
zig build test --summary all
zig build -Doptimize=ReleaseSafe
```

Тесты проверяют валидацию и HTTP-ошибки, UTC-даты, подпись SigV4 на фиксированном
независимом примере, бинарный PUT, отказ хранилища и отмену зависшего запроса
на локальном тестовом сервере.
Они не требуют PostgreSQL или MinIO. Для сквозной проверки запустите оба сервиса,
примените миграции вручную, выполните два запроса выше и проверьте строку `tracks`
и объект в бакете `uploads`.

Протокол S3 опирается на [PutObject](https://docs.aws.amazon.com/AmazonS3/latest/API/API_PutObject.html)
и [AWS Signature V4](https://docs.aws.amazon.com/IAM/latest/UserGuide/reference_sigv-create-signed-request.html).
Драйвер PostgreSQL: [pg.zig](https://github.com/karlseguin/pg.zig).

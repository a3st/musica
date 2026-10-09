# Musica

Self-hosted музыкальный плеер: музыка и сервер остаются под вашим контролем.

Frontend — адаптивное PWA: плейлисты, поиск, HLS-плеер и загрузка музыки
с компьютера через перетаскивание файлов. На телефоне плейлисты открываются
в боковой панели, плеер остаётся внизу. Backend поддерживает пользователей
и сессии, плейлисты с ролями, PostgreSQL и MinIO, подготовку HLS через FFmpeg.
Описание интерфейса и проверки — в [frontend/README.md](frontend/README.md).

В медиатеке доступен **Импорт из Spotify**: выберите `Playlists.json` и/или
`YourLibrary.json` из выгрузки данных аккаунта. Backend создаёт треки и приватные
плейлисты, скачивает аудио отдельными jobs через yt-dlp и автоматически готовит HLS.
Требования и контракт — в [backend/README.md](backend/README.md#импорт-spotify).

## Структура

```text
frontend/             TypeScript + Vite, PWA
  src/                Клиентский код и стили
  public/             Иконки приложения
backend/              Zig 0.16.0 + http.zig
  src/main.zig        Инициализация и регистрация фич
  src/features/       auth, users, playlists, tracks, streaming, spotify_int, health
  src/infrastructure/ PostgreSQL, S3/MinIO и общая очередь jobs
  migrations/         SQL-миграции для ручного выполнения
  build.zig           Сборка и запуск
  build.zig.zon       Закреплённые зависимости
AGENTS.md             Инструкции по работе с кодом
```

## Требования

- Node.js 22.12+ (либо 20.19+) и npm — требования [Vite](https://vite.dev/guide/).
- Zig **0.16.0**.
- PostgreSQL 14+ и MinIO для backend. Настройка окружения, ручные миграции
  и HTTP-контракты описаны в [backend/README.md](backend/README.md).
- FFmpeg — для подготовки треков к воспроизведению; в Docker-образ уже включён.
- yt-dlp и Node.js 22+ на backend — для импорта Spotify; Docker-образ включает их.
- Интернет при первой установке npm- и Zig-зависимостей.

Backend использует [karlseguin/http.zig](https://github.com/karlseguin/http.zig),
который импортируется как `httpz`. Версия закреплена в `build.zig.zon`.
Используется [коммит `9b14af9`](https://github.com/karlseguin/http.zig/commit/9b14af98fde5e98abb9a8376fe02b42003e835bf)
для Zig 0.16; текущий `master` уже перешёл на Zig 0.17.

## Разработка

Для запуска backend, PostgreSQL и MinIO в Docker используйте
`docker-compose.yml` в корне проекта. Настройка `.env`, команды запуска и
ручного применения миграций — в [инструкции backend](backend/README.md#запуск-через-docker-compose).

Сначала настройте PostgreSQL, MinIO и переменные окружения по
[инструкции backend](backend/README.md), примените SQL-миграции вручную.
Затем запустите backend в первом терминале:

```sh
cd backend
zig build run
```

Во втором терминале запустите frontend:

```sh
cd frontend
npm ci
npm run dev
```

Откройте <http://localhost:5173>. Vite проксирует `/api/` на
`http://127.0.0.1:8080`, поэтому отдельная настройка CORS не требуется.
Backend слушает только loopback-интерфейс.

Зарегистрируйтесь в приложении: автоматически появится приватный плейлист
`Uploads`. Кнопка «Загрузить треки» доступна на ПК; после загрузки запускается
подготовка HLS. Удаление из `Uploads` удаляет трек из всей медиатеки и MinIO,
из остальных плейлистов — только связь. Оба действия требуют подтверждения.
После сброса БД вручную примените `backend/migrations/001_init.sql`.
Она создаёт таблицы приложения в схеме `musica`, а общую очередь — в `public.jobs`.

Проверка API:

```sh
curl http://127.0.0.1:8080/api/health
```

В PowerShell можно использовать `Invoke-RestMethod http://127.0.0.1:8080/api/health`.
Ожидаемый ответ: `{"status":"ok","service":"musica"}`.
Неизвестные маршруты возвращают `404` с `{"error":"not_found"}`.

## Сборка

Frontend (результат в `frontend/dist/`):

```sh
cd frontend
npm run build
npm run preview
```

Backend (результат в `backend/zig-out/bin/`):

```sh
cd backend
zig fmt --check build.zig src
zig build -Doptimize=ReleaseSafe
```

## Задачи VS Code

Откройте корень репозитория в VS Code. В `.vscode/tasks.json` настроены
задачи, доступные через **Terminal → Run Task**:

- `Frontend: install` — установка зависимостей через `npm ci` (перед первым запуском).
- `Backend: build` / `Frontend: build` — сборка выбранного подпроекта.
- `Backend: build ReleaseSafe` — оптимизированная сборка backend.
- `Backend: test` — все unit-тесты backend с итоговой сводкой.
- `Backend: run` / `Frontend: run` — запуск выбранного подпроекта.
- `Build: all` — параллельная сборка обоих подпроектов, также по **Ctrl+Shift+B**.
- `Run: all` — одновременный запуск backend и frontend в отдельных терминалах.

Остановка серверов: **Terminal → Terminate Task** либо **Ctrl+C** в их терминалах.
Zig и npm должны быть доступны в PATH; на Windows задачи используют `npm.cmd`.
Формат задач описан в [документации VS Code](https://code.visualstudio.com/docs/debugtest/tasks).

Панель **Testing → Run Test** настроена через `.vscode/settings.json`: вместо
`zig test <файл>` она использует `backend/build.zig` и передаёт имя выбранного
теста в `-Dtest-filter`. Так учитываются модули httpz/pg и остальные настройки
сборки. Для всего набора запускайте задачу `Backend: test`;
панель расширения обнаруживает тесты в открытых Zig-файлах.

## PWA и self-hosting

[vite-plugin-pwa](https://vite-pwa-org.netlify.app/guide/) генерирует манифест
и service worker при production-сборке. После первого открытия кешируется
оболочка приложения; API и музыка не кешируются. Обновление оболочки
применяется кнопкой «Доступна новая версия · Обновить». В режиме разработки service worker
отключён.

Для self-hosting разместите содержимое `frontend/dist/` на веб-сервере,
проксируйте `/api/` к backend и используйте один домен с HTTPS. Для клиентских
маршрутов предусмотрите fallback на `index.html`, кроме `/api/`.
Приложение рассчитано на размещение в корне домена. Установка PWA и service
worker требуют HTTPS либо localhost.
Для HTTPS включите `AUTH_COOKIE_SECURE=true` у backend. Reverse proxy должен
сохранять исходный `Host`: он проверяется при изменяющих запросах с cookie-сессией.

`npm run preview` служит для локальной проверки сборки, а не для production;
он не проксирует API. Для совместной проверки production-сборки и backend
используйте reverse proxy.

Храните музыку и изменяемые данные отдельно от исходников, например в `media/`
и `data/` в корне репозитория: эти каталоги исключены из Git. Загруженные
через API файлы backend хранит в приватном бакете MinIO из `S3_BUCKET`.

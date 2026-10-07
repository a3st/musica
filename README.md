# Musica

Self-hosted музыкальный плеер: музыка и сервер остаются под вашим контролем.

Frontend содержит стартовую PWA-оболочку. Backend поддерживает пользователей
и сессии, плейлисты с ролями и доступом по ссылке, создание треков в PostgreSQL
и загрузку файлов и обложек в MinIO. Воспроизведение и сканирование файлов
будут добавлены позднее.

## Структура

```text
frontend/             TypeScript + Vite, PWA
  src/                Клиентский код и стили
  public/             Иконки приложения
backend/              Zig 0.16.0 + http.zig
  src/main.zig        Инициализация и регистрация фич
  src/features/       Ручки и логика по фичам (health, tracks)
  src/infrastructure/ PostgreSQL и S3/MinIO
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
- `Backend: run` / `Frontend: run` — запуск выбранного подпроекта.
- `Build: all` — параллельная сборка обоих подпроектов, также по **Ctrl+Shift+B**.
- `Run: all` — одновременный запуск backend и frontend в отдельных терминалах.

Остановка серверов: **Terminal → Terminate Task** либо **Ctrl+C** в их терминалах.
Zig и npm должны быть доступны в PATH; на Windows задачи используют `npm.cmd`.
Формат задач описан в [документации VS Code](https://code.visualstudio.com/docs/debugtest/tasks).

## PWA и self-hosting

[vite-plugin-pwa](https://vite-pwa-org.netlify.app/guide/) генерирует манифест
и service worker при production-сборке. После первого открытия кешируется
оболочка приложения; API и музыка не кешируются. Обновление оболочки
применяется кнопкой «Обновить приложение». В режиме разработки service worker
отключён.

Для self-hosting разместите содержимое `frontend/dist/` на веб-сервере,
проксируйте `/api/` к backend и используйте один домен с HTTPS. Для клиентских
маршрутов предусмотрите fallback на `index.html`, кроме `/api/`.
Приложение рассчитано на размещение в корне домена. Установка PWA и service
worker требуют HTTPS либо localhost.

`npm run preview` служит для локальной проверки сборки, а не для production;
он не проксирует API. Для совместной проверки production-сборки и backend
используйте reverse proxy.

Храните музыку и изменяемые данные отдельно от исходников, например в `media/`
и `data/` в корне репозитория: эти каталоги исключены из Git. Загруженные
через API файлы backend хранит в бакете MinIO `uploads`.

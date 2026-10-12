<p align="center">
  <img src="frontend-app/public/icon.svg" width="96" height="96" alt="Логотип Musica">
</p>

<h1 align="center">Musica</h1>

<p align="center">
  Музыкальная библиотека и плеер на вашем сервере.
  <br>
  <strong>Self-hosted · PWA · Svelte · Zig</strong>
  <br>
  Версия <strong>0.4.1</strong>
</p>

<p align="center">
  <a href="README.md">English (en-US)</a> · <strong>Русский (ru-RU)</strong>
</p>

<p align="center">
  <a href="#возможности">Возможности</a> ·
  <a href="#быстрый-запуск">Быстрый запуск</a> ·
  <a href="#разработка">Разработка</a> ·
  <a href="#документация">Документация</a>
</p>

## Ваша музыка, ваш сервер

**Musica** — self-hosted музыкальный плеер для компьютера и телефона.
Загружайте музыку, собирайте плейлисты и слушайте свою библиотеку через браузер
или установленное PWA. Аудиофайлы хранятся в MinIO, данные библиотеки — в PostgreSQL.

Проект состоит из плеера **Musica Player**, интерфейса аккаунта и администрирования
**Musica Profile** и общего backend. Плеер поддерживает светлую и тёмную темы;
оба интерфейса доступны на русском и английском языках.

## Возможности

- **Музыкальная библиотека.** Загрузка файлов перетаскиванием, обложки треков,
  длительность и личный плейлист `Uploads`.
- **Плейлисты.** Обложки, описания, теги, приватный и публичный доступ,
  доступ по ссылке и роли просмотра или редактирования.
- **Воспроизведение.** HLS-плеер, очередь, перемешивание, эквалайзер
  и сохранение настроек громкости.
- **Поиск.** Поиск в доступной библиотеке; при отсутствии совпадений —
  поиск общих сервисных треков и результатов iTunes и Deezer.
- **Импорт Spotify.** Выбор плейлистов и треков из `Playlists.json` и
  `YourLibrary.json`, загрузка аудио через yt-dlp и подготовка к воспроизведению.
- **Профиль и администрирование.** Вход, регистрация при её включении,
  смена пароля и удаление аккаунта. Для администратора — управление
  пользователями, статистика хранилища и очистка неиспользуемых общих треков.
- **PWA.** Установка плеера на устройство и кеширование оболочки приложения.
  Авторизация, поиск и воспроизведение требуют подключения к серверу.

Личные загрузки принадлежат пользователю. Общие треки из Web и Spotify
хранятся у сервисной учётной записи: их можно слушать без добавления в библиотеку
или сохранить в свои плейлисты. Удаление личного трека из `Uploads` удаляет
сам трек; удаление общего трека убирает только связь с вашей библиотекой.

## Быстрый запуск

Для запуска нужны Docker с Compose и доступ к интернету для первой сборки.
[docker-compose.yml](docker-compose.yml) запускает PostgreSQL, MinIO, backend
и nginx с обеими frontend-сборками.

### 1. Настройте окружение

Скопируйте [.env.docker.example](.env.docker.example) в `.env` в корне проекта:

```sh
cp .env.docker.example .env
```

В PowerShell используйте `Copy-Item .env.docker.example .env`.
Задайте пароли PostgreSQL и MinIO. Перед первым запуском backend
раскомментируйте и заполните обе переменные `BOOTSTRAP_ADMIN_USERNAME` и
`BOOTSTRAP_ADMIN_PASSWORD` для создания администратора.

По примеру nginx слушает `127.0.0.1:8080` за внешним HTTPS reverse proxy.
Для локального входа через HTTP установите `AUTH_COOKIE_SECURE=false`;
для HTTPS оставьте `true`. Внешний proxy должен сохранять исходный `Host`
и направлять весь сайт, включая `/profile/` и `/api/`, в nginx.

Для скачивания аудио через proxy раскомментируйте `YTDLP_PROXY` в `.env`
и укажите HTTP/HTTPS или SOCKS5 URL, доступный из контейнера backend.
Настройка применяется к скачиваниям yt-dlp для Web и Spotify.

### 2. Соберите образы и подготовьте хранилища

```sh
docker compose build
docker compose up -d postgres minio minio-init
```

Дождитесь готовности PostgreSQL и MinIO. `minio-init` создаст бакет из
`S3_BUCKET`, если его ещё нет.

### 3. Примените начальную схему

Выполните миграцию **вручную, один раз, только для пустой БД**:

```sh
docker compose exec postgres sh -c 'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -v ON_ERROR_STOP=1 -f /migrations/001_init.sql'
```

Миграции не применяются автоматически. Все таблицы приложения находятся
в схеме `musica`, общая очередь задач — в `public.jobs`.

### 4. Запустите Musica

```sh
docker compose up -d --wait
```

| Интерфейс | Локальный адрес |
| --- | --- |
| Плеер | <http://localhost:8080/> |
| Профиль и администрирование | <http://localhost:8080/profile/> |
| Проверка API | <http://localhost:8080/api/health> |

Войдите с учётными данными стартового администратора. После создания аккаунта
переменные `BOOTSTRAP_ADMIN_*` можно удалить из окружения.

По умолчанию на хосте опубликован только nginx. PostgreSQL, MinIO и backend
общаются внутри Docker-сети. Для локального подключения к БД или MinIO
раскомментируйте нужные порты в Compose и переменные в `.env`.
Имя проекта `musica` и volumes `postgres-data`, `minio-data` сохраняются.

<details>
<summary>Команды обслуживания</summary>

```sh
docker compose config --quiet
docker compose ps
docker compose logs -f backend nginx
docker compose exec postgres psql -U musica -d musica
docker compose down
```

В команде `psql` замените `musica` на свои `DB_USER` и `DB_NAME`, если они отличаются.
`docker compose down` сохраняет volumes с данными.
После сборки образа nginx его маршруты можно проверить командой
`python docker/tests/nginx_smoke.py`; тест использует отдельный временный контейнер.

</details>

## Разработка

### Требования

| Компонент | Требование |
| --- | --- |
| Плеер и профиль | Node.js 22.12+ и npm |
| Backend | Zig **0.16.0**, Python 3.10+, PostgreSQL 14+ и MinIO |
| Обработка аудио | FFmpeg и ffprobe |
| Скачивание аудио | yt-dlp и Node.js 22+ |

Docker-образ backend уже включает инструменты обработки и скачивания аудио.
HTTP-сервер использует [http.zig](https://github.com/karlseguin/http.zig)
как модуль `httpz`; зависимости Zig закреплены в
[build.zig.zon](backend/build.zig.zon).

Настройте хранилища, окружение backend и примените начальную миграцию по
[инструкции backend](backend/DOCUMENTATION.md). Затем запустите каждый подпроект
в отдельном терминале:

| Подпроект | Каталог | Команды | Адрес |
| --- | --- | --- | --- |
| Backend | `backend/` | `python3 build.py run` | `http://localhost:8080/api/` |
| Плеер | `frontend-app/` | `npm ci`, затем `npm run dev` | `http://localhost:5173/` |
| Профиль | `frontend-admin/` | `npm ci`, затем `npm run dev` | `http://localhost:5174/profile/` |

Vite проксирует `/api/` на backend. Открывайте оба интерфейса через один hostname,
например `localhost`, чтобы использовать общую cookie-сессию. В Windows при
ограничении запуска `npm.ps1` используйте `npm.cmd`.

В VS Code доступны задачи сборки, запуска и тестов в
[tasks.json](.vscode/tasks.json), а также конфигурация отладки backend в
[launch.json](.vscode/launch.json).

### Сборка и проверки

В каждом frontend выполните `npm run build` и `npm run format:check`.
Сборка включает `svelte-check`, результат находится в `dist/`.
Дополнительные проверки описаны в `DOCUMENTATION.md` соответствующего подпроекта.

Для backend из `backend/`:

```sh
zig fmt --check build.zig src
python3 build.py test
python3 build.py -Doptimize=ReleaseSafe
```

Результат сборки backend находится в `backend/zig-out/bin/`.
Обёртка скачивает недостающие зависимости в `backend/3rdparty/`, затем
собирает из этого каталога без скачивания. Кеши компиляции остаются отдельно.
В Windows используйте `python` вместо `python3`. Для подготовки пакетов без
сборки выполните `python3 build.py --deps-only`.
Миграции и интеграционные тесты не следует выполнять на рабочей БД.

## Структура проекта

```text
frontend-app/          Musica Player: Svelte 5, TypeScript, Vite, PWA
frontend-admin/        Musica Profile: аккаунт и администрирование
backend/
  src/features/       HTTP-маршруты, модели и бизнес-операции
  src/infrastructure/ БД, S3, каталог, инструменты обработки и jobs
  src/helpers/        Общие вспомогательные функции
  migrations/         Начальная SQL-схема для ручного применения
  tests/              Интеграционные проверки
docker/                MinIO, nginx и проверки развёртывания
docker-compose.yml     Запуск всех компонентов
AGENTS.md              Правила архитектуры и оформления кода
```

## Документация

- [Backend](backend/DOCUMENTATION.md) — конфигурация, API, миграции, обработка аудио и jobs.
- [Musica Player](frontend-app/DOCUMENTATION.md) — интерфейс, PWA, настройки и проверки.
- [Musica Profile](frontend-admin/DOCUMENTATION.md) — авторизация, профиль и администрирование.
- [Окружение Docker](.env.docker.example) — параметры развёртывания.
- [Окружение backend](backend/.env.example) — настройки для запуска вне Docker.
- [Правила проекта](AGENTS.md) — архитектура и стиль кода.

В production размещайте плеер по `/`, профиль по `/profile/`, API по `/api/`
на одном HTTPS-домене. Вход и регистрация выполняются в профиле, после входа
пользователь возвращается в плеер. Service worker кеширует оболочку плеера,
исключая API, аудио и навигацию профиля. `npm run preview` предназначен
для проверки сборки и не заменяет production reverse proxy.

## Лицензия

Copyright © 2026 Dmitriy Lukovenko.

Musica распространяется под **GNU General Public License v3.0**
(`GPL-3.0-only`). Полный текст условий — в [LICENSE](LICENSE).
Сторонние зависимости сохраняют собственные лицензии.

## Участие в разработке

Сообщения об ошибках и предложения можно оставлять в
[Issues](https://github.com/a3st/musica/issues), изменения — предлагать через
[Pull Requests](https://github.com/a3st/musica/pulls).
Для ошибки приложите шаги воспроизведения, версию приложения и логи без секретов.
Перед изменениями ознакомьтесь с [AGENTS.md](AGENTS.md) и выполните проверки
затронутого подпроекта.

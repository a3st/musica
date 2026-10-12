<p align="center">
  <img src="frontend-app/public/icon.svg" width="96" height="96" alt="Musica logo">
</p>

<h1 align="center">Musica</h1>

<p align="center">
  Your music library and player, hosted on your server.
  <br>
  <strong>Self-hosted · PWA · Svelte · Zig</strong>
  <br>
  Version <strong>0.4.1</strong>
</p>

<p align="center">
  <strong>English (en-US)</strong> · <a href="README.ru-RU.md">Русский (ru-RU)</a>
</p>

<p align="center">
  <a href="#features">Features</a> ·
  <a href="#quick-start">Quick start</a> ·
  <a href="#development">Development</a> ·
  <a href="#documentation">Documentation</a>
</p>

## Your music, your server

**Musica** is a self-hosted music player for desktop and mobile devices.
Upload music, organize playlists, and listen to your library in a browser
or an installed PWA. Audio files are stored in MinIO, and library data in PostgreSQL.

The project includes **Musica Player**, **Musica Profile** for account management
and administration, and a shared backend. The player supports light and dark
themes; both interfaces are available in English and Russian.

## Features

- **Music library.** Drag-and-drop uploads, track artwork, duration metadata,
  and a personal `Uploads` playlist.
- **Playlists.** Covers, descriptions, tags, private and public access,
  sharing by link, and viewer or editor roles.
- **Playback.** An HLS player, queue, shuffle, equalizer,
  and saved volume settings.
- **Search.** Search your accessible library first; when no matches are found,
  search shared service tracks and the iTunes and Deezer catalogs.
- **Spotify import.** Select playlists and tracks from `Playlists.json` and
  `YourLibrary.json`, download audio through yt-dlp, and prepare it for playback.
- **Accounts and administration.** Sign in, register when enabled, change your
  password, and delete your account. Administrators can manage users, view storage
  statistics, and remove unused shared tracks.
- **PWA.** Install the player on your device and cache the application shell.
  Authentication, search, and playback require a connection to the server.

Personal uploads belong to the user. Shared tracks from Web and Spotify
are owned by a service account: you can play them without adding them to your
library, or save them to your playlists. Removing a personal track from `Uploads`
deletes the track itself; removing a shared track only removes its library link.

## Quick start

You need Docker with Compose and an internet connection for the initial build.
[docker-compose.yml](docker-compose.yml) runs PostgreSQL, MinIO, the backend,
and nginx serving both frontend builds.

### 1. Configure the environment

Copy [.env.docker.example](.env.docker.example) to `.env` in the repository root:

```sh
cp .env.docker.example .env
```

In PowerShell, use `Copy-Item .env.docker.example .env`.
Set the PostgreSQL and MinIO passwords. Before starting the backend for the
first time, uncomment and set both `BOOTSTRAP_ADMIN_USERNAME` and
`BOOTSTRAP_ADMIN_PASSWORD` to create an administrator account.

The example configures nginx to listen on `127.0.0.1:8080` behind an external
HTTPS reverse proxy. For local sign-in over HTTP, set `AUTH_COOKIE_SECURE=false`;
for HTTPS, keep it `true`. The external proxy must preserve the original `Host`
and forward the entire site, including `/profile/` and `/api/`, to nginx.

To download audio through a proxy, uncomment `YTDLP_PROXY` in `.env` and set
an HTTP/HTTPS or SOCKS5 proxy URL reachable from the backend container.
This setting applies to yt-dlp downloads for Web and Spotify.

### 2. Build the images and start storage services

```sh
docker compose build
docker compose up -d postgres minio minio-init
```

Wait for PostgreSQL and MinIO to become healthy. `minio-init` creates the bucket
specified by `S3_BUCKET` if it does not already exist.

### 3. Apply the initial schema

Run the migration **manually, once, against an empty database only**:

```sh
docker compose exec postgres sh -c 'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -v ON_ERROR_STOP=1 -f /migrations/001_init.sql'
```

Migrations are not applied automatically. Application tables use the `musica`
schema, and the shared job queue is stored in `public.jobs`.

### 4. Start Musica

```sh
docker compose up -d --wait
```

| Interface | Local address |
| --- | --- |
| Player | <http://localhost:8080/> |
| Profile and administration | <http://localhost:8080/profile/> |
| API health check | <http://localhost:8080/api/health> |

Sign in with the bootstrap administrator credentials. Once the account has
been created, you can remove the `BOOTSTRAP_ADMIN_*` variables from the environment.

Only nginx publishes a host port by default. PostgreSQL, MinIO, and the backend
communicate over the Docker network. To access the database or MinIO locally,
uncomment the relevant port mappings in Compose and variables in `.env`.
The project name `musica` and volumes `postgres-data` and `minio-data` are preserved.

<details>
<summary>Maintenance commands</summary>

```sh
docker compose config --quiet
docker compose ps
docker compose logs -f backend nginx
docker compose exec postgres psql -U musica -d musica
docker compose down
```

In the `psql` command, replace `musica` with your `DB_USER` and `DB_NAME` if they differ.
`docker compose down` preserves the data volumes.
After building the nginx image, check its routes with
`python docker/tests/nginx_smoke.py`; the test uses a separate temporary container.

</details>

## Development

### Requirements

| Component | Requirement |
| --- | --- |
| Player and profile | Node.js 22.12+ and npm |
| Backend | Zig **0.16.0**, Python 3.10+, PostgreSQL 14+, and MinIO |
| Audio processing | FFmpeg and ffprobe |
| Audio downloads | yt-dlp and Node.js 22+ |

The backend Docker image already includes the audio processing and download tools.
The HTTP server uses [http.zig](https://github.com/karlseguin/http.zig)
as the `httpz` module; Zig dependencies are pinned in
[build.zig.zon](backend/build.zig.zon).

Configure storage, set the backend environment, and apply the initial migration
following the [backend documentation](backend/DOCUMENTATION.md) (in Russian).
Then start each subproject in a separate terminal:

| Subproject | Directory | Commands | Address |
| --- | --- | --- | --- |
| Backend | `backend/` | `python3 build.py run` | `http://localhost:8080/api/` |
| Player | `frontend-app/` | `npm ci`, then `npm run dev` | `http://localhost:5173/` |
| Profile | `frontend-admin/` | `npm ci`, then `npm run dev` | `http://localhost:5174/profile/` |

Vite proxies `/api/` to the backend. Open both interfaces using the same hostname,
such as `localhost`, to share the session cookie. On Windows, use `npm.cmd`
if execution of `npm.ps1` is restricted.

VS Code build, run, and test tasks are available in
[tasks.json](.vscode/tasks.json), with backend debugging configured in
[launch.json](.vscode/launch.json).

### Building and checking

Run `npm run build` and `npm run format:check` in each frontend directory.
The build includes `svelte-check` and writes its output to `dist/`.
Additional checks are described in each subproject's `DOCUMENTATION.md`.

For the backend, run these commands from `backend/`:

```sh
zig fmt --check build.zig src
python3 build.py test
python3 build.py -Doptimize=ReleaseSafe
```

Backend build output is written to `backend/zig-out/bin/`.
The wrapper downloads missing dependencies into `backend/3rdparty/`, then
builds from that package cache without fetching. Compilation caches stay separate.
On Windows, use `python` instead of `python3`. To prepare packages without
building, run `python3 build.py --deps-only`.
Do not run migrations or integration tests against your production database.

## Project structure

```text
frontend-app/          Musica Player: Svelte 5, TypeScript, Vite, PWA
frontend-admin/        Musica Profile: accounts and administration
backend/
  src/features/       HTTP routes, models, and business operations
  src/infrastructure/ Database, S3, catalog, media tools, and jobs
  src/helpers/        Shared helpers
  migrations/         Initial SQL schema, applied manually
  tests/              Integration checks
docker/                MinIO, nginx, and deployment checks
docker-compose.yml     All application services
AGENTS.md              Architecture and code style guidelines
```

## Documentation

Detailed subproject documentation and configuration comments are currently in Russian.

- [Backend](backend/DOCUMENTATION.md) — configuration, API, migrations, audio processing, and jobs.
- [Musica Player](frontend-app/DOCUMENTATION.md) — interface, PWA, settings, and checks.
- [Musica Profile](frontend-admin/DOCUMENTATION.md) — authentication, profile, and administration.
- [Docker environment](.env.docker.example) — deployment settings.
- [Backend environment](backend/.env.example) — settings for running outside Docker.
- [Project guidelines](AGENTS.md) — architecture and code style.

In production, serve the player at `/`, the profile at `/profile/`, and the API
at `/api/` on a single HTTPS domain. Sign-in and registration take place in the
profile interface, which returns the user to the player after authentication.
The service worker caches the player shell, excluding API responses, audio,
and profile navigation. `npm run preview` is for checking builds and does not
replace a production reverse proxy.

## License

Copyright © 2026 Dmitriy Lukovenko.

Musica is licensed under the **GNU General Public License v3.0**
(`GPL-3.0-only`). See [LICENSE](LICENSE) for the full terms.
Third-party dependencies retain their respective licenses.

## Contributing

Report bugs and suggest improvements through
[Issues](https://github.com/a3st/musica/issues), or submit changes through
[Pull Requests](https://github.com/a3st/musica/pulls).
Include reproduction steps, the application version, and logs without secrets
when reporting a bug. Before making changes, read [AGENTS.md](AGENTS.md)
and run the checks for the affected subproject.

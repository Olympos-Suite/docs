---
title: "Installation"
description: "Run Psyche with Docker Compose or bare-metal pnpm, and complete the first-run admin setup."
section: "User Guide"
order: 10
---

Psyche ships as **one image running two processes**: a Next.js web app on port `3000` and a Fastify API on port `3001`. Only the web port is published (`9698:3000`); the browser's `/api/*` requests are proxied to the container-internal API by a single catch-all route. You never expose the API port yourself.

## Prerequisites

- **A TMDB API key** — either a v3 API key (32 hex characters) or a v4 read-access token (JWT starting with `eyJ`). Get one from [themoviedb.org](https://www.themoviedb.org/settings/api). Psyche has exactly one metadata source; without a key, discovery and search fail fast with guidance.
- **Docker** (recommended), or **Node.js ≥ 24 and pnpm 12.7.0** for a bare-metal run.
- **A torrent client** — qBittorrent or Transmission, reachable from Psyche. Required for grabbing.
- **An indexer** — a Prowlarr instance or a Torznab/Newznab endpoint. Required for release search; without one, searches return empty results.

The TMDB key, indexers, and torrent clients are all configured after boot as [service connections](./configuration#service-connections) in the Settings UI — not through environment variables.

## Docker Compose

The repository ships this `docker-compose.yml`:

```yaml
services:
  psyche:
    build: .
    image: psyche:latest
    container_name: psyche
    restart: unless-stopped
    ports:
      - '9698:3000'      # host → web only; the API stays container-internal
    environment:
      - PUID=1000
      - PGID=1000
      - TZ=UTC
    volumes:
      - ./volumes/config:/config     # DB + settings + session secret (backup this!)
      - ./volumes/data:/data         # app data (artwork + model caches)
      - /mnt/media/tv:/media/tv      # TV library root
      - /mnt/media/movies:/media/movies  # movie library root
      - /mnt/media/downloads:/media/downloads  # torrent clients' downloads
```

Adjust the host paths to your library layout, then:

```bash
docker compose up -d --build
```

Key points:

- **Volumes.** `/config` holds `psyche.sqlite`, the settings store, and the session secret — it is the **only volume that needs backing up**. `/data` holds regenerable caches (TMDB artwork, cross-encoder models). The three `/media/*` mounts are the standard library layout; the default settings point at them.
- **User drop.** The entrypoint starts as root, creates an app group/user from `PGID`/`PUID`, chowns `/config` and `/data` recursively (media mount points are chowned but never rewritten recursively — host library permissions stay yours), then drops privileges via `gosu`. The runtime never runs as root. Match `PUID`/`PGID` to the owner of your mounted directories.
- **Supervisor.** One container runs both processes (`next start` + the compiled API). If either dies, the container exits and the restart policy brings it back.
- **Healthcheck.** Defined in the image: `curl -fsS http://localhost:3000/api/health` every 30 s (5 s timeout, 40 s start period, 3 retries).

## First run

1. Open `http://localhost:9698`. With no admin account yet, the app routes you to `/setup`.
2. Create the admin account (username + password, stored bcrypt-hashed). Psyche is single-admin; there is no multi-user or request/approval layer.
3. On first boot the server also generates a persistent session secret at `/config/session.secret` (mode `0600`), seeds setting defaults, and seeds the four default [quality profiles](./quality-profiles) — but only into an empty profiles table.
4. In **Settings → Services**, add your TMDB connection, at least one indexer, and a torrent client. Use the built-in test probe before saving. See [Configuration](./configuration#service-connections).

> [!IMPORTANT]
> Restarts never log you out: sessions are SQLite-backed and the secret persists in `/config`. If `/config` is unwritable, Psyche falls back to an **ephemeral** secret with a loud warning — every restart then logs all users out. Fix the mount permissions.

## Verify

```bash
curl http://localhost:9698/api/health
```

Expected: `{"success":true,"data":{"status":"ok","uptime":...}}`. The health route is public (no auth). Then sign in and check **Settings → Services** — each connection's test result should be `ok: true`.

## Environment variables

Bootstrap-only: ports and paths. Everything else lives in the [settings store](./configuration).

| Variable | Default | Purpose |
|----------|---------|---------|
| `PSYCHE_CONFIG_DIR` | `/config` | Config directory: SQLite DB, settings, session secret, backups. |
| `PSYCHE_DATA_DIR` | `/data` | App data: artwork cache (`metadata/artwork`), cross-encoder model cache. |
| `PSYCHE_DATABASE_PATH` | `<configDir>/psyche.sqlite` | Database file override; always lives under the config dir by default. |
| `PORT` | `3001` | API listen port (container-internal). |
| `HOST` | `0.0.0.0` | API listen address. |
| `WEB_PORT` / `API_PORT` | `3000` / `3001` | Image-level port pair consumed by the supervisor. |
| `PSYCHE_API_ORIGIN` | `http://localhost:3001` | Upstream the web proxy forwards `/api/*` to. |
| `SESSION_SECRET` | — | Optional override, **≥ 32 characters**. Always wins over the file; set-but-short refuses to boot. |
| `PUID` / `PGID` | `1000` / `1000` | Docker only: user/group the entrypoint drops to. |
| `TZ` | `UTC` | Container timezone. |
| `NODE_ENV` | `development` | `production` in the image; switches logs from pretty to structured JSON. |
| `LOG_LEVEL` | `info` | Boot-time log level fallback; the `logging.level` setting takes over once the DB is up. |

## Bare metal (pnpm)

Requires Node ≥ 24 and pnpm 12.7.0 (pinned via `packageManager`; corepack is avoided for determinism). From the repository root:

```bash
pnpm install          # better-sqlite3 native build is allow-listed in pnpm-workspace.yaml
pnpm dev              # Turborepo: API via tsx watch + Next.js dev server
```

| Command | What it does |
|---------|--------------|
| `pnpm dev` | Run web + API from source with watch mode. |
| `pnpm build` | Compile all packages (server `tsc` → `dist/`, web `next build`). |
| `pnpm test` | Vitest suites across the monorepo. |
| `pnpm typecheck` / `pnpm lint` | `tsc` and ESLint 9 (layering rules included). |

For production, run the two compiled processes yourself: `node apps/server/dist/index.js` (API) and `next start -p 3000` in `apps/web` (web). Point the defaults at writable directories first:

```bash
export PSYCHE_CONFIG_DIR=$HOME/.config/psyche
export PSYCHE_DATA_DIR=$HOME/.local/share/psyche
export NODE_ENV=production
```

Without overrides the server expects `/config` and `/data` to exist and be writable. Migrations apply automatically on every boot — a plain start is enough. See [Testing](./testing) for the full command and CI reference.
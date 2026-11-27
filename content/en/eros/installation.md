---
title: "Installation"
description: "Run Eros with the bundled Docker Compose stack or bare-metal pnpm, and complete the first-run admin setup."
section: "User Guide"
order: 10
---

Eros ships as **one image running two processes**: a Next.js web app on port `3000` and a Fastify API on port `3001`. Only the web port is published (`9697:3000`); the browser's `/api/*` requests are proxied to the container-internal API by a single catch-all route handler. You never expose the API port yourself. The bundled `docker-compose.yml` also brings up qBittorrent, Prowlarr, and Jellyfin so a fresh host has the whole stack.

## Prerequisites

- **Docker** (recommended), or **Node.js ≥ 24 and pnpm 12.7.0** for a bare-metal run (pinned via `packageManager`).
- **An indexer** — Prowlarr, Jackett, or any Torznab/Newznab endpoint. Required for search; the compose stack includes Prowlarr.
- **A torrent client** — qBittorrent or Transmission, reachable from Eros. Required for grabbing; the compose stack includes qBittorrent.
- **TPDB / StashDB API keys** — optional. Without a metadata provider, downloads still work but scenes stay `unmapped` (no metadata).

Indexers, clients, and metadata providers are all configured after boot as [service connections](./configuration) in the Settings UI — not through environment variables.

## Docker Compose

The repository's `docker-compose.yml` defines four services; the Eros service is:

```yaml
services:
  eros:
    build:
      context: .
      args:
        NEXT_PUBLIC_QBITTORRENT_DEFAULT_URL: http://qbittorrent:8180
        NEXT_PUBLIC_PROWLARR_DEFAULT_URL: http://prowlarr:9696
    image: eros:latest
    container_name: eros
    init: true
    ports:
      - "9697:3000"        # host → web only; the API stays container-internal
    environment:
      - SESSION_SECRET=${SESSION_SECRET:-}   # empty → generated once, persisted
      - DB_PATH=/config/eros.db
      - PUID=${PUID:-1000}
      - PGID=${PGID:-1000}
    volumes:
      - ${APPDATA:-./data}/eros/config:/config            # DB + session secret + backups
      - ${APPDATA:-./data}/eros/db:/data                  # legacy DB location (empty on new installs)
      - ${APPDATA:-./data}/eros/cross-encoder:/cross-encoder  # similarity model cache
      - ${DOWNLOADS:-./data/downloads}:/downloads         # shared with qBittorrent
      - ${EROS_MEDIA:-./data/media/adult}:/media          # organized output
    depends_on:
      qbittorrent: { condition: service_healthy }
      prowlarr: { condition: service_healthy }
    restart: unless-stopped
```

The companion services publish qBittorrent on `8180` (Web UI, plus `6881` TCP/UDP), Prowlarr on `9696`, and Jellyfin on `8096`. Jellyfin mounts `${JELLYFIN_MEDIA:-./data/media}` — the parent of Eros's `/media` output — so organized scenes appear in its library without extra wiring. Copy `.env.example` to `.env` to adjust the bind-mount roots (`APPDATA`, `DOWNLOADS`, `EROS_MEDIA`, `JELLYFIN_MEDIA`) and `PUID`/`PGID`, then:

```bash
docker compose up -d
```

Key points:

- **Volumes.** `/config` holds `eros.db`, the session secret, and `backups/` — it is the **only volume that needs backing up**. `/data` is kept solely for legacy migration; `/cross-encoder` caches the similarity model (regenerable). `/downloads` must be the same directory your torrent client writes to; `/media` is where organized scenes land.
- **User drop.** The entrypoint starts as root, resolves or creates a group/user from `PGID`/`PUID`, and fixes ownership of the mount points — recursively only when ownership actually differs, so boots stay cheap on large libraries. It also reads the `paths` setting from the database and creates/chowns any custom download/storage paths you configured, then drops privileges via `gosu`. The runtime never runs as root.
- **Supervisor.** `docker/supervisor.mjs` spawns both processes (`next start` + the compiled `node dist/index.js`). If either dies, the supervisor exits non-zero and the restart policy brings the container back. Shutdown signals are forwarded with a 10 s grace period (`SHUTDOWN_GRACE_MS`).
- **Healthcheck.** Defined in compose: a Node one-liner fetches both `http://localhost:3001/api/health` and `http://localhost:3000/` every 30 s (10 s timeout, 40 s start period, 3 retries).
- **Build args.** The two `NEXT_PUBLIC_*` args are inlined into the web bundle at build time and pre-fill the qBittorrent/Prowlarr URL presets in Settings → Services.

> [!IMPORTANT]
> **Upgrading an old install?** Application state moved from `/data` to `/config`, and there is **no automatic migration** — the move is manual. Before upgrading: `docker compose down`, then move the database files — `mv ./data/eros/db/eros.db* ./data/eros/config/` (including `eros.db-wal` / `eros.db-shm` if present) — then `docker compose up -d`. Compose keeps the legacy `/data` mount for exactly this transition; new installs leave it empty, and everything is created under `/config` automatically.

## First run

1. Open `http://localhost:9697`. With no admin account yet, the app routes you to `/setup`.
2. Create the admin account: username ≥ 3 characters; password ≥ 8 characters with at least one uppercase letter, one lowercase letter, and one number (stored bcrypt-hashed). Eros is single-admin; setup can only run once.
3. Until setup completes, every API route except the setup/status/health endpoints and `/api/docs` answers `503 SETUP_REQUIRED`.
4. On first boot the server also seeds 45 setting defaults and the four default [quality profiles](./quality-profiles) — **HD 1080p** is the default profile — only into an empty profiles table, ensures a `/downloads` download path and a `/media` storage path exist in the `paths` setting, and generates a persistent session secret at `/config/session.secret` (mode `0600`).
5. In **Settings → Services**, add an indexer (Prowlarr at `http://prowlarr:9696` in the compose network) and a torrent client (qBittorrent at `http://qbittorrent:8180`), and test each connection. Optionally add TPDB/StashDB credentials for enrichment. See [Configuration](./configuration).

## Verify

```bash
curl http://localhost:9697/api/health
```

Expected: `{"status":"ok","timestamp":"..."}`. The health route is public (no auth, no setup gate). Then sign in and check **Settings → Services** — each connection's test should report success.

> [!NOTE]
> Sessions are cookie-based (24 h rolling expiry) with an **in-memory** session store: restarting the server signs users out because session state lives in memory, not on disk. Your account is unaffected — the persisted secret only keeps cookie signing stable — so you simply log in again. The secret resolution order is `SESSION_SECRET` env (≥ 32 characters, always wins) → `/config/session.secret` → an ephemeral secret with a loud warning when `/config` is unwritable. A too-short `SESSION_SECRET` is ignored with a warning, not fatal.

## Environment variables

Bootstrap-only: ports and paths. Everything else lives in the [settings store](./configuration).

| Variable | Default | Purpose |
|----------|---------|---------|
| `DB_PATH` | `/config/eros.db` | SQLite database file. Its directory is also the default app-data root. |
| `PORT` | `3001` | API listen port (container-internal); the host is fixed to `0.0.0.0`. |
| `SESSION_SECRET` | — (empty) | Optional override, ≥ 32 characters. Otherwise the secret is read/generated at `/config/session.secret`. |
| `DATA_DIR` | directory of `DB_PATH` | App-data root: local image cache (`images/`), hover preview frames (`previews/`). |
| `BACKUP_DIR` | `/config/backups` | Database backup snapshots. |
| `API_URL` | `http://localhost:3001` | Upstream the web app's `/api` proxy forwards to (web process). |
| `NODE_ENV` | `development` | `production` in the image; switches logs from pretty to structured JSON. |
| `PUID` / `PGID` | `1000` / `1000` | Docker only: user/group the entrypoint drops to. Match your mounted directories' owner. |
| `DISABLE_CROSS_ENCODER` | unset | Set to `1` to disable the cross-encoder model (text similarity only). |
| `CORS_ORIGINS` | unset | Comma-separated explicit origin allowlist; without it, private-network origins are allowed. |
| `NEXT_PUBLIC_QBITTORRENT_DEFAULT_URL` | `http://localhost:8080` | Build-time UI preset for the qBittorrent URL (compose sets `http://qbittorrent:8180`). |
| `NEXT_PUBLIC_PROWLARR_DEFAULT_URL` | `http://localhost:9696` | Build-time UI preset for the Prowlarr URL (compose sets `http://prowlarr:9696`). |

## Bare metal (pnpm)

Requires Node ≥ 24 and pnpm 12.7.0. From the repository root:

```bash
corepack enable
pnpm install
pnpm dev        # web on :3000, API on :3001 (Turborepo)
```

| Command | What it does |
|---------|--------------|
| `pnpm dev` | Run web + API from source (`next dev` + `tsx` watch). |
| `pnpm build` | Compile all packages (server `tsc` → `dist/`, web `next build`). |
| `pnpm test` | Vitest suites across the monorepo (`pnpm --filter @repo/server test` for the server alone). |
| `pnpm typecheck` / `pnpm lint` | `tsc` and ESLint (layering rules included). |

For production, run the two compiled processes yourself: `node apps/server/dist/index.js` (API) and `pnpm --filter @repo/web start` (web, `next start`). Point the defaults at writable locations first — without overrides the server expects `/config` to exist:

```bash
export DB_PATH=$HOME/.config/eros/eros.db
export BACKUP_DIR=$HOME/.config/eros/backups
export NODE_ENV=production
```

`DATA_DIR` defaults to the database's directory, so image and preview caches follow it. Migrations apply automatically on every boot — a plain start is enough. API docs are served at `/api/docs`. See [Testing](./testing) for the full command and CI reference.
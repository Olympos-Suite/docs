---
title: "Installation"
description: "Run Zephyrus with Docker Compose or bare-metal pnpm, and prepare the qBittorrent connection."
section: "User Guide"
order: 1
---

# Installation

## Prerequisites

- **qBittorrent 5.x** with the WebUI enabled and reachable from Zephyrus. The adapter requires **Web API ≥ 2.11.0** and uses the v5 `torrents/stop` / `torrents/start` endpoints; qBittorrent 4.x is not supported (its `pause`/`resume` endpoints and `pausedDL` state names no longer exist in v5). You need the WebUI username and password.
- **Docker** (recommended), or **Node.js ≥ 22 and pnpm** for a bare-metal run.

One Zephyrus instance manages one client connection. For multiple clients, run multiple instances with separate config files, databases, and ports.

## Docker Compose

The repository ships a `docker-compose.yml`. Create a `.env` file next to it:

```bash
# .env
ZEPHYRUS_TOKEN=change-me-long-random-string   # static API bearer token — required in production
QBIT_PASSWORD=your-qbit-webui-password        # referenced from config.yaml via env:QBIT_PASSWORD
PUID=1000                                     # user the container drops to (default 1000)
PGID=1000                                     # group (default 1000)
TZ=Europe/Istanbul                            # container timezone (default Europe/Istanbul)
```

Then the compose file (as shipped in the repo):

```yaml
services:
  zephyrus:
    build: .
    container_name: zephyrus
    restart: unless-stopped
    ports:
      - "9695:3030"
    environment:
      ZEPHYRUS_TOKEN: ${ZEPHYRUS_TOKEN:?set ZEPHYRUS_TOKEN in .env}
      QBIT_PASSWORD: ${QBIT_PASSWORD:?set QBIT_PASSWORD in .env}
      PUID: ${PUID:-1000}
      PGID: ${PGID:-1000}
      TZ: ${TZ:-Europe/Istanbul}
    volumes:
      - ./data:/data        # SQLite database (zephyrus.db)
      - ./config:/config    # config.yaml lives here
```

Key points:

- **Volumes.** `/data` holds the SQLite database, `/config` holds `config.yaml`. The image sets `ZEPHYRUS_CONFIG=/config/config.yaml` and `ZEPHYRUS_DB=/data/zephyrus.db`. Place your configuration at `./config/config.yaml` on the host (start from `config.example.yaml` — see [Configuration](./configuration)).
- **First boot with an empty `/config`.** Zephyrus does not crash: it writes a self-contained default `config.yaml` (pointing at `http://qbittorrent:8080` with placeholder credentials) and logs a warning. Edit the file and restart, or use the dashboard's first-run setup wizard, which tests the connection before saving.
- **User drop.** The container starts as root, applies `PUID`/`PGID` to the `zephyrus` user, chowns `/data` and `/config`, then drops privileges via `gosu`. Match `PUID`/`PGID` to the owner of your mounted directories.
- **Healthcheck.** Defined in the image (not the compose file): every 30 s it runs `curl -sf -H "Authorization: Bearer ${ZEPHYRUS_TOKEN}" http://127.0.0.1:3030/api/status` (5 s timeout, 10 s start period, 3 retries). `GET /api/status` answers even when the torrent client is unreachable — it reports `degraded` instead of failing, so a client outage does not kill the container.
- **Companion qBittorrent.** The repo's compose file includes a commented-out `linuxserver/qbittorrent:5.x` example service. If you enable it, uncomment the matching `depends_on` block too.

Build and start:

```bash
docker compose up -d --build
```

Verify:

```bash
curl -H "Authorization: Bearer $ZEPHYRUS_TOKEN" http://localhost:9695/api/status
```

Open `http://localhost:9695` for the dashboard. On a fresh install the first-run wizard asks you to create an admin account and connect the torrent client (see [Dashboard](./dashboard)).

## Environment variables

| Variable | Purpose |
|----------|---------|
| `ZEPHYRUS_TOKEN` | Secondary static machine token for the HTTP API (`Authorization: Bearer <token>`). Primary authentication is the admin account created by the first-run setup wizard (username/password → 30-day session tokens). The token is required in production by the shipped compose file, which refuses to start without it. When unset, Zephyrus logs a startup warning and the static token is unavailable; username/password sessions still apply, and the API is fully open **only** during first-run setup (no users exist yet). |
| `QBIT_PASSWORD` | Not read directly by Zephyrus — referenced from `config.yaml` as `password: env:QBIT_PASSWORD`. Any `env:NAME` reference works the same way. |
| `ZEPHYRUS_CONFIG` | Config file path. Default `./config.yaml` (Docker: `/config/config.yaml`). |
| `ZEPHYRUS_DB` | SQLite database path. Default `./data/zephyrus.db` (Docker: `/data/zephyrus.db`). |
| `PUID` / `PGID` | Docker only: user/group to drop to (default `1000`). |
| `TZ` | Container timezone. Schedule windows use the `timezone` field in `config.yaml`, not `TZ`. |
| `LOG_LEVEL` | Overrides `server.log_level` from the config. |
| `NODE_ENV` | `development` enables pretty-printed logs; the Docker image sets `production`. |

## Bare metal (pnpm)

Requires Node.js ≥ 22 and pnpm. From the repository root:

```bash
pnpm install          # native builds (better-sqlite3) are allow-listed in pnpm-workspace.yaml
pnpm dev              # tsx watch src/index.ts — auto-creates ./config.yaml on first run
```

| Command | What it does |
|---------|--------------|
| `pnpm dev` | Run from source with watch mode. On first run it creates `./config.yaml` with defaults and logs a warning; edit it and restart. |
| `pnpm build` | Compile TypeScript to `dist/`. |
| `pnpm start` | Run the compiled server (`node dist/index.js`). |
| `pnpm test` / `pnpm test:watch` | Vitest suite (policy engine, adapter, orchestrator, API, config). |
| `pnpm typecheck` | `tsc --noEmit` (strict). |
| `pnpm db:generate` / `pnpm db:migrate` | Drizzle-kit migration tooling. Migrations also auto-apply on every boot, so a plain start is enough to run. |

The dashboard is a nested package under `web/` (not a pnpm workspace member):

```bash
cd web
pnpm install --ignore-workspace
pnpm build            # produces web/dist, served statically by Fastify
```

For frontend development, `pnpm dev` inside `web/` starts the Vite dev server with an `/api` proxy to the backend.

Set `ZEPHYRUS_TOKEN` (and any variables your config references) in the environment before starting:

```bash
export ZEPHYRUS_TOKEN=change-me-long-random-string
export QBIT_PASSWORD=your-qbit-webui-password
pnpm build && pnpm start
```

## Preparing qBittorrent

1. Use qBittorrent **5.x** and enable the WebUI (Tools → Options → Web UI). Note the port (default `8080`) and credentials.
2. Make sure the WebUI is reachable from the Zephyrus host/container — `client.url` in the config must point at it (for example `http://qbittorrent:8080` on a shared Docker network).
3. Zephyrus never changes qBittorrent's global settings. Its own queueing (`max_active_downloads` / `max_active_torrents`) **may stay enabled** — the two queues coexist by design (see [Smart queuing](./smart-queuing)). The repo's compose file nevertheless recommends disabling qBit's internal queueing or setting both limits generously, because two competing queues can cause start/stop thrash.
4. Assign torrents to the categories that match your managed groups (`eros`, `psyche`, …). Zephyrus only manages torrents in configured groups; everything else is left alone (see [Integration](./integration)).

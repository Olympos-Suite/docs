---
title: "Installation"
description: "Run Morpheus with Docker Compose or bare-metal pnpm: the two images, first-run setup, worker API keys, and GPU prerequisites."
section: "User Guide"
order: 10
---

Morpheus ships as two images. The management image is the suite-standard single web+API container; the worker image is headless — no UI, no published ports, configured with a server URL and an API key, nothing else.

| Image | Contents | Configuration |
|-------|----------|---------------|
| `morpheus` (management) | Web UI (port 3000) + API (port 3001) + SQLite, embedded worker, vendored libvmaf-capable ffmpeg | Web port, `/config`, archive roots |
| `morpheus-worker` | Node runtime + transcode engine only | `MORPHEUS_SERVER_URL` + `MORPHEUS_API_KEY` |

## Docker Compose

The repository ships `docker-compose.example.yml` — copy it to `docker-compose.yml` and adjust. The core shape: one management service plus dedicated workers on the same compose network.

```yaml
services:
  morpheus:
    image: morpheus
    container_name: morpheus
    ports:
      - "9699:3000"        # web UI; host port is your choice
      # - "9700:3001"      # API — publish ONLY for workers on other machines
    volumes:
      - morpheus-config:/config
      # - morpheus-gpu:/data/.morpheus-gpu   # NVIDIA hosts only
      # - /mnt/media/archive:/data/archive:rw
    environment:
      - PUID=1000
      - PGID=1000
      - MORPHEUS_GPU_CACHE=/data/.morpheus-gpu
    restart: unless-stopped

  morpheus-worker:
    image: morpheus-worker
    container_name: morpheus-worker
    cpus: 2                # kernel-enforced cgroup quota
    environment:
      - MORPHEUS_SERVER_URL=http://morpheus:3001
      - MORPHEUS_API_KEY=${MORPHEUS_WORKER_API_KEY:?create one via the API Keys page}
      - MORPHEUS_GPU_CACHE=/app/.morpheus-gpu
    restart: unless-stopped

  morpheus-worker-2:       # scale by duplicating worker services
    image: morpheus-worker
    container_name: morpheus-worker-2
    cpus: 4
    environment:
      - MORPHEUS_SERVER_URL=http://morpheus:3001
      - MORPHEUS_API_KEY=${MORPHEUS_WORKER_API_KEY:?create one via the API Keys page}
      - MORPHEUS_GPU_CACHE=/app/.morpheus-gpu
    restart: unless-stopped

volumes:
  morpheus-config:
```

Key points:

- **Ports.** The container always serves web on 3000 and the API on 3001. Only the web port is published by default (9699 in the example); the frontend proxies `/api/*` to the API. Workers on the same compose network dial `http://morpheus:3001` directly — container-internal, never the web port.
- **`cpus` is the hard CPU budget.** It sets a kernel cgroup quota the worker reads and advertises at registration; "half the CPU" means exactly half. See [Transcode pipeline](./transcode-pipeline#cpu-budgets).
- **User drop.** The entrypoint starts as root, creates the `PUID`/`PGID` user/group if missing (defaults 1000:1000), chowns `/config` and `/data`, then drops privileges via gosu. The runtime never runs as root. Match `PUID`/`PGID` to the owner of your mounted directories.
- **No Docker HEALTHCHECK.** The supervisor runs web + API and exits when either process dies, so the restart policy brings the whole app back. `GET /api/health` reports ffprobe availability.

## Volumes

| Mount | Contents | Backup? |
|-------|----------|---------|
| `/config` | SQLite DB, settings, session secret, the embedded worker's API key (mode 0600), and the embedded worker's default staging dir (`worker-staging/`) | **Yes — the only volume worth backing up** |
| `/data/...` | Your archive roots (media mounts) | Your existing media backup policy |
| `/data/.morpheus-gpu` (management) / `/app/.morpheus-gpu` (worker) | Runtime-downloaded NVIDIA encoder components, version-stamped | No — re-downloadable; kept outside `/config` so backups stay lean |

> [!NOTE]
> The embedded worker's staging dir defaults under `/config` and holds whole media files mid-transcode. For large libraries, point `embedded_worker_staging_dir` at a roomier mount (see [Configuration](./configuration#embedded-worker)).

## First run

1. Start the stack: `docker compose up -d`.
2. Open `http://<host>:9699`. The first-run wizard asks you to create the admin account.
3. Create a **worker API key** on the API Keys page (or `POST /api/api-keys`). The plaintext is shown **exactly once** in a copyable dialog — only a sha256 hash is stored.
4. Export it before bringing workers up; the example compose refuses to start without it:

```bash
export MORPHEUS_WORKER_API_KEY="<the plaintext key>"
docker compose up -d
```

All workers can share one key. Add your archive roots on the Libraries page and run a scan — see [Libraries and scanning](./libraries).

## Embedded worker vs dedicated workers

The management container runs an **embedded worker** in-process by default (`embedded_worker_enabled: true`), so a single container can transcode on its own. When you dedicate worker machines to the job, disable it in Settings → Workers & Disk so the management node only orchestrates and verifies.

> [!WARNING]
> On current images, flipping `embedded_worker_enabled` at runtime may not take effect until you `docker restart morpheus`. The live-reconfigure fix is in the code but not yet in every released image. See [Workers](./workers). Mount-mapping (`embedded_worker_mounts`) and staging-dir changes, by contrast, apply live — drain and loop restart, no API restart.

## NVIDIA GPU workers

The base worker image ships CPU (x264/x265) and Intel QSV/VAAPI support. NVIDIA encode components are **downloaded at runtime**, only when `nvidia-smi` detects a GPU. Prerequisites:

- **NVIDIA Container Toolkit** on the host, with the GPU exposed to the container.
- **Internet access on first start** — the encoder artifact pull happens once and is cached in the GPU cache volume. Uncomment the cache volume so the download survives container recreation.

Hosts without an NVIDIA GPU never download anything. Upgrade order matters: **upgrade the server before the workers** — an older worker registering against a newer server is fine, the reverse can loop on 400s (see [Troubleshooting](./troubleshooting)).

## Workers on other machines

Publishing the API port is a **separate step** from the web port mapping — the default compose publishes web only. Uncomment the `"9700:3001"` mapping on the management service, then point remote workers at it:

```yaml
environment:
  - MORPHEUS_SERVER_URL=http://<lan-ip>:9700   # the API port — NEVER the web port
  - MORPHEUS_API_KEY=<worker key>
```

> [!IMPORTANT]
> A worker pointed at the web port relies on the `/api/*` proxy for large transfers. The direct API port is the preferred topology for remote workers; hardening the published port is a later phase, so keep it on a trusted LAN.

## Bare metal (pnpm)

Requires **Node ≥ 24** and **pnpm 12.7.0** (pinned via the `packageManager` field). From the repository root:

```bash
pnpm install                        # better-sqlite3 native builds are allow-listed in pnpm-workspace.yaml
pnpm --filter @repo/server dev      # API on :3001
pnpm --filter @repo/web dev         # web on :3000, proxies /api/* to :3001
```

| Command | What it does |
|---------|--------------|
| `pnpm --filter @repo/server build` | Compile the API; production runs `node apps/server/dist/index.js` — never tsx |
| `pnpm typecheck && pnpm lint && pnpm test && pnpm build` | Full verification chain (CI order) |
| `docker build -f docker/Dockerfile.management -t morpheus:dev .` | Build the management image |
| `docker build -f docker/Dockerfile.worker -t morpheus-worker:dev .` | Build the worker image |

Bootstrap env for the API: `CONFIG_DIR` (default `./config` — DB + session secret live under it), `API_PORT` (3001), `SESSION_SECRET` (generated once if unset). pnpm ≥ 10 blocks dependency build scripts by default; `better-sqlite3` is listed in `pnpm-workspace.yaml` `allowBuilds`.

## ffmpeg and ffprobe

Both images vendor a pinned BtbN FFmpeg-Builds GPL artifact at `/usr/local/bin/ffmpeg` (with libvmaf, x264/x265, and nvenc/vaapi/qsv encoders); the distro `/usr/bin/ffmpeg` remains as an explicit-path fallback, and ffprobe stays the distro binary. On bare metal, put `ffprobe` on PATH (or set `ffprobe_path`) — without it scans still run and count probe errors. Verification uses `ffmpeg_path`; the VMAF gate specifically needs a libvmaf-capable build (see [Verification](./verification)).
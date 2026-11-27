---
title: "Configuration"
description: "Every Morpheus setting with defaults and ranges, grouped by tab, plus the bootstrap environment variables and ports."
section: "User Guide"
order: 20
---

Morpheus configuration lives in the SQLite `settings` table, not in files or env vars — env is for bootstrap only (ports, paths, secrets). Edit settings on the tabbed **Settings** page or via `PUT /api/settings` (partial update; only the keys you send change). Defaults are seeded on server boot. Every key below is user-writable except the machine-managed calibration blob. The UI groups the keys into five tabs — Quality, Jobs & Scheduling, Workers & Disk, System, Security; the tables below group them by topic instead.

## Quality

| Setting | Default | Range / values | Meaning |
|---------|---------|----------------|---------|
| `transcode_crf` | `23` | 0–51 | x265 CRF quality target; lower = better quality, bigger file. Rulesets can override per file. |
| `transcode_preset` | `medium` | `ultrafast` … `veryslow` (9-rung x265 ladder) | Speed/efficiency trade-off. Hardware encoders map the ladder to their own presets. |
| `max_resolution` | `off` | `off`, `2160`, `1440`, `1080`, `720` | Output-height cap in pixels, frozen into the job at enqueue; `off` means no cap at all (source height preserved). Never upscales; 10-bit/HDR preserved. |
| `savings_threshold_percent` | `10` | 1–90 | Minimum verified savings for a replace to succeed: staging ≤ original × (1 − threshold/100). Failing this gate permanently marks the file (see [Verification](./verification#savings-threshold-rejection)). |

## Verification

| Setting | Default | Range / values | Meaning |
|---------|---------|----------------|---------|
| `verify_decode_mode` | `full` | `full`, `light`, `off` | Decode gate: every frame / head+tail only / skipped. `light` never decodes the middle — corruption there passes the gate (see [Verification](./verification#decode-modes-and-hardware-decode)). Other gates always apply. Frozen per job at enqueue. |
| `verify_light_seconds` | `60` | 10–600 | In light mode, seconds decoded at the start and end; both passes must exit clean. |
| `verify_hw_decode` | `auto` | `auto`, `off` | `auto` = NVIDIA NVDEC (`hevc_cuvid`) when initializable, software fallback only on init-class failures; `off` = always software. |
| `verify_decode_threads` | `0` | 0–16 | Decoder threads for the decode gate and the VMAF compare. 0 = auto from cgroup cores and RAM; explicit always wins. |
| `verify_duration_tolerance_percent` | `1` | 0.25–10 | Allowed duration drift vs a fresh probe of the original. The 0.25 floor absorbs ffprobe jitter. |
| `vmaf_min_score` | `0` | 0–100 | VMAF floor for **rule-less single-file enqueues** only; 0 = gate off. Ruleset jobs never read this key — a ruleset with VMAF enabled carries its own floor, defaulting to 90 when unspecified. Requires a libvmaf-capable `ffmpeg_path`. |

> [!IMPORTANT]
> The VMAF gate is opt-in and does not "just work" on any ffmpeg: it needs a build with the libvmaf filter. The management image vendors one; a custom `ffmpeg_path` is operator-supplied and must carry libvmaf itself.

## Trash

| Setting | Default | Range / values | Meaning |
|---------|---------|----------------|---------|
| `trash_retention_days` | `7` | 1–365 | Replaced originals wait in `<root>/.morpheus-trash/` this long before the daily purge. |
| `trash_immediate_delete` | `false` | boolean | Delete replaced originals right away instead of retaining them — they cannot be restored. |

## Workers and disk guards

| Setting | Default | Range / values | Meaning |
|---------|---------|----------------|---------|
| `worker_lease_seconds` | `90` | 30–3600 | How long a claim stays valid without a heartbeat before the sweep requeues the job. |
| `worker_max_attempts` | `3` | 1–10 | A transcode is marked failed after this many attempts. |
| `worker_max_concurrent` | `1` | 1–64 | Live leases one worker may hold at once. Server-owned verifying jobs do not count. |
| `staging_min_free_bytes` | `10737418240` (10 GiB) | ≥ 0 | Absolute free-space floor on the worker's staging filesystem, delivered at registration. |
| `disk_headroom_factor` | `1.5` | 1–10 | Claim-side guard: a library root needs free space ≥ input size × factor. |
| `job_max_wall_seconds` | `0` | ≥ 0 | Per-job wall-clock watchdog; 0 = off. When set, verification decode passes share the job budget. |

## Embedded worker

| Setting | Default | Meaning |
|---------|---------|---------|
| `embedded_worker_enabled` | `true` | Run a worker inside the API process. Turn off when dedicated workers handle everything. |
| `embedded_worker_staging_dir` | `''` | Empty = `<CONFIG_DIR>/worker-staging`; otherwise an absolute path on a roomy volume. Staging holds whole media files. Changes apply live. |
| `embedded_worker_mounts` | `''` | Empty = transfer mode (download → transcode → upload). Otherwise comma-separated `/server/path=/worker/path` pairs switch it to [mount mode](./mount-mode). Applies without a restart. |

> [!WARNING]
> Live reconfiguration is the design, but on current images an `embedded_worker_enabled` change may require `docker restart morpheus` to take effect. Mount-mapping and staging-dir changes apply live (drain + loop restart, no API restart).

## Scheduling

| Setting | Default | Meaning |
|---------|---------|---------|
| `queue_mode` | `running` | `running` claims normally; `paused` hands out no new claims (running jobs keep their leases); `draining` also waits for running jobs to finish. |
| `schedule_window_start` | `''` | 24-hour `HH:MM` local time. Set both bounds or neither; the window may wrap midnight (e.g. 22:00 → 06:00). Empty = around the clock. |
| `schedule_window_end` | `''` | See above. Outside the window, claims are refused immediately. |

## Paths and probing

| Setting | Default | Meaning |
|---------|---------|---------|
| `ffmpeg_path` | `ffmpeg` | `ffmpeg` uses the server PATH; anything else must be an absolute path. Used for verification (and the VMAF compare). PATH reliance is a risk: a distro ffmpeg may lack libvmaf (see the warning below) — the vendored image build is the safe default. |
| `ffprobe_path` | `ffprobe` | Same convention and PATH-reliance caveat; used for scans and verification probes. |
| `max_concurrent_probes` | `4` | 1–16 files probed simultaneously during a scan. Higher is faster but heavier on CPU and disk. |

> [!WARNING]
> A custom `ffmpeg_path` without libvmaf makes the VMAF gate **always fail closed** — every VMAF-enabled job fails with a "VMAF gate error". The vendored management-image ffmpeg includes libvmaf; distro builds typically do not.

## Calibration

`estimator_calibration` is **machine-managed and never user-writable** — it is absent from the update schema, so a client attempting to PATCH it is a silent no-op. The calibration loop folds realized transcode outcomes into bucket and global correction factors; the Stats page shows them read-only. See [Transcode engine](./transcode-engine).

## Environment variables

Management (bootstrap only):

| Variable | Default | Purpose |
|----------|---------|---------|
| `PUID` / `PGID` | `1000` / `1000` | Docker user/group drop. |
| `TZ` | — | Container timezone. |
| `CONFIG_DIR` | `./config` (Docker: `/config`) | SQLite DB, session secret, embedded worker key. |
| `API_PORT` | `3001` | API listen port. |
| `SESSION_SECRET` | generated once | Session signing secret; persisted under `CONFIG_DIR`. |
| `MORPHEUS_GPU_CACHE` | `/data/.morpheus-gpu` | Runtime NVIDIA encoder cache path. Legacy `MORPHEUS_NVENC_CACHE` works as an alias. |

Workers:

| Variable | Required | Purpose |
|----------|----------|---------|
| `MORPHEUS_SERVER_URL` | yes | Management API base URL, e.g. `http://morpheus:3001`. |
| `MORPHEUS_API_KEY` | yes | Worker API key (create on the API Keys page). |
| `MORPHEUS_WORKER_NAME` | no | Display name for registration (upsert key). |
| `MORPHEUS_WORKER_CPUS` | no | Explicit core budget when no cgroup quota is present. |
| `MORPHEUS_WORKER_STAGING_DIR` | no | Staging location; default is the container filesystem (transient by design). |
| `MORPHEUS_MOUNTS` | no | `/server/path=/worker/path` pairs enable mount mode. |
| `MORPHEUS_GPU_CACHE` | no | Worker GPU cache path (image default `/app/.morpheus-gpu`). |

## Ports

| Port | Served by | Published? |
|------|-----------|------------|
| 3000 | Web UI (proxies `/api/*` to the API) | Yes — host port of your choice (9699 in the example) |
| 3001 | Fastify API | Container-internal by default; publish only for remote workers or debugging |
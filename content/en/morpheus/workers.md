---
title: "Workers"
description: "Embedded and dedicated workers: registration, leases and heartbeats, crash requeue, scaling, GPU provisioning, and server-side overrides."
section: "User Guide"
order: 70
---

Workers do the encoding; the management server owns the queue, verification, and the replace. A worker can be the **embedded worker** inside the management container or a **dedicated** headless container on any machine that can reach the API.

## Embedded and dedicated workers

The embedded worker runs in-process in the API — the same transcode engine code, talking to the loopback API. It is enabled by default (`embedded_worker_enabled: true`) so a single-container setup works out of the box. When dedicated workers handle everything, disable it in Settings → Workers & Disk. Its staging dir defaults under `/config`; point `embedded_worker_staging_dir` at a bigger volume for large libraries.

Dedicated workers need only `MORPHEUS_SERVER_URL` and `MORPHEUS_API_KEY`. They register, claim, transcode, and upload; they never verify and never touch the original file.

## Registration and capabilities

A worker registers by name (`POST /api/worker/register`) — an upsert, so restarts reuse the same row. It advertises its capabilities: effective CPU cores, cgroup quota, acceleration class (none/qsv/vaapi/nvenc), GPU info, version, and its file-access mode and mount mappings. The server normalizes the advertisement (trailing slashes, mode/mapping invariants). An admin rename on the Workers page **locks the display name** — re-registration never overwrites it.

Presence is tracked by `lastSeenAt`: register, claim, and heartbeat all stamp it, and the lease sweep ages a worker to **offline** after 3× the lease without contact.

## Claims, leases, and heartbeats

In user terms:

1. The worker **long-polls for a job** (the server holds the request up to 25 s). It gets the highest-priority eligible job, or an empty answer when the hold expires.
2. The claim carries a **lease** — 90 s by default. While it works, the worker **heartbeats** every `max(5 s, lease/3)` to extend the lease by another full period.
3. After the upload is accepted, the **server takes ownership**: the lease is cleared and verification runs server-side, possibly outliving any lease. The worker is free to claim again immediately.

Scheduling gates refuse claims immediately (no hold): queue mode not `running`, outside the nightly window, or the worker already at `worker_max_concurrent`.

The default timings, all derived from settings:

| Timing | Default | Source |
|--------|---------|--------|
| Claim long-poll hold | 25 s | Server constant |
| Lease | 90 s | `worker_lease_seconds` |
| Heartbeat interval | 30 s | `max(5 s, lease/3)` |
| Worker aged offline | 270 s without contact | 3 × lease, via the sweep |
| Attempts before terminal failure | 3 | `worker_max_attempts` |

## Crashes and requeue

If a worker dies mid-job, its lease expires. The sweep requeues the job (attempts incremented, up to `worker_max_attempts`, default 3), and another worker picks it up **from scratch** — the original is untouched. A worker waiting on an empty queue picks up a requeued job within about a second, because every claim iteration runs the lease sweep first. Per-attempt staging names (`<jobId>.a<attempts>.mkv`) isolate the successor's upload from any stale in-flight bytes.

## Concurrency

`worker_max_concurrent` (default 1) counts **live leases only**. A job the worker uploaded — now server-owned and verifying — does not count, so a worker that uploaded and re-claims is never blocked by its own verifying job.

## Scaling workers

Duplicate worker services in one compose file, each with its own `cpus` quota (the example ships `cpus: 2` and `cpus: 4`). All workers can share one API key. For workers on other machines, publish the API port on the management host and point `MORPHEUS_SERVER_URL` at it — never the web port (see [Installation](./installation)).

## GPU workers

The base image ships CPU + QSV/VAAPI. On NVIDIA hosts the worker detects the GPU via `nvidia-smi` and downloads the encode components at runtime — internet on first start and the NVIDIA Container Toolkit are required; the download is cached in the GPU cache volume.

> [!IMPORTANT]
> Upgrade order is **server first**. A worker newer than the server can loop on 400 registration errors; upgrade the management image before the workers.

## File-access override

The server can override any worker's file-access mode and mappings: `PATCH /api/workers/:id` (the Workers page action) sets `fileAccessOverride`. The **server-side override wins** over the worker's advertised mode at claim time — effective on the next claim, zero worker-side changes, and it survives re-registration and restarts. Use it to force a worker into transfer mode, or to correct its mount mappings without touching its env.

## Live-toggling the embedded worker

The embedded worker is designed for live reconfiguration: flipping `embedded_worker_enabled` off drains the loop gracefully and stops it; a mid-job disable aborts the job as retryable, so the server requeues it immediately for another worker. Mount-mapping changes (`embedded_worker_mounts`) and staging-dir changes (`embedded_worker_staging_dir`) drain and restart the loop without an API restart; identical mappings are a no-op.

> [!WARNING]
> On current images, an `embedded_worker_enabled` change may not take effect until you `docker restart morpheus`. The transition fix is in the code but not yet deployed in every released image. If the toggle appears ignored, restart the management container — running jobs are requeued at boot and originals stay intact.

## Staging disk guards

Two guards keep a worker from filling a disk:

- **Absolute floor:** `staging_min_free_bytes` (default 10 GiB) on the staging filesystem, delivered at registration and self-checked by the worker.
- **Headroom factor:** at claim, the server skips candidates whose library root has less free space than input size × `disk_headroom_factor` (default 1.5). A statfs failure fails open with a warning — the worker-side guard remains the real protection.

When every candidate is blocked by the headroom guard, the server logs a diagnostic instead of answering a silent empty claim — see [Troubleshooting](./troubleshooting).
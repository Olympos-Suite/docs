---
title: "Mount Mode"
description: "Experimental in-place processing: workers read and write through shared SMB/NFS storage, with no download or upload."
section: "User Guide"
order: 80
---

> [!IMPORTANT]
> Mount mode is **experimental** (Phase 4D). It works when explicitly opted in, but is **not recommended for production**: the mount-mode worker is **commented out** in `docker-compose.example.yml` and is not enabled by default. Validate it on your storage and keep a transfer-mode worker as fallback.

In transfer mode a worker downloads the original, transcodes into local staging, and uploads the result. When the **same archive storage is mounted into the worker container** (NFS, SMB, or a same-host bind), mount mode skips both transfers: the worker reads the original and writes staging **in place** through the shared filesystem, then posts a completion marker. The server still runs every verification gate and the atomic replace — those are mode-blind.

## How it works

1. The worker registers with `mode: 'mount'` and its mount mappings.
2. The server hands out assignments carrying the **worker's own view** of the paths: translated input path, staging dir, and the exact per-attempt staging file name.
3. The worker transcodes directly into the mapped staging location — no download leg, so visible progress starts at `transcoding`.
4. The worker posts `output-mounted`; the server checks the staged file exists (size > 0), takes ownership, and runs the same verify-and-replace seam as an upload.

## Configuring mappings

Mappings are comma-separated `<serverPrefix>=<workerPrefix>` pairs of absolute POSIX paths:

```bash
# Headless worker env:
MORPHEUS_MOUNTS=/mnt/media/archive=/mnt/media/archive

# Multiple roots:
MORPHEUS_MOUNTS=/srv/movies=/mnt/movies,/srv/shows=/mnt/shows
```

- An **identity mapping** (same path on both sides) is valid — the zero-config same-host case.
- The embedded worker uses the same format via the `embedded_worker_mounts` setting, live-reconfigurable without an API restart (drain + loop restart); only `embedded_worker_enabled` flips may need `docker restart morpheus` on current images.
- Prefixes are normalized (trailing slashes stripped); each server prefix may be mapped once, and ambiguous pairwise-overlapping server prefixes are rejected at registration.
- The worker volume must be the **same storage** the server serves the library from, mounted read-write.

The compose example ships a commented `morpheus-worker-mount` service — uncomment and adjust to try it:

```yaml
  morpheus-worker-mount:
    image: morpheus-worker
    container_name: morpheus-worker-mount
    cpus: 2
    volumes:
      # MUST be the same storage the server serves the library from:
      - /mnt/media/archive:/mnt/media/archive:rw
    environment:
      - MORPHEUS_SERVER_URL=http://morpheus:3001
      - MORPHEUS_API_KEY=${MORPHEUS_WORKER_API_KEY:?create one via the API Keys page}
      - MORPHEUS_MOUNTS=/mnt/media/archive=/mnt/media/archive
    restart: unless-stopped
```

## Claim filtering

A mount worker claims **only jobs under its mapped server roots** — the filter runs SQL-side, segment-aware, and composes with the hardware-preference filter. Two consequences:

- A mount registration **without mappings claims nothing** — never the whole queue.
- Libraries outside every mapped prefix are invisible to that worker; a transfer-mode worker (or the embedded worker) handles them.

## Path matching

Root matching is **case-insensitive** (a `strcasecmp` on the stored root path), which suits SMB shares — but it means you must **register the library with matching case** to the mapping. Realpath drift is not followed: if the stored root and the mapped prefix diverge beyond case, the job will not match. This is documented behavior, not a bug to work around silently.

## Staging and probe-writes

Staging lives on the mapped roots, in the same per-root `.morpheus-staging/` directory transfer mode uses, with the same per-attempt names (`<jobId>.a<attempts>.mkv`). At startup the worker **probe-writes each mapped staging root**: a read-only mount produces one loud log line and never blocks registration — but the job will fail when it cannot write, so fix the mount before assigning work.

The worker reports free space for the mapped roots (any root satisfying the floor passes its self-check); the server's per-root claim-side guard is authoritative.

## Completion

`POST /api/worker/jobs/:jobId/output-mounted` validates the claim holder and live lease, checks the staged output exists with size > 0 (a 409 names the expected path), then reuses the upload-accept seam verbatim: ownership transfer, `verifying` stage, server-side verification, atomic replace. No bytes cross the wire.

## What mount mode never does

- **Never wipes the shared staging root.** The scratch-wipe on startup stays transfer-only — a mount worker deleting shared staging would destroy other workers' in-flight outputs.
- **Never bypasses verification.** Every gate, the savings threshold, and the M1 link-then-rename apply exactly as in transfer mode.
- **Never touches the original** before the replace — the worker only reads it.
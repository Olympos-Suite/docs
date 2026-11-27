---
title: "Troubleshooting"
description: "Low-memory management nodes, verify timeouts, 409 conflicts, permanent rejections, idle workers, and where to read the logs."
section: "User Guide"
order: 100
---

Morpheus fails safe: a failed verification keeps the original, a dead worker's job is requeued, and a restart never loses data. Most problems below are configuration or capacity issues, not corruption.

## Where the logs live

The server logs structured JSON via **Pino** to stdout — in Docker, `docker logs morpheus` (the supervisor prefixes `api |` and `web |` lines). Workers log the same way: `docker logs morpheus-worker`. Every job also carries a run log in its detail view on the Jobs page, including the verification gate results — start there for a failed transcode.

## Low-memory management nodes

The canonical failure: a **4 GiB NAS** running the management container with a 1-core quota. Verification's ffmpeg decode auto-threaded to the *host's* CPU count (16), not the cgroup quota — a 4K HEVC full decode held ~3 GiB RSS, the node OOMed, and the flat 30-minute decode timeout killed every feature-length verify. The fixes are in the code and on by default:

- `verify_decode_threads: 0` (auto) caps decode threads from cgroup cores **and RAM**: `clamp(min(cores, floor(RAM GiB / 2)), 1, 16)` — a 4 GiB node resolves to 2 threads.
- Every verification spawn runs under `nice -n 19`, so the API event loop is never starved.
- `verify_hw_decode: auto` uses NVDEC when a GPU is present — 4K HEVC decode at ~300–500 MB RSS instead of gigabytes.

Recommended settings for a small management node (e.g. 4 GiB NAS + GTX 1050):

```yaml
verify_decode_mode: full      # keep the full-decode guarantee
verify_hw_decode: auto        # NVDEC when available, init-only software fallback
verify_decode_threads: 0      # auto: resolves to 2 on a 4 GiB node
```

> [!TIP]
> If swap starts filling during verification, `docker restart morpheus` is safe: ffmpeg is killed, the job is requeued at boot, and the original is still intact. Then lower the decode thread cap explicitly or enable hardware decode.

## Verification timeouts

**Symptom:** feature-length files fail the decode gate on a weak node.
**Cause:** the decode budget is duration-scaled (2 × duration + 10 min, floor 30 min) — but unbounded threads or a too-small `job_max_wall_seconds` can still exhaust it.
**Fix:** leave `verify_decode_threads` at auto (or set a small explicit cap), enable `verify_hw_decode: auto` on GPU hosts, and if you set `job_max_wall_seconds`, make it generous enough for a full realtime decode — or set it back to 0 to use the scaled budget.

## 409 on claim

**Symptom:** a worker's claim or heartbeat answers 409.
**Meaning:** the worker lost the job — another worker claimed it, the lease expired and the sweep requeued it, or the job was finalized underneath. After an upload is accepted the lease is intentionally cleared (server ownership), so a late heartbeat 409 is normal and logged as "server-owned", never as a requeue.
**Fix:** nothing for a one-off — the worker re-claims. Repeated 409s mean the lease is too short for the heartbeat path: check network latency and `worker_lease_seconds`.

## 409 on job create

**Symptom:** manual transcode or rule assignment answers 409.
**Meaning:** the one-active-job-per-file constraint — another transcode for this file is already queued or running (a partial UNIQUE index in the database). Also 409: the file is not probed or not h264 (manual path), a disabled ruleset, or an already-active bulk run/scan for the library.
**Fix:** check the Jobs page for the active job; wait for it or cancel it. The error envelope's `details` names the conflicting job where applicable.

## Savings-threshold rejections

**Symptom:** a job fails with "savings below threshold" and the file never re-queues.
**Meaning:** the verified output saved less than the threshold — the **only** failure that stamps the permanent no-retry marker. The original is intact; the encode was deleted.
**Fix:** accept that the file is not a good candidate, or change the approach: assign a different ruleset (clears the marker — a new profile is a new chance), adjust CRF/preset, or run a manual transcode, which stays allowed regardless of the marker. See [Verification](./verification#savings-threshold-rejection).

## Mount worker claims nothing

Work through the causes in order:

1. **No mappings configured** — a mount registration without usable mappings claims nothing by design.
2. **Library root outside every mapped server prefix** — check the mapping covers the library's registered root.
3. **Case mismatch** — matching is case-insensitive, but register the library with the same case as the mapping; realpath drift is not followed.
4. **Ambiguous overlapping prefixes** — rejected at registration; check the worker log.
5. **Server-side override** — an admin `fileAccessOverride` wins over the advertised mappings; check the Workers page.

## GPU worker registration loop

**Symptom:** a GPU worker logs repeated 400s on register.
**Cause:** the worker is newer than the server.
**Fix:** upgrade in **server-first** order — management image first, then workers. Also verify the NVIDIA Container Toolkit is installed and the first-start download had internet access; the encoder components are cached in the GPU volume afterwards.

## Embedded worker toggle not taking effect

**Symptom:** you flipped `embedded_worker_enabled` but the embedded worker keeps running (or never starts).
**Cause:** on current images the live-reconfigure transition may not be handled until restart — the fix is in the code but not yet in every released image.
**Fix:** `docker restart morpheus`. Running jobs are requeued at boot and restart from scratch; originals stay intact. Mount-mapping changes (`embedded_worker_mounts`) do apply live.

## Workers idle, queue full

**Symptom:** queued transcodes, online workers, but nothing is claimed.
**Cause:** a scheduling gate or the disk guard refuses claims — the server logs one diagnostic per reason per minute instead of answering silent 204s. Check, in order:

1. `queue_mode` is `paused` or `draining`.
2. The current time is outside the nightly schedule window.
3. The worker holds `worker_max_concurrent` live leases (verifying jobs don't count).
4. Every candidate's library root lacks free space ≥ input size × `disk_headroom_factor` — free disk on the archive roots, or lower the factor.
5. Hardware-preference mismatch — a `hw`-pinned rule with only CPU workers registered (or vice versa).
---
title: "Worker Protocol"
description: "The frozen worker wire contract: register, long-poll claim, lease and heartbeat semantics, transfers, failure reports, and the abort chain."
section: "Developer Guide"
order: 20
---

The worker protocol is a **frozen contract** (deepwork decision #4): the shipped worker client is implemented against it, and third-party clients can be too. All JSON routes speak the suite envelope (`{success:true,data}` / `{success:false,error,code}`); the two binary transfer routes deliberately do not. Auth is API-key (or admin session). Job-scoped calls carry worker identity in the **`X-Worker-Id` header** (or a `workerId` query param) — when present, services enforce a strict claim-holder match (mismatch → 409); when absent, the caller acts as the job's current holder.

| Method | Path | Purpose |
|--------|------|---------|
| POST | `/api/worker/register` | Upsert by name, advertise capabilities |
| POST | `/api/worker/claim` | Long-poll for the next job (25 s hold) |
| POST | `/api/worker/jobs/:jobId/heartbeat` | Extend the lease |
| POST | `/api/worker/jobs/:jobId/progress` | Throttled stage/percent report |
| POST | `/api/worker/jobs/:jobId/fail` | Failure report (retryable or terminal) |
| GET | `/api/worker/jobs/:jobId/input` | Download the original (Range-resumable) |
| PUT | `/api/worker/jobs/:jobId/output` | Upload the transcoded output |
| POST | `/api/worker/jobs/:jobId/output-mounted` | Mount-mode completion marker |

## Registration

`POST /api/worker/register` — **upsert by name**. The body advertises capabilities: effective cores, cgroup quota (`cpuBudgetCores`), acceleration class, version, `gpuInfo`, mode (`transfer` | `mount`), and `mountMappings`. The server normalizes (trailing slashes, mode/mapping invariants: mount requires ≥ 1 mapping, server prefixes unique and non-overlapping). The response returns the lease budget and `stagingMinFreeBytes`. An admin-renamed worker has `nameLocked` set — the upsert never overwrites a locked display name. Registration stamps `lastSeenAt` + online.

## Claim

`POST /api/worker/claim` — long-poll, **25 s hold** (`workerClaimHoldMs`), 1 s internal poll. Returns the highest-priority claimable transcode job, or **204** when the hold deadline passes. Each iteration:

1. **Lease sweep FIRST** — expired leases are requeued before the claim query, so a worker parked on an empty queue picks up a requeued job within ~1 s of expiry.
2. **Scheduling gates** — `queue_mode ≠ running`, outside the schedule window, or `worker_max_concurrent` live leases reached → the call answers **immediately** (no hold), so workers back off and re-poll rather than park. Gate refusals while jobs are queued log one diagnostic per reason per 60 s.
3. **Candidate page + disk guard** — a priority-ordered candidate page (LIMIT 25, indexed claim order) joined with input size and library root; statfs per distinct root (30 s TTL cache, outside any SQLite transaction) skips roots with free space < input size × `disk_headroom_factor`. Statfs failure **fails open** with a warning — the worker-side staging guard is the real protection. The first candidate with headroom is claimed atomically.

The claim filters SQL-side by the worker's acceleration (allowed `hw_preference` values) and, for mount workers, by effective server root prefixes — below LIMIT, so one worker class cannot starve the other. Presence is stamped at arrival, even on gate-refused or empty polls. The assignment carries the frozen payload knobs, the resolved hw accel, the lease deadline, and (mount mode) the worker-view input/staging paths with the exact staging file name.

## Lease and heartbeat

- **Lease:** `worker_lease_seconds` (default 90 s), set at claim. The worker heartbeats at `max(5 s, lease/3)`.
- `POST /api/worker/jobs/:jobId/heartbeat` extends the lease by another full period. **409** when the lease was lost or the server took ownership.
- **NULL lease = server ownership (M3).** Upload acceptance clears `lease_expires_at`; verification may outlive the lease, and the sweep skips NULL-lease rows. A heartbeat on a server-owned job answers 409 — the shipped client logs it as "server-owned" and never treats it as a requeue signal.

## Progress and failure reports

- `POST /api/worker/jobs/:jobId/progress` — stage/percent reports (`downloading` | `transcoding` | `uploading`), leading-edge throttled to at most one per 2 s per stage → **204**. On server-owned jobs the server acknowledges with 204 **no-write**, preserving the `verifying` stage published at accept time.
- `POST /api/worker/jobs/:jobId/fail` → **204**. Retryable failures requeue the job under `worker_max_attempts` (default 3); non-retryable failures or the attempts cap mark it failed. Reports on server-owned jobs are ignored with a warning — verification decides the outcome.

## Binary transfers

- `GET /api/worker/jobs/:jobId/input` — streams the original to the claim holder with a live lease. **Range-resumable**: `bytes=N-` → 206 with `content-range`; malformed/multi-range headers fall back to a full 200; out-of-bounds → 416 (enveloped).
- `PUT /api/worker/jobs/:jobId/output` — raw `application/octet-stream` body piped straight to the per-attempt staging file with backpressure (non-buffering parser; nothing held in memory). Route `bodyLimit` is 1 TiB; a **2 s lease watchdog** kills the pipe if the job is requeued mid-upload, and the partial file is deleted — it never reaches acceptance. Completion calls the accept seam: ownership transfer (lease → NULL), `verifying` published, detached verification. Lost-lease races answer 409 and clean staging.

**Per-attempt staging** (`<root>/.morpheus-staging/<jobId>.a<attempts>.mkv`, one shared helper) isolates a successor's upload from a stale in-flight one after requeue.

## Abort chain

One `AbortController` per job. Heartbeat 409, progress 409, or `stop()` aborts: transfers reject, ffmpeg gets SIGTERM → SIGKILL. After upload acceptance the server clears the lease, the heartbeat interval dies immediately, and an in-flight beat's 409 is logged as server-owned — never as a requeue. Graceful shutdown drains the loop.

## Concurrency and re-rank

`worker_max_concurrent` counts **live leases only** — NULL-lease verifying rows do not count, so a worker that uploaded and re-claims is never blocked by its own verifying job. The lease sweep piggybacks a **priority re-rank**: when the effective global calibration factor drifts ≥ 2% (`RERANK_TRIGGER_DELTA`) from the last recompute, queued priorities are recomputed set-based from payload snapshots (no `media_files` reads).

## Mount-mode seam

`POST /api/worker/jobs/:jobId/output-mounted` — no body, no bytes. Validates claim holder + live lease, checks the staged output exists with size > 0 at the job's own staging resolution (409 names the expected path), then reuses `acceptOutput` verbatim. Verify and the M1 replace are mode-blind. See [Mount mode](./mount-mode).

## File-access override

`PATCH /api/workers/:id` stores `fileAccessOverride` (`{mode, mountMappings}`). The **effective** mode/mappings resolve from the stored row on every claim — the override wins over the advertised capabilities, takes effect on the next claim with zero worker-side changes, and survives re-registration (the upsert never touches the column). A mount shape with no usable prefixes claims nothing rather than falling back to the whole queue.

## The loop in one picture

```text
register ──► claim (long-poll, 25 s) ──► download ──► transcode ──► upload
   ▲              │                                                   │
   │              ├─ 204 empty → re-poll                              ▼
   │              └─ gate refused → back off, re-poll        accept: lease → NULL
   │                                                                  │
   └──────────────────── re-claim immediately ◄───────────────────────┘
                                        (server verifies detached, single-flight)
```

Mount mode replaces download/upload with in-place reads/writes and the `output-mounted` marker; everything from acceptance onward is identical. Signals drain the loop gracefully; a mid-job abort reports retryable so the server requeues immediately.
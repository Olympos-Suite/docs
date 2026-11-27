---
title: "Transcode Pipeline"
description: "The job lifecycle, savings-based priority, what ffmpeg actually does to each file, and the three-layer CPU budget."
section: "User Guide"
order: 50
---

A transcode job moves through a strict lifecycle: the server enqueues it with a frozen settings snapshot, a worker claims it, transcodes into staging, uploads the result, and the server verifies before replacing the original. This page covers the queue and the encode; [Verification](./verification) covers the gates.

## Job lifecycle

Three job types share one queue (`JOB_TYPES`):

| Type | Execution | Purpose |
|------|-----------|---------|
| `library-scan` | In-process on the server | Walk a root, probe files, update the cache |
| `transcode` | Claimed by a worker over HTTP | One file: encode → upload → verify → replace |
| `bulk-enqueue` | In-process on the server | A ruleset-driven run that enqueues eligible files across a library |

A transcode job moves through a strict lifecycle:

```text
queued → running (claimed by a worker) → succeeded / failed (after verification)
```

While running, its `result` reports the visible stage: `downloading` → `transcoding` → `uploading`, then `verifying` once the server accepts the upload (mount-mode jobs start at `transcoding` — there is no download leg).

- **Cancel:** a queued job can always be cancelled. A running job held by a worker (live lease) is cancelled and its lease cleared — the worker's next heartbeat fails and it aborts. A running job under **server-owned verification** (lease cleared after upload) cannot be cancelled: 409.
- **Retry:** failed transcodes can be retried (`POST /api/jobs/:id/retry`) — the job returns to queued with attempts reset, its frozen payload untouched.
- **Delete:** only terminal jobs (succeeded / failed / cancelled) can be deleted; deletion removes the job and its history rows together.
- **One active job per file** is enforced by the database — a second enqueue for the same file answers 409 (see [Database](./database#one-active-job-per-file)).

## Priority and the estimator

Jobs are claimed **highest expected savings first**: priority is the expected savings in bytes (`size × savings%`), snapshotted at enqueue. Ties break FIFO; legacy jobs without a priority sort last. Concretely: a 10 GB file estimated at 50% savings (priority ≈ 5 GB) is claimed before a 2 GB file estimated at 60% (≈ 1.2 GB) — absolute bytes saved, not percent.

The estimate comes from a heuristic estimator (codec × resolution × source-bitrate correction), then a **calibration loop** corrects it from real outcomes: every verified replace folds the realized size ratio into machine-learned factors, per codec/resolution bucket and globally. In user terms: the predictions get better as the archive gets processed, and the queue re-ranks itself when the global factor drifts by 2% or more. The calibration data is machine-managed — you can watch it on the Stats page but never edit it. Details and exact formulas: [Transcode engine](./transcode-engine).

## What ffmpeg does

The worker builds one ffmpeg command per job from the frozen payload:

- **Video:** re-encode to h265. CPU path uses libx265 with the preset ladder (default `medium`) and CRF (default 23). Hardware paths map quality per encoder:

| Encoder | Quality mapping | Notes |
|---------|-----------------|-------|
| libx265 (CPU) | `-crf <crf> -preset <preset>` | x265 `pools=` derived from the CPU budget |
| hevc_nvenc | `cq = clamp(crf + 10, 1, 51)` | `-tune hq -rc-lookahead 32 -spatial-aq 1` |
| hevc_qsv | `icq = clamp(crf + 2, 1, 51)` | Preset mapped from the x265 ladder |
| hevc_vaapi | QP mapped from CRF | Scale runs before the hardware upload |
- **Resolution cap:** when `max_resolution` is set, one software scale filter caps the output height — `scale=w=-2:h='min(<cap>,ih)':force_divisible_by=2`. The `min()` guard means it **never upscales**; aspect ratio stays intact and dimensions stay even. 10-bit/HDR sources stay 10-bit/HDR — no tonemapping, no pixel-format change.
- **Audio: never re-encoded.** Every audio stream is stream-copied, always.
- **Subtitles:** MP4/MOV-family `mov_text` tracks convert to SubRip (they cannot stream-copy into Matroska); every other subtitle codec stream-copies. Verification expects exactly that conversion.
- **Attachments and chapters:** stream-copied and preserved; the stream-match gate counts them.
- **Container:** output is MKV unconditionally, whatever the source.

## CPU budgets

"Use half the CPU" must mean **exactly half**. Three layers enforce the budget, set on the worker (compose `cpus` quota or `MORPHEUS_WORKER_CPUS`), advertised at registration, and respected by the server when assigning work:

1. **cgroup quota** — the worker reads `/sys/fs/cgroup/cpu.max`; a Docker `cpus: 4` limit is enforced by the kernel and cannot be overshot.
2. **CPU affinity** — without a quota, the worker pins ffmpeg to a core set via taskset: half the CPU = half the cores pinned, also kernel-hard.
3. **ffmpeg thread caps** — `-threads`, x265 `pools=`, and decode/filter thread counts derive from the budget. On hardware paths the encode runs on the GPU, so the caps move to where the CPU cycles actually go: the decoder and the filter graph.

The first two layers are hard; the third is best-effort on top. The effective cap is surfaced in the worker's capabilities.

## Interrupted jobs

An interrupted transcode **restarts from scratch** on requeue — there is no resume from partial output. If a worker crashes mid-job, its lease expires, the sweep requeues the job (attempts incremented), and another worker picks it up from the beginning. The original is untouched throughout, and per-attempt staging names keep a stale in-flight upload from colliding with the successor. See [Workers](./workers) for the lease mechanics.
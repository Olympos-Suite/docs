---
title: "Verification Internals"
description: "verifyAndReplace gate semantics, the single-flight queue, decode budgets and thread resolution, NVDEC fallback, VMAF parsing, and the M1 replace."
section: "Developer Guide"
order: 40
---

`VerifyService.verifyAndReplace({ jobId, workerId })` is the server-side trust boundary. It runs detached after upload acceptance, **never throws**, and finalizes the job row itself (succeeded with realized savings, or failed with the rejecting gate) plus the run log copied to `job_history` via a fresh `JobLogger`.

## The verifyAndReplace seam

Entry is defensive: a vanished job row is logged and skipped; a row no longer `running` or no longer held by the expected worker (requeued or finalized underneath — e.g. a boot-requeue race) is **logged-and-skipped**, never finalized twice. Ownership transferred conditionally at accept time, so this check is the backstop, not the primary guard.

## Gate error semantics

Seven gates, in order; each failure deletes staging and marks the job terminally failed, original untouched:

| # | Failure | Error |
|---|---------|-------|
| 1 | Staging missing | `VerificationError('staging file missing after upload')` |
| 2 | Probe ≠ hevc/mkv | `VerificationError('output video/codec mismatch')` |
| 3 | Fresh original probe ≠ enqueued h264 source, or duration outside tolerance | `VerificationError('duration mismatch')` (N5 out-of-band swap fails here) |
| 4 | `describeStreamMismatch` non-null | `VerificationError('stream mismatch: …')` — audio count/codecs in order, subtitle codecs with the `mov_text` → `subrip` exception, attachment/chapter counts |
| 5 | Decode pass not clean | `VerificationError('full decode failed (…)')` / `'light decode (head\|tail) failed (…)'` |
| 6 | Staging > original × (1 − threshold/100) | **`SavingsThresholdError`** — a distinct subclass, never message matching, so no other gate can stamp the permanent marker |
| 7 | VMAF compare error / score below floor | `VerificationError('VMAF gate error: …')` / `'VMAF score … below floor …'` — distinct messages, both terminal |

Gate 6's marker write (`#markTranscodeRejected`) is best-effort and idempotent; a re-failure refreshes the timestamp. The rejection logs an evidence line comparing staging size against the payload's estimate snapshot. Threshold and decode mode come from the **frozen payload** (legacy → global settings); hw policy, threads, light seconds, and tolerance stay live globals. Gate 3 re-probes the original fresh; gate 6 stats the original again (`original file vanished before the replace` is its own failure).

## The single-flight queue

Serialization lives in `TranscodeJobService`: a `#verifyQueue` array + `#verifyInFlight` flag allow **at most one** `verifyAndReplace` at a time (A.12 #7). Accepted uploads push `{jobId, workerId}`; each starts on `setImmediate`; a settled verify advances the queue FIFO. The limit is **fixed at 1 — no settings key**. Concurrent full decodes would starve a weak management CPU. The queue depth is logged at accept time; jobs waiting show the `verifying` stage. The defensive ownership check above handles rows requeued/finalized while queued.

## Decode budgets

```ts
scaledDecodeBudgetMs = max(
  DECODE_TIMEOUT_MS,                          // 30 min — floor + hang guard
  durationSeconds * DECODE_BUDGET_FACTOR * 1000 + DECODE_BUDGET_MARGIN_MS
)                                             // factor 2, margin 10 min
```

Measured on a 1-core cgroup node: 4K HEVC full decode runs ≈ 1.05× media duration — the flat 30-minute guard timed out every feature-length verify, hence the scaling (A.12 #6). Branching: `job_max_wall_seconds > 0` → each decode pass shares the job's wall budget; 0 → the scaled budget. Light passes get the **same** per-pass budget (it is a hang guard, not a work estimate). The VMAF compare gets the scaled budget **× 2** (both inputs decoded) or the job budget when set.

## Decode thread resolution

`resolveVerifyDecodeThreads` feeds both decode paths (full-decode gate and VMAF compare):

- Explicit 1–16 passes through clamped; **explicit always wins**, no detection runs.
- 0 = auto: `clamp(min(cgroup-effective cores, RAM ceiling), 1, 16)`.
  - cgroup-effective cores: quota (`cpu.max` / v1 quota÷period) AND cpuset present → min of both; one present → that one; neither → `os.availableParallelism()`. Fractional quota floors, minimum 1. Readers fail open — resolution never throws.
  - RAM ceiling = `max(1, floor(totalMemGiB / 2))` — measured ~0.2 GiB per decode thread at 4K HEVC. A 4 GiB NAS auto-resolves to 2 **even with a misconfigured CPU quota**; 32 GiB buys the full 16.
- The hard 1–16 clamp matches ffmpeg's frame-threading ceiling.

## NVDEC fallback

`verify_hw_decode: auto` tries `hevc_cuvid`; the adapter falls back to software **only on init-class failures** (one shot). Decode errors are fail-closed — they fail the gate, never retry in software. Spawn-level failures (missing binary, nice exit 126/127) are classified separately from decode errors. Every verification spawn — decode and VMAF — runs under `nice -n 19` (nice execs ffmpeg in the same process, so the child argv is unchanged and the kill-timeout still reaches ffmpeg).

## VMAF parsing

The compare runs `libvmaf` with reference = original, distorted = staging. Score extraction reads the **pooled stderr** for the `VMAF score:` line — libvmaf's `log_path=-` writes the log to stderr, a quirk the parser owns. Missing libvmaf filter, exec error, timeout, or unparseable output → `VMAF gate error` (terminal, fail-closed); a parsed score below the floor → the distinct quality rejection. Floor default is 90 when the payload enables the gate without a number (D-C1). The global `vmaf_min_score` setting defaults to 0 (gate off) and governs rule-less single-file enqueues; 90 is the ruleset-side fallback floor, not the global default.

## The M1 replace

Pass → `trashService.linkToTrash` (hard-link the original into `<root>/.morpheus-trash/` under a collision-safe name) → `rename(2)` staging onto the original path → keep or immediately unlink the trash entry per settings. Same filesystem → guaranteed atomic; **the original path is never absent**. Crash windows: between link and rename → original intact + an orphan trash link; between rename and unlink → replacement live + an orphan trash link. Both orphans purge by mtime. Post-replace, a fresh stat + re-probe updates the probe-cache row in the atomic success commit (estimates go NULL — an h265 file never re-ranks); a failed final re-probe keeps the staging probe values.

## Boot orphan cleanup

After `finalizeStaleJobs` (in-process → failed, worker rows → `requeueAtBoot` under the attempts cap), `purgeOrphanedStagingOutputs` removes staging outputs whose job is no longer active (not queued/running) **or was requeued at boot** — a requeued job restarts from scratch, so its old upload is garbage. Anything under a live running job is never touched; removals log byte sizes. The daily `trash-purge` job additionally sweeps orphaned staging older than the retention cutoff (N6), so the directory cannot grow unbounded between boots.

## Constants

| Constant | Value | Defined in |
|----------|-------|------------|
| `DECODE_TIMEOUT_MS` | 30 min (floor + hang guard) | `adapters/ffmpeg.ts` |
| `DECODE_BUDGET_FACTOR` | 2 | `services/verify-service.ts` |
| `DECODE_BUDGET_MARGIN_MS` | 10 min | `services/verify-service.ts` |
| `DEFAULT_VMAF_MIN_SCORE` | 90 (D-C1 fallback floor; global `vmaf_min_score` defaults to 0 = gate off) | `services/verify-service.ts` |
| `MAX_VERIFY_DECODE_THREADS` | 16 (ffmpeg frame-threading ceiling) | `lib/verify-threads.ts` |
| Verification concurrency | 1, fixed — no settings key | `services/transcode-job-service.ts` |
| Upload lease watchdog | 2 s cadence | `routes/worker-routes.ts` |
| Upload body limit | 1 TiB (effectively disabled) | `routes/worker-routes.ts` |
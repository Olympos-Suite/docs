---
title: "Invariants"
description: "The non-negotiable rules Morpheus enforces in code and schema, and where each one is enforced."
section: "Developer Guide"
order: 70
---

These rules bind every change. They are owner-locked decisions (morpheus.md D.1, D.4, D.6) — a deviation is a bug, not a design choice. Each entry names where the rule is enforced, because none of them relies on code review alone.

## Verification before replace

The original is never touched until **every gate passes server-side**. Workers only produce staging files; `verifyAndReplace` on the management server is the sole path to a replace. Enforced by the seam itself: the replace call sits after gate 7, and no worker endpoint can write to an original path. See [Verification internals](./verification-internals).

## Atomic rename, original never absent

The M1 pattern: hard-link the original into trash **first**, then `rename(2)` staging onto the original path — same filesystem, guaranteed atomic. There is no window where the original path is absent while its only copy is staging. Crash windows leave at most an orphan trash link, purged by mtime. Enforced in `VerifyService.#replaceOriginal` + `TrashService.linkToTrash`.

## Never lose data

Any verification failure deletes the staging file, marks the job failed, and keeps the original intact. Interrupted uploads are deleted by the lease watchdog; boot cleanup removes only orphaned staging, never live-job outputs. The trash retains replaced originals for `trash_retention_days` (default 7) unless the operator explicitly opts into immediate deletion.

## One active job per file

A partial UNIQUE index on `jobs.media_file_id` (queued/running rows only) makes double-queuing impossible at the database level; UNIQUE violations map to 409. Bulk enqueue, rule assignment, and manual transcode all race through the same constraint. See [Database](./database#one-active-job-per-file).

## One-way h264 → h265 only

The reverse direction was removed by owner decision (2026-11-11) and is not coming back. `TRANSCODE_TARGET_CODECS = ['hevc']` — the ban is **type-level**: rules carry no direction field, the route body rejects other targets with 400, and a legacy h264-target payload degrades to hevc at parse. An output that is not hevc/mkv terminal-fails the codec gate, original untouched.

## Savings-threshold failure is the only permanent marker

Gate 6 alone stamps `media_files.transcode_rejected_at` — a distinct `SavingsThresholdError` subclass, never message matching, so no other gate (decode, stream, duration, VMAF) can mark a file. Marked files are never auto-selected again; manual transcode stays allowed; a changed ruleset assignment or a successful replace clears the marker. No historical backfill.

## Interrupted transcodes restart from scratch

No resume from partial output, ever. Lease expiry or boot requeue increments attempts and hands the job to a worker from the beginning; per-attempt staging names (`<jobId>.a<attempts>.mkv`) isolate successor uploads from stale bytes. The scratch-wipe on worker startup is **transfer-only** — a mount worker never wipes a shared staging root.

## CPU budget exactness

"Use half the CPU" means exactly half, via three layers: kernel cgroup quota, taskset affinity when no quota exists, and ffmpeg thread/pool caps derived from the budget. The first two are kernel-hard; the worker advertises the effective budget at registration and the server respects it when assigning work. Verification decodes are separately capped by cgroup cores **and RAM** (`verify_decode_threads` auto) and run under `nice -n 19`.

## Serialized verification

At most one `verifyAndReplace` executes at a time; further accepted uploads wait FIFO (`#verifyQueue`, limit fixed at 1, no settings key). Concurrent feature-length decodes would starve a weak management CPU. Rows requeued or finalized while queued are logged-and-skipped by the defensive ownership check.

## No auto-enqueue on scan

Scanning discovers and probes; it never enqueues transcodes (the Phase 3 manual-apply decision stands). Work enters the queue only via ruleset assignment or manual transcode. After a replace, the re-probe sees h265 and the file never ranks again — the pipeline cannot loop on its own output.

## /config is the only backup-worthy volume

The SQLite DB, settings, session secret, and worker key live under `/config`; everything else is rebuildable — media is the operator's archive, GPU cache re-downloads, staging is transient, trash is retention-limited. Keeping the GPU cache outside `/config` is deliberate: config backups stay lean.

## Enforcement at a glance

| Invariant | Enforced by | Kind |
|-----------|-------------|------|
| Verification before replace | `verifyAndReplace` seam; workers have no write path to originals | Code structure |
| Atomic rename | M1 link-then-rename, same-filesystem `rename(2)` | Filesystem semantics |
| Never lose data | Gate failure paths, lease watchdog, boot orphan cleanup | Code |
| One active job per file | Partial UNIQUE index → 409 | **Database** |
| One-way codec | `TRANSCODE_TARGET_CODECS = ['hevc']`, Zod body, gate 2 | **Type system** + code |
| Permanent marker only at gate 6 | `SavingsThresholdError` subclass (no message matching) | Code |
| Restart from scratch | Requeue semantics + per-attempt staging names | Code |
| CPU budget exactness | cgroup quota + taskset + thread caps | **Kernel** + code |
| Serialized verification | `#verifyQueue` / `#verifyInFlight`, limit 1 | Code |
| No auto-enqueue on scan | Scan engine has no enqueue call; assignment/manual only | Code structure |
| Lean backups | GPU cache path outside `/config` | Deployment layout |

A change that touches any of these is accepted only with its regression suite green — `transcode-flow`, `verify-replace-failure`, `two-worker-requeue`, `verify-serialization`, and the CPU-budget spike above all. See [Testing](./testing).
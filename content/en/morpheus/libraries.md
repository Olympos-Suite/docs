---
title: "Libraries and Scanning"
description: "Archive roots, the ffprobe cache and its fingerprint, enqueue eligibility, and the queue controls that govern transcode work."
section: "User Guide"
order: 30
---

A **library** is one archive root — a directory tree of media files you want kept storage-optimal. Morpheus scans it, probes every file with ffprobe, caches the results, and ranks files by expected savings. Nothing is transcoded until you enqueue it, directly or through a [ruleset](./rulesets).

## Adding a library

Add roots on the Libraries page (or `POST /api/libraries` with a name and an absolute `rootPath`). In Docker, mount the archive into the management container first — for example `/mnt/media/archive:/data/archive:rw` — and register the container-side path. Each root must be unique. Removing a library deletes its probe-cache rows; the media files themselves are never touched.

## Scanning and the probe cache

A scan (`POST /api/libraries/:id/scan`, or the scan button) walks the root and probes each file with ffprobe: codec, resolution, bitrate, duration, container, size. Results land in the `media_files` probe cache. A scan is a `library-scan` job running **in-process on the server** — not on a worker — and shows on the Jobs page like any other job.

- **Fingerprint:** `relPath + sizeBytes + mtimeMs`. A file whose fingerprint is unchanged is never re-probed — rescans are cheap.
- **Concurrency:** `max_concurrent_probes` (default 4) files are probed at once.
- **One scan at a time:** starting a scan while one is queued or running for the library answers 409.
- **No ffprobe?** Scans still run and count probe errors; unprobed files simply cannot be enqueued.

The estimator computes an expected h265 size and savings percentage for every probed file it can improve (see [Transcode engine](./transcode-engine)). Files already in hevc or av1 — or any codec outside the estimator's table — get no estimate and never rank.

## The file table

The per-library Files page shows the probe cache, savings-ranked by default:

| Column | Meaning |
|--------|---------|
| Path | Relative path within the library root |
| Video codec / resolution | Probed codec, width × height |
| Size | Current size in bytes |
| Expected savings | Calibrated estimate, percent and projected output size |
| Probe status | When the file was last probed |
| Transcode status | Active job state, or the last outcome |
| Rule | Assigned ruleset override, if any |

Row actions: manual transcode, assign/remove a ruleset, and (for bulk operations) multi-select assignment of one ruleset to up to 500 files. Sort orders: `savings_desc` (default), `size_desc`, `path_asc`, `probed_desc`; pagination is URL-driven, so filters survive navigation.

## What can be transcoded

Enqueue eligibility is narrow on purpose:

- The file must be **probed** and its video codec must be **h264**.
- **Any source container** is accepted — mkv, mp4, avi, mov, m4v, ts, webm, and so on.
- The output is **always MKV**, unconditionally. MP4-family `mov_text` subtitle tracks convert to SubRip; everything else stream-copies.

The reverse direction (h265 → h264) does not exist. A file that is already h265 is storage-optimal for this pipeline and is never a candidate.

## No auto-enqueue on scan

Scanning **never enqueues transcodes** — that is a deliberate manual-apply decision. Work enters the queue in exactly two ways:

1. **Ruleset assignment** — assigning a ruleset to a file enqueues it immediately when eligible; assigning one to a library starts a bulk-enqueue run (see [Rulesets](./rulesets)).
2. **Manual transcode** — the per-file action, which uses the resolved ruleset or the global fallback.

## After a successful replace

When verification passes and the atomic replace completes, the server re-probes the final file and updates the cache row in the same commit. The re-probe sees **h265**, the estimate goes NULL, and the file never ranks or re-queues again. The library's `realized_savings_bytes` counter grows by the verified difference — the Stats page charts it per day.

A file rejected by the savings-threshold gate keeps its original and carries a permanent no-auto-retry marker; see [Verification](./verification#savings-threshold-rejection).

## Queue controls

`queue_mode` governs whether workers may claim new work:

| Mode | Behavior |
|------|----------|
| `running` | Claims are handed out normally. |
| `paused` | No new claims; running jobs keep their leases and finish. |
| `draining` | No new claims; the queue waits for running jobs to finish. |

Combine it with the nightly schedule window (`schedule_window_start` / `schedule_window_end`, Settings → Jobs & Scheduling) to confine transcodes to off-hours — outside the window, claims are refused immediately. The mode switcher lives in the Jobs page header and applies immediately; the window bounds are a settings edit.
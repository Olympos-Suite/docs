---
title: "Transcode Engine"
description: "Estimator formulas, the calibration loop, priority computation, payload freezing, and ffmpeg argument construction per encoder class."
section: "Developer Guide"
order: 30
---

The engine is pure where it can be: the estimator (`lib/estimate-h265.ts`) and calibration math (`lib/calibration.ts`) are I/O-free and shared by every enqueue site, the lease-sweep re-rank, and the boot backfill. The ffmpeg runner (`worker/transcode.ts`) builds one argument sequence per assignment from the frozen payload.

## The estimator

Estimator v1.1 predicts the h265 output size from codec, width, and source bitrate:

```text
ratio = clamp(0.12, 0.92, base[codec] × resolutionMultiplier × bitrateFactor)
bitrateFactor = clamp(0.55, 1.6, sqrt(referenceBps[bucket] / sourceBitrateBps))
expectedSizeBytes = round(sizeBytes × ratio)
expectedSavingsPercent = round((1 − ratio) × 1000) / 10
```

Base ratios per source codec:

| Codec | Base ratio |
|-------|-----------|
| h264 | 0.5 |
| mpeg4 | 0.45 |
| mpeg2video | 0.45 |
| vp8 | 0.55 |
| vp9 | 0.65 |

hevc, av1, and any unknown codec return **null** — nothing this pipeline can improve. (Only h264 is enqueues-eligible; the other ratios exist for estimation.) Resolution buckets keyed by width:

| Bucket | Min width | Multiplier | Reference bitrate |
|--------|-----------|------------|-------------------|
| `3600` | 3600 | 0.9 | 18 Mbps |
| `1900` | 1900 | 1.0 | 5 Mbps |
| `1200` | 1200 | 1.1 | 2.5 Mbps |
| `smallest` | below / unknown | 1.25 | 1.2 Mbps |

The bitrate correction is the v1.1 addition: fat sources compress harder (factor < 1), lean sources have less to squeeze (factor > 1). A missing/non-positive bitrate keeps factor 1.0 (exact v1 behavior). Bitrate is **bits per second end to end** — ffprobe's `format.bit_rate` stored unchanged in `bitrate_bps`. The percent derives from the ratio, not the rounded bytes, so ranking stays stable for tiny files.

## Calibration

Every verified replace folds one realized ratio (`newSizeBytes / estimatedSizeBytes`) into the machine-managed `estimator_calibration` blob:

- **EMA** with α = 0.25 on both the bucket factor and the global factor: `factor += 0.25 × (ratio − factor)`, hard-clamped to **[0.5, 2.0]**.
- Buckets key `codec:resolutionBucket` (e.g. `h264:1900`), sharing the estimator's bucket definition. A factor is trusted from **n ≥ 2 samples** (`MIN_BUCKET_SAMPLES`, owner-lowered from 5 so calibration kicks in before a large overnight run enqueues on a wrong factor); below that, bucket → global → 1.0.
- Global `mae` is the running mean of |ratio − 1| × 100 (percent).
- **Re-rank trigger:** the lease sweep recomputes queued priorities when the effective global factor moves ≥ 2% (`RERANK_TRIGGER_DELTA = 0.02`) from `lastRecomputeFactor`.

Calibrated values: `calibratedSize = expectedSizeBytes × factor`; `calibratedPct = 100 × (1 − (1 − rawPct/100) × factor)`, rounded to the estimator's 1-decimal precision so threshold comparisons never flip on binary-fraction noise. The blob is never user-writable — absent from `UpdateSettingsBody`, so a PATCH attempt is a silent no-op.

## Priority

Claim priority is the **expected-savings bytes** snapshot, computed from the payload alone:

```text
originalBytes = estimatedSizeBytes / (1 − expectedSavingsPercent/100)
priority = round(originalBytes − estimatedSizeBytes × factor)
```

The second form uses only payload fields, so the sweep re-ranks set-based without touching `media_files`. NULL estimate or degenerate percent (≥ 100) → NULL priority, which sorts last (the FIFO tail). Claim order: `priority DESC`, then `(created_at, id)` FIFO, served by a partial index scoped to queued transcode rows.

## Payload freeze

At enqueue, the merged file → library → global knob set is frozen into `jobs.payload`: crf, preset, thresholdPercent, verifyDecodeMode, hwPreference, vmafEnabled/vmafMinScore, maxResolution, sourceContainer, plus the RAW estimate snapshot. **Claim and verification read frozen values**, never live settings or ruleset rows. The ruleset-model fields are optional with no static default: a legacy payload parses without them and the consumer falls back to the matching global setting. `hwPreference` is also denormalized to the `jobs.hw_preference` column for SQL-side claim filtering.

## ffmpeg argument construction

One software scale filter on every encoder class when the cap is set:

```text
scale=w=-2:h='min(<cap>,ih)':force_divisible_by=2
```

The `min()` guard never upscales; VAAPI scales in system memory **before** its `format=nv12|vaapi,hwupload` chain. 10-bit/HDR frame side data rides through — no tonemapping, no pix_fmt change. With the cap off, every block stays byte-identical to the frozen pre-cap sequence (snapshot tests are the regression guard).

Per-class video blocks:

| Class | Quality mapping | Thread caps |
|-------|-----------------|-------------|
| none (libx265) | `-crf <crf> -preset <preset>` | `-threads N` + `-x265-params pools=<derived>` |
| qsv | `-global_quality clamp(crf + 2, 1, 51)`, preset mapped from the x265 ladder | `-filter_threads N` |
| vaapi | `-qp` mapped from CRF | `-filter_threads N` |
| nvenc | `-cq clamp(crf + 10, 1, 51)` with `-tune hq -rc-lookahead 32 -spatial-aq 1` | `-filter_threads N` |

The NVENC +10 offset was adopted 2026-11-16 from real-hardware ladder tests (it supersedes the early Phase 4A `crf + 4`); cq 0 would mean "automatic", hence the 1–51 clamp. On hw paths the encode runs on the GPU, so the CPU budget caps the **decoder** (`-threads` before `-i`) and the filter graph instead of x265 pools. Thread/pool counts derive from the three-layer budget (cgroup quota → cpuset affinity → flags). Audio always stream-copies; mp4-family `mov_text` subs convert with `-c:s srt`; attachments/chapters copy; `-progress pipe:1` key=value lines drive progress.

## The one-way codec gate

`TRANSCODE_TARGET_CODECS = ['hevc']` — h264 was removed from the type when the reverse direction was deleted (2026-11-11). The manual route's Zod body rejects any other target with 400. A **legacy payload** still carrying `targetCodec: 'h264'` degrades to `'hevc'` at parse (`.catch('hevc')`) instead of failing the whole payload; an output that is not hevc/mkv terminal-fails verification gate 2 with the original untouched. Rules carry no direction field at all.
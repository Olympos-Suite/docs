---
title: "Verification"
description: "The seven sequential gates every output must pass, the permanent savings rejection, and the atomic replace with trash retention."
section: "User Guide"
order: 60
---

Verification is the trust boundary. It runs **server-side** after a worker's upload is accepted — never on the worker — and the original file is not touched until every gate passes. Any failure deletes the staging file, marks the job failed, and leaves the original intact.

## The seven gates

Gates run in order; the first failure ends the job.

| # | Gate | What it checks |
|---|------|----------------|
| 1 | Staging exists | The uploaded output is present on disk. |
| 2 | Codec + container | Output video is **hevc** and the container is **mkv**. |
| 3 | Duration | Within `verify_duration_tolerance_percent` of a **fresh probe of the original** — which must still be the enqueued h264 source (an out-of-band swap fails here). |
| 4 | Stream match | Audio count and per-stream codecs in order, subtitle count and codecs (with the `mov_text` → SubRip exception), attachment count, chapter count. |
| 5 | Decode | Full / light / off per the frozen payload; hardware decode per `verify_hw_decode`. See below. |
| 6 | Size | Staging ≤ original × (1 − threshold/100), using the **frozen** threshold. The only gate that permanently marks the file. |
| 7 | VMAF (optional) | Quality score ≥ floor, original as reference vs staging as distorted. Off by default; fail-closed. |

Every outcome, at a glance:

| Outcome | Staging file | Original | Job | File marker |
|---------|--------------|----------|-----|-------------|
| Gates 1–5 or 7 fail | Deleted | Untouched | Failed (retryable) | None |
| Gate 6 (threshold) fails | Deleted | Untouched | Failed | **Permanent no-retry** |
| Worker crash / lease expiry | Orphan cleaned at boot or by purge | Untouched | Requeued (attempts + 1) | None |
| All gates pass | Renamed onto original | Hard-linked into trash | Succeeded | Cleared |

> [!NOTE]
> The VMAF gate needs an ffmpeg built with libvmaf. The management image vendors a pinned BtbN build that includes it; a custom `ffmpeg_path` is operator-supplied and must carry libvmaf itself — otherwise the gate fails closed with a "VMAF gate error".

## Savings-threshold rejection

Gate 6 is special. When the output saves less than the threshold, the file is stamped with a **permanent no-retry marker** (`transcode_rejected_at`):

- The encode proved the cached estimate unreachable, so the file is **never auto-selected again** — bulk runs and savings ranking skip it.
- The staging file is deleted, the original kept, the job marked failed.
- **Manual transcode stays allowed** — the marker blocks auto-selection only.
- Assigning a *different* ruleset clears the marker (a new profile is a new chance); a successful replace clears it too.

A gate-6 rejection happens **before any replace**, so no trash entry is created — `trash_immediate_delete` is irrelevant to rejections.

No other gate marks the file. Decode errors, stream mismatches, duration drift, and VMAF failures are all retryable job failures — the file remains a normal candidate.

> [!NOTE]
> A rejection is information, not a malfunction: the file is already near-optimal for this pipeline. Check the CRF/preset if you expected more savings, or accept the marker.

## Decode modes and hardware decode

The decode gate (gate 5) catches truncation and corruption that probes cannot see:

- **`full`** (default) — decodes every frame of the output. The original guarantee.
- **`light`** — decodes only the first and last `verify_light_seconds` (default 60 s); both passes must exit clean. The unverified middle is a deliberate trade-off — see the warning below.
- **`off`** — skips the decode gate entirely. Every other gate still applies.

> [!WARNING]
> In `light` mode the middle of the file is **never decoded** — corruption there passes the gate and the original gets replaced. Use it only when you accept that trade-off.

`verify_hw_decode: auto` uses NVIDIA NVDEC (`hevc_cuvid`) when it can initialize — dramatically lower RAM on GPU hosts — with a one-shot software fallback **only on init-class failures**. Decode errors never trigger the fallback; they fail the gate (fail-closed). `off` always decodes in software.

The decode mode is frozen per job at enqueue; hardware policy, thread count, light seconds, and duration tolerance stay live global settings.

## Time budgets

A full decode is CPU-bound and runs at roughly realtime-or-slower on weak nodes. With the watchdog off (`job_max_wall_seconds: 0`), each decode pass gets a budget scaled to the output's duration: **2 × duration + 10 minutes, never below 30 minutes**. The flat 30-minute floor stays as the hang guard for short files. With `job_max_wall_seconds > 0`, decode passes share the job's wall-clock budget instead. The VMAF compare gets twice the scaled budget — it decodes both inputs.

## One verification at a time

Verification is **serialized**: at most one `verifyAndReplace` runs at a time; further accepted uploads wait in a FIFO queue (their jobs show the `verifying` stage). Concurrent feature-length decodes would starve a weak management CPU. The limit is fixed at 1 — there is no settings key.

Two protections keep the API responsive on small nodes:

- Every verification spawn runs under `nice -n 19`, so a decode cannot starve the API event loop.
- Decode threads auto-cap from the node's cgroup cores and RAM (`verify_decode_threads: 0`) — a 4 GiB NAS resolves to 2 threads, not the host's 16. See [Troubleshooting](./troubleshooting#low-memory-management-nodes).

## Replacement and trash

When all gates pass, the replace follows the **M1 link-then-rename** pattern:

1. **Hard-link** the original into `<root>/.morpheus-trash/` — the original path keeps serving data.
2. **Atomically rename** the staging file onto the original path (`rename(2)`, same filesystem). The original path is never absent while its only copy is staging.
3. Keep the trash link for `trash_retention_days` (default 7), or unlink it immediately when `trash_immediate_delete` is true.

The daily trash-purge job removes expired trash entries by mtime and sweeps orphaned staging uploads.

**Boot-time orphan cleanup:** after the stale-job sweep (in-process jobs finalized as failed, worker jobs requeued), the server removes staging outputs whose job is no longer active or was requeued at boot — a requeued job restarts from scratch, so its old upload is garbage. Anything under a live running job is never touched; removals are logged with byte sizes.
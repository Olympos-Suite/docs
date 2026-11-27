---
title: "Rulesets"
description: "Reusable quality, speed, and verification profiles: the resolution chain, immediate enqueue on assignment, and bulk library runs."
section: "User Guide"
order: 40
---

**Rulesets** are reusable global settings profiles. A ruleset carries quality, speed, and verification knobs; every nullable field inherits the matching global setting. They are not bound to libraries — you assign them per file (override) or per library (default), and the merged result is frozen into each job at enqueue. Manage them on the Rules page or via `/api/rules`.

## Ruleset fields

| Group | Field | Values | NULL means |
|-------|-------|--------|------------|
| Quality | `crf` | 0–51 | Inherit `transcode_crf` |
| Quality | `maxResolution` | `off`, `2160`, `1440`, `1080`, `720` | Inherit `max_resolution` |
| Speed | `preset` | x265 ladder `ultrafast` … `veryslow` | Inherit `transcode_preset` |
| Speed | `hwPreference` | `any`, `hw`, `cpu` (default `any`) | — (not nullable) |
| Verification | `thresholdPercent` | 0–100 | Inherit `savings_threshold_percent` |
| Verification | `vmafEnabled` | boolean (default `false`) | — (not nullable) |
| Verification | `vmafMinScore` | 0–100 (default `90`) | — (used when VMAF is enabled) |
| Verification | `verifyDecodeMode` | `full`, `light`, `off` | Inherit `verify_decode_mode` |

A ruleset also has an `enabled` flag: **disabled rulesets are rejected with 409 on every assignment path**. `hwPreference` pins which worker class may claim the job — a `hw`-pinned rule never reaches a CPU-only worker, and vice versa (the filter runs SQL-side, so one class cannot starve the other).

> [!NOTE]
> Enabling VMAF on a ruleset requires a libvmaf-capable ffmpeg on the management server (`ffmpeg_path`). The gate is fail-closed: a compare error fails the job. See [Verification](./verification). The global `vmaf_min_score` setting defaults to 0 (gate off) and governs rule-less manual enqueues only; a ruleset with VMAF enabled carries its own floor via `vmafMinScore`, defaulting to 90 when unspecified.

## The resolution chain

At enqueue, knobs resolve **file → library → global settings**:

1. The file's explicit ruleset override (`media_files.rule_id`), if set.
2. Otherwise the library default (`libraries.default_rule_id`), if set.
3. Otherwise the global settings.

The merged result — crf, preset, threshold, decode mode, hw preference, VMAF fields, resolution cap — is **frozen into the job payload**. Claim and verification read the frozen values, never live settings or ruleset rows, so mid-flight edits never touch in-flight jobs. Legacy payloads without a field fall back to the matching global setting.

> [!IMPORTANT]
> The chain picks **one winning ruleset** — the file override beats the library default outright; the two profiles are never merged with each other. The winner's NULL fields inherit the **global settings**, not the library default. Example: global CRF 23; the library default sets CRF 20; a file override sets only preset `slow`. That file enqueues with preset `slow` and CRF **23** (global), while its unoverridden siblings get CRF 20.

## Assigning to a file

Assigning a ruleset to a file (`POST /api/media-files/:id/rule`, or the Files page action) **immediately enqueues a transcode when the file is eligible**. Ineligible files answer a skip reason, never an error:

| Skip reason | Meaning |
|-------------|---------|
| `not-probed` | The file has no probe-cache entry yet — run a scan. |
| `not-h264` | The source codec is not h264 (already h265, or unsupported). |
| `active-job` | A transcode for this file is already queued or running. |
| `rejected` | The permanent savings-rejection marker is set and the assignment did not change. |
| `below-threshold` | The calibrated estimate does not meet the resolved threshold (or is missing). |

Two marker rules matter:

- Assigning a **different** ruleset clears the no-retry marker in the same atomic write — a new settings profile is a new chance. Re-assigning the **same** ruleset leaves the marker, so the file answers `rejected`.
- A successful replace also clears the marker.

The bulk action (`POST /api/media-files/rule`) applies the same per-file logic to 1–500 selected files and returns aggregated counters.

## Assigning to a library

Assigning a ruleset to a library (`POST /api/libraries/:id/rule`) does two things:

1. Sets the library's **default ruleset** — the fallback for files without an explicit override.
2. Starts **one whole-library bulk-enqueue run**: every eligible file is enqueued with the resolved knobs. Explicit per-file overrides win during the run.

The run's threshold is frozen into its payload, so a later settings change never mutates a run in flight. A second assignment while a bulk run is queued or running answers 409; a disabled ruleset answers 409 as everywhere else.

## Unassigning

Assigning `null` — to a file or a library — **only changes the fallback**. No job is enqueued, no running job is touched. The file simply resolves to the next level of the chain (library default, then global settings) on its next enqueue.

## Manual transcode without a ruleset

The per-file manual transcode keeps the global-fallback behavior when no ruleset is assigned: global settings resolve into the frozen payload like any other enqueue. Two deliberate differences from assignment:

- **No enqueue-time threshold gate** — the savings threshold still applies at verification, but a low-estimate file can be enqueued manually.
- **Rejected files stay manually transcodable** — the permanent marker blocks auto-selection only. A manual attempt that fails the threshold again simply refreshes the marker.
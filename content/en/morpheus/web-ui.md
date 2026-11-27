---
title: "Web UI"
description: "A tour of every Morpheus screen: dashboard, libraries, files, jobs, workers, rules, settings, API keys, and stats."
section: "User Guide"
order: 90
---

The web UI is served on port 3000 (host port 9699 in the example compose) and talks to the API through a same-origin proxy — the browser never needs the API port. All screens are dark-first and update live while jobs run.

| Route | Screen |
|-------|--------|
| `/` | Dashboard |
| `/libraries` | Libraries list |
| `/libraries/<id>` | Files table for one library |
| `/jobs` | Job queue + detail |
| `/workers` | Registered workers |
| `/rules` | Ruleset management |
| `/settings` | Tabbed settings |
| `/api-keys` | API key management |
| `/stats` | Savings history, calibration, accuracy |
| `/login`, `/setup` | Auth and first-run wizard |

## Login and first run

On a fresh install the **setup wizard** asks you to create the admin account (`POST /api/auth/setup`). After that, the login screen is CSRF-protected username/password auth with a 24-hour sliding session. Until setup completes, the API reports `SETUP_REQUIRED` for protected routes.

## Dashboard

The overview: quick stats cards for library count, file count, total archive size, realized savings, active jobs, and queue status. It is the landing screen and the fastest way to see whether work is moving.

## Libraries

The list of archive roots. Per library: add/edit, run a scan, assign the default ruleset (which also starts a bulk-enqueue run), and watch the realized-savings counter. Active scans and bulk runs show inline; queued transcodes appear as a badge. See [Libraries and scanning](./libraries).

## Files

The per-library file table: codec, resolution, size, expected savings percent, probe status, transcode status, and rule assignment, savings-ranked by default with sorting and pagination. Row actions: **manual transcode**, assign/remove a ruleset, and multi-select bulk rule assignment (1–500 files). Assignment outcomes are reported per file — the enqueued job id or the skip reason (`not-probed`, `not-h264`, `active-job`, `rejected`, `below-threshold`). Files below the savings threshold are dimmed as not worth re-encoding.

## Jobs

The job queue: id, type, status, progress (stage and percent), media file, worker, priority, and created/started/finished timestamps — filterable and paginated. The header carries the **queue board**: live transcode counts per status and the running / paused / draining mode switcher, applied immediately. The detail view shows the **full run log and the gate results**, so a failed verification names the exact gate that rejected the output. Queued and worker-held jobs can be cancelled; failed transcodes retried; terminal jobs deleted.

## Workers

Registered workers: name, online/offline status, capabilities (acceleration class, cores, GPU), current job, last seen, and the **effective file-access mode** (with an "override" badge when the server overrides the advertisement). Actions: inline rename (locks the display name against re-registration) and set/clear the server-side file-access override. The override wins over the worker's advertised mode on the next claim — see [Workers](./workers#file-access-override).

## Rules

Ruleset management: create/edit/delete the reusable profiles — quality (crf, max resolution), speed (preset, hardware preference), verification (threshold, VMAF enabled/floor, decode mode). Nullable fields inherit the global settings. The screen also shows assignment outcomes per file. See [Rulesets](./rulesets).

## Settings

The tabbed settings page exposes every user-writable key, grouped:

| Tab | Keys |
|-----|------|
| Quality | CRF, preset, max resolution, savings threshold, VMAF floor, and all verification keys (decode mode, light seconds, hardware decode, threads, duration tolerance) |
| Jobs & Scheduling | Night window, concurrent leases, wall-clock limit, lease seconds, attempts |
| Workers & Disk | Embedded worker enabled / staging dir / mounts, staging floor, headroom factor, trash retention and immediate delete |
| System | ffmpeg/ffprobe paths (with live ffprobe availability badge), probe concurrency, read-only storage info |
| Security | Password change |

Validation errors jump you to the tab containing the failing field. The machine-managed calibration blob is **not exposed** here — it lives read-only on the Stats page. Full reference: [Configuration](./configuration).

## API Keys

Create, list, and revoke worker API keys. On create, the **plaintext is shown exactly once** in a copyable dialog — only the sha256 hash and a display prefix are stored, so a lost key cannot be recovered, only revoked and replaced. Revoked keys stay listed for audit.

## Stats

Queue counts per status; per-library **daily realized-savings history**; the estimator **calibration view** (bucket factors, global factor, last recompute); and estimate-accuracy rows comparing predictions against realized outcomes. This is where you watch the estimator learn.

## Changing your password

`POST /api/auth/change-password` (Settings → Security) takes the current password and a new one (≥ 8 characters). Success **revokes every other session** of the user — other browsers are signed out — while the current session survives. A wrong current password is a validation error, not a lockout.
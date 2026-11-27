---
title: "Database"
description: "The SQLite schema: table reference, enums, the one-active-job partial index, payload snapshots, and the permanent rejection marker."
section: "Developer Guide"
order: 60
---

Morpheus uses SQLite through Drizzle (`packages/database`) — the only SQLite touchpoint in the codebase. The DB file lives under `CONFIG_DIR` (`/config` in Docker). Columns are snake_case, TS properties camelCase; UUID text primary keys; millisecond-precision integer timestamps; JSON-valued columns store JSON strings (serialization is the application's concern).

## Table reference

| Table | Key columns |
|-------|-------------|
| `libraries` | `id`, `name`, `root_path` (unique), `last_scan_at`, `realized_savings_bytes` (running counter of verified-and-replaced savings), `default_rule_id` (FK → rules, SET NULL) |
| `media_files` | `id`, `library_id` (FK, cascade), `rel_path`, `size_bytes`, `mtime_ms`, `video_codec`, `width`, `height`, `bitrate_bps`, `duration_seconds`, `container`, `probed_at`, `expected_savings_percent`, `expected_size_bytes`, `transcode_rejected_at`, `rule_id` (FK → rules, SET NULL). UNIQUE(`library_id`, `rel_path`) |
| `jobs` | `id`, `type`, `status`, `library_id` (SET NULL), `payload` (JSON), `result` (JSON), `error`, `created_at` / `started_at` / `finished_at`, `claimed_by_worker_id` (denormalized, no FK), `lease_expires_at`, `attempts`, `priority`, `media_file_id` (FK, SET NULL), `hw_preference` (default `any`) |
| `job_history` | `id`, `job_id`, `type`, `status`, `library_id`, `started_at`, `finished_at`, `log`. **No FKs** — history outlives deleted jobs and libraries |
| `workers` | `id`, `name` (unique), `name_locked`, `capabilities` (JSON), `gpu_info` (JSON), `file_access_override` (JSON), `last_seen_at`, `status` |
| `api_keys` | `id`, `name`, `key_hash` (sha256 hex, unique), `key_prefix` (display only), `created_at`, `last_used_at`, `revoked_at` |
| `rules` | `id`, `name`, `enabled`, `threshold_percent`, `crf`, `preset`, `max_resolution` (all nullable = inherit global), `hw_preference` (default `any`), `vmaf_enabled` (default false), `vmaf_min_score` (default 90), `verify_decode_mode` (nullable), `created_at`, `updated_at` |
| `settings` | `key` (snake_case, PK), `value` (JSON), `updated_at` |
| `users` | `id`, `username` (unique), `password_hash`, `role` (default `admin`), `created_at` |
| `sessions` | `id` (the session sid), `data` (JSON), `expires_at` — the SQLite session store |

The current job on a worker is a join, not a column; `claimed_by_worker_id` is deliberately denormalized so job rows outlive deregistered workers.

## Enums

Defined as `as const` arrays in `@repo/shared-types` (no TypeScript enums):

| Constant | Values |
|----------|--------|
| `JOB_STATUSES` | `queued`, `running`, `succeeded`, `failed`, `cancelled` |
| `JOB_TYPES` | `library-scan`, `transcode`, `bulk-enqueue` |
| `TRANSCODE_TARGET_CODECS` | `hevc` only — h264 removed with the reverse direction |
| `VERIFY_DECODE_MODES` | `full`, `light`, `off` |
| `VERIFY_HW_DECODE_MODES` | `auto`, `off` |
| `QUEUE_MODES` | `running`, `paused`, `draining` |

Worker presence is not an enum write-path: `status` is `online`/`offline`, stamped by register/claim/heartbeat and aged to offline by the lease sweep when `lastSeenAt` is older than **3× the lease**.

## One active job per file

A **partial UNIQUE index** enforces the invariant at the database level:

```sql
CREATE UNIQUE INDEX jobs_media_file_active_unique
  ON jobs (media_file_id)
  WHERE status IN ('queued', 'running') AND media_file_id IS NOT NULL;
```

`media_file_id` is backfilled from the payload, so bulk enqueue and manual enqueue can never double-queue a file — a lost insert race maps to **409 CONFLICT**. The slot frees the moment a row leaves queued/running (cancel, fail, succeed).

## Indexes

| Index | On | Scope / purpose |
|-------|----|-----------------|
| `jobs_media_file_active_unique` | `media_file_id` | Partial: queued/running rows only — one active job per file |
| `jobs_transcode_claim_order` | `priority DESC, created_at, id` | Partial: queued transcode rows — the claim candidate page is `INDEXED BY` this |
| `jobs_status_finished_at` | `status, finished_at` | Stats and sweep lookups by time window |
| `media_files_library_id_rel_path_unique` | `library_id, rel_path` | One cache row per file |
| `workers_name_unique` | `name` | Registration upsert key |
| `api_keys_key_hash_unique` | `key_hash` | Key lookup by hash |

## Payload and result snapshots

`jobs.payload` is the enqueue-time **frozen transcode snapshot**: mediaFileId, the RAW estimate pair, targetCodec, hwPreference, VMAF fields, maxResolution, sourceContainer, and the ruleset-model knobs (crf/preset/thresholdPercent/verifyDecodeMode — optional; absent = legacy, consumer falls back to global settings). Claim and verification read it instead of live settings. `jobs.result` holds the throttled progress JSON (stage/percent) and, on success, the realized-savings payload (`realizedSavingsBytes`, `realizedSavingsPercent`, `originalSizeBytes`, `newSizeBytes`). Retry preserves the payload untouched.

## The permanent rejection marker

`media_files.transcode_rejected_at` is stamped **only** by the savings-threshold gate (gate 6): the encode proved the estimate unreachable, so auto-selection (bulk candidates, savings ranking) must skip the file forever. Properties:

- NULL = never rejected; a re-failure refreshes the timestamp.
- Deliberately **not part of the probe-cache fingerprint** — a rescan/re-probe keeps the marker.
- Cleared by a successful replace, or by assigning a **changed** ruleset (a new profile is a new chance). Retry never clears it; manual transcode stays allowed regardless.

## Settings storage

One row per snake_case key, JSON value, `updated_at` timestamp. Defaults seed on boot from `SETTING_DEFAULTS`; `GET /api/settings` parses the whole object through `SETTINGS_SCHEMA` (a stale row for a removed key is stripped, never breaks the read). `estimator_calibration` is machine-managed — absent from the update schema, so user PATCH attempts are silent no-ops. Internal one-shot markers (e.g. the estimator-backfill done flag) live in the same table, deliberately invisible to the API.

## Pragmas and migrations

`createDatabase` opens better-sqlite3 with **`journal_mode = WAL`** and **`foreign_keys = ON`**, creating parent directories as needed. `migrateDatabase` applies the generated Drizzle migrations (`packages/database/drizzle/`) — the server runs them **on every boot**, before the settings seed and the stale-job sweep, so a plain start is always schema-current. Migration 0009 carries the ruleset model: it drops the former library binding/scope path and binds each library's most-recently-updated whole-library rule as its `default_rule_id`.
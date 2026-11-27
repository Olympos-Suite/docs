---
title: "Database"
description: "Psyche's SQLite schema: the table inventory, XOR and cascade constraints, the service-connections registry, the -1 sentinel, and boot migrations."
section: "Developer Guide"
order: 50
---

Psyche uses **SQLite permanently** (better-sqlite3 + Drizzle ORM) — PostgreSQL is rejected by design, not deferred. The whole state lives in one file, `<configDir>/psyche.sqlite` (default `/config/psyche.sqlite`), the only volume that needs backing up. SQLite is accessed **only through Drizzle**, and only repositories touch it.

## Table inventory

| Table | Key columns | Purpose |
|-------|-------------|---------|
| `settings` | `key` (PK), `value` (JSON) | Key-value config; Zod-validated, camelCase↔snake_case mapping. |
| `users` | `username` (unique), `passwordHash` (bcrypt), `role` | Single-admin auth. |
| `api_keys` | `keyHash` (unique, SHA-256), `keyPrefix`, `revokedAt` | Programmatic keys; plaintext shown once. |
| `sessions` | `id` (PK), `data` (JSON), `expiresAt` | SQLite-backed session store. |
| `series` | `tmdbId` (unique), `title`, `originalTitle`, `status`, `anime` | TMDB-anchored series. |
| `series_localizations` | `seriesId` + `language` (unique pair), `title`, `overview` | Per-language text for ordered fallback. |
| `seasons` | `seriesId`, `seasonNumber` (unique per series), `tmdbSeasonId` | Seasons. |
| `episodes` | `seasonId`, `episodeNumber` (unique per season), `absoluteNumber` (nullable) | Episodes; both numbering schemes. |
| `movies` | `tmdbId` (unique), `title`, `releaseDate`, `runtime` | TMDB-anchored movies (one row per movie). |
| `movie_localizations` | `movieId` + `language` (unique pair) | Per-language movie text. |
| `people` | `tmdbId` (unique), `name`, `knownForDepartment` | Browsable persons — not subscribable. |
| `metadata_cache` | `key` (PK), `payload` (JSON), `expiresAt` | Rate-limit-aware TMDB browse cache. |
| `quality_profiles` | `name` (unique), `isDefault`, `preferences` (JSON array) | Ordered preference lists. |
| `subscriptions` | `seriesId` / `movieId` (XOR), `qualityProfileId`, `monitored`, `grabPolicyOverride` | One subscription per entity. |
| `release_requests` | `subscriptionId`, `requestType`, `seasonNumber`, `episodeNumber`, `status`, `reason` | Wanted work; dedup UNIQUE with sentinel. |
| `download_queue` | `infoHash` (unique), `status`, `scoreTotal`, `qualityTag`, `grabbedAt`, `retryCount`, `nextRetryAt` | Grab lifecycle; score verbatim from grab. |
| `blacklist` | `infoHash` (unique, uppercase 40-hex), `reason` | Permanent hash bans. |
| `episode_files` | `episodeId`, `file_path` (unique, absolute), `qualityTag` | One linked file per episode file. |
| `movie_files` | `movieId`, `file_path` (unique, absolute), `qualityTag` | One linked file per movie file. |
| `service_connections` | `name` (unique), `type`, `provider`, `priority`, `config` (JSON) | Unified external-service registry. |
| `job_logs` | `jobType`, `status`, `startedAt`, `itemsProcessed`, `result` (JSON) | Persisted run history. |
| `app_logs` | `time`, `level`, `component`, `message`, `data` | Redacted pino events. |

## Relationships and constraints

The schema's integrity rules are the domain model:

- **Subscriptions XOR** — CHECK `subscriptions_exactly_one_target`: exactly one of `seriesId`/`movieId` is non-null. Both are additionally UNIQUE, so each entity has at most one subscription.
- **Quality profile FK** — `subscriptions.qualityProfileId` is `ON DELETE SET NULL`: deleting a profile (default included) nulls referencing subscriptions and the quality gate re-blocks them with an explicit reason.
- **Cascades down the work chain** — deleting a subscription cascades its `release_requests` and `download_queue` rows; deleting a series cascades seasons → episodes → `episode_files`; movies cascade `movie_files`. Localizations cascade with their parent.
- **Client deletion preserves history** — `download_queue.downloadClientId` → `service_connections` is `SET NULL`; queue rows survive connection removal.
- **File paths are unique** — `episode_files.file_path` / `movie_files.file_path` are absolute and UNIQUE: one on-disk file links exactly once.
- **infoHash uniqueness** — `download_queue.infoHash` is UNIQUE; NULLs (non-torrent rows) coexist freely with non-NULL rows because SQLite treats NULLs as distinct. Blacklisted hashes never re-enter, which keeps the constraint safe long-term.

Library entities and files are the durable side: no cascade ever deletes media files, and machinery-history pruning (the cleanup job) never touches entities, files, or requests.

### Queue row anatomy

`download_queue` is the widest table — its columns group into four concerns:

| Concern | Columns |
|---------|---------|
| Identity & linkage | `title`, `indexerName`, `infoHash` (unique), `magnetUrl`, `downloadUrl`, `sizeBytes`, `releaseRequestId` (null = manual grab), `subscriptionId` (display grouping), `downloadClientId` (SET NULL), `clientTorrentHash` |
| Score-once provenance | `qualityTag` (parsed at grab), `scoreTotal` (verbatim, never recomputed) |
| Lifecycle | `status` (enum), `progress` (0..1), `downloadedBytes`, `errorMessage`, `grabbedAt`, `completedAt`, `statusChangedAt` |
| Retry machinery | `retryCount`, `nextRetryAt` — backoff and the grace window anchor on `grabbedAt`, never the release publish time |

`job_logs` rows carry `status` ∈ `running` / `completed` / `completed_with_errors` / `failed`, item counts (`itemsProcessed`/`itemsTotal`), a `result` JSON summary, and `errorMessage`. The weekly cleanup prunes rows older than `files.jobLogsRetentionDays`; terminal queue rows settled more than 7 days are pruned alongside them.

## The service_connections registry

One table holds **every** external service (Eros-parity): `type` ∈ `metadata_provider` / `indexer` / `torrent_client`, `provider` within the kind's allowlist, url/credentials, `isActive`, `priority` (lower = first), and a JSON `config` bag. Fan-out and dispatch iterate by type + priority in a single pass.

- `metadata_provider`: at most one row (`tmdb`) — the single metadata source.
- Sensitive columns (`apiKey`, `username`, `password`) are stored **raw at rest**; masking to `********` is an API-layer concern, never a storage one.
- `lastTestedAt` / `lastStatus` record stored-connection probe results.

> [!NOTE]
> Migrations 0007/0008 moved the TMDB key out of the `settings` store (dropping the legacy `tmdb.api_key` row), removed the legacy `indexers` table, and retargeted `download_queue.download_client_id` to `service_connections`. Older spec text placing the key in settings is superseded by this layout.

## The sentinel

`release_requests` dedups on UNIQUE `(subscription_id, request_type, season_number, episode_number)`. Movie requests have no season/episode; season packs have no episode. Plain nullable columns would let duplicates through — **SQLite treats NULLs as distinct in unique indexes** — so "not applicable" components use the sentinel **`-1`** (`NOT NULL DEFAULT -1`). Real season/episode numbers are always ≥ 0, so `-1` can never collide. API DTOs stay nullable; the server maps `-1 ↔ null` at the boundary. (A COALESCE expression index was rejected: drizzle-kit misquotes sql-chunk index expressions.)

The same NULL-uniqueness property is used deliberately elsewhere: hash-less queue rows coexist under the UNIQUE `infoHash`.

## Pragmas and migrations

`createDatabase` (the only place a connection is opened) applies on **every** connection:

```sql
PRAGMA journal_mode = WAL;
PRAGMA foreign_keys = ON;
```

WAL lets the scheduled jobs and HTTP handlers read while a write is in flight; foreign keys make the cascades above real. Drizzle migrations ship in `packages/database/drizzle` and **apply automatically on every boot** before anything else resolves — upgrades are a plain restart, and the backup job's online snapshots stay consistent under WAL.

Backups are better-sqlite3 online `backup()` snapshots into `/config/backups` (weekly job, newest 7 kept); restore replaces the live DB and schedules a process restart. See [Configuration](./configuration#volumes) for the mount layout.
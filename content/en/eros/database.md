---
title: "Database"
description: "Eros's SQLite schema: the 23-table inventory, hash-evidence and pipeline tables, expression and pHash indexes, transactional migrations, seeds, and online backups."
section: "Developer Guide"
order: 50
---

Eros stores everything in one SQLite file, accessed through **Drizzle ORM + better-sqlite3**. The `createDatabase(dbPath)` factory in `@repo/database` is the only place a connection is opened: it creates the parent directory, applies `PRAGMA journal_mode = WAL` and `PRAGMA foreign_keys = ON`, and wraps the handle with `drizzle(sqlite, { schema })`. It returns `{ db, sqlite }` — the typed `DbType` every repository takes, plus the raw handle used by the migration runner, the logger transport, and backups. The default path is `/config/eros.db` (`DB_PATH` env override); repositories are the only Drizzle consumers (see [Invariants](./invariants) for the documented exceptions).

## Table inventory

23 tables in `packages/database/src/schema/`, grouped by purpose. Status vocabularies are `as const` objects, never TS enums; timestamps are unix seconds (`unixepoch()` defaults), booleans integer-mode, JSON payloads text-mode.

### Identity and auth

| Table | Purpose |
|-------|---------|
| `users` | Local accounts (single-admin app); `username` unique, bcryptjs `passwordHash`, `role` admin/user. |
| `api_keys` | Third-party REST keys; `keyHash` unique (SHA-256 hex, plaintext never stored), `keyPrefix` display-only, `isActive` soft revoke, `userId` FK cascade. |

There is **no `sessions` table** — it was dropped in migration `0016`; cookie sessions live in `@fastify/session`'s in-process MemoryStore.

### Catalog

| Table | Purpose |
|-------|---------|
| `performers` | Performer records; `slug` unique, aliases/images/tags JSON, `externalIds`, JAV backfill watermark. |
| `studios` | Studio records; `slug` unique, aliases/images JSON, logo/banner/website URLs, `externalIds`. |
| `scenes` | Central scene entity, **created at download start**; `slug` unique, `folderPath`/`nfoPath`, parsed `quality`/`source`, status discovered/enriched/unmapped/organized/deleted. |
| `scene_performers` | M:N scenes↔performers; both FKs cascade, unique pair. |
| `scene_studios` | M:N scenes↔studios; both FKs cascade, unique pair. |

### Scene evidence

| Table | Purpose |
|-------|---------|
| `scene_files` | Files on disk owned by a scene, with **our computed** `osHash`/`pHash`, duration, size-check watermark; 16 pHash block indexes. |
| `scene_external_hashes` | **Provider-reported** fingerprints (TPDB/StashDB) for sibling-record dedup; `submissions` evidence weight, `duration` gate; unique `(externalId, hash, hashType)`. MD5 is stored but never matched. |
| `jav_scene_codes` | JAV codes harvested per performer; status machine pending/searched/downloaded/failed/skipped with retry timestamps. |

### Torrent pipeline

| Table | Purpose |
|-------|---------|
| `torrent_groups` | Clustered indexer results; `bestTorrentHash`, `memberCount`, status incl. `accepted`/`exhausted`; soft scene/subscription links. |
| `torrent_group_members` | Individual hits per group with durable **trial state** (`attemptStatus` trying/failed/succeeded) for group-fallback retries; FK cascade. |
| `torrent_blacklist` | Hashes (and names) never to re-download; soft `subscriptionId`; normalized-name expression index. |
| `download_queue` | Active downloads + seed lifecycle; `infoHash` **unique** (normalized lowercase), 8-state status, retries (max 3), `isMegapack`, `replacesSceneId` upgrade marker, six stall-tracking columns (plain epoch integers, migration `0033`). |

### Megapack

| Table | Purpose |
|-------|---------|
| `megapack_items` | Scenes extracted from a pack download; FKs cascade to queue row and scene. |
| `megapack_piece_mapping` | Per-file piece ranges for **mid-download** hash checks; unique `(downloadQueueId, fileIndex)`, CAS-claimable status, `sceneFileId`/`matchedSceneId` set-null FKs. |
| `megapack_history` | Durable record of every pack ever queued — survives queue cleanup so search never re-adds a pack; `subscriptionId` set-null (provenance only). |

### Config

| Table | Purpose |
|-------|---------|
| `settings` | Key/value config (45 seeded keys); `value` text (JSON for `paths`), `category`, `description`. |
| `service_connections` | External services (qBittorrent/Transmission, Prowlarr, TPDB, StashDB); provider/type/credentials are data, `priority` 1–99 lower wins, probe results. |
| `quality_profiles` | Ordered preference lists per user; `isDefault`, `preferences` JSON. |
| `subscriptions` | Automation bound to a performer **or** studio (never a scene); word filters, megapack/compilation toggles, exhaustion stamps; soft FK links. |

### Observability

| Table | Purpose |
|-------|---------|
| `app_logs` | Pino events via the SQLite transport; level/category/source/job-run columns; FTS5 search (below). |
| `job_logs` | One row per job run; status running/completed/completed_with_errors/failed, item counters, result JSON. |

## Relationships and constraints

- **Evidence cascades with its parent** — deleting a scene cascades `scene_performers`, `scene_studios`, `scene_files`, `scene_external_hashes`; group members cascade with their group; megapack items cascade with queue row and scene.
- **Deliberate soft links** — `subscriptions` → performer/studio/profile/path, `torrent_groups` → scene/subscription, and most `download_queue` links omit `references()` entirely: history survives entity deletion, and services enforce ownership instead of the schema.
- **Set-null survivors** — `megapack_piece_mapping.sceneFileId/matchedSceneId` and `megapack_history.subscriptionId` are `ON DELETE SET NULL`: packs and mappings outlive their references.
- **Uniqueness** — `download_queue.infoHash` (one active row per hash; restore drops stale rows to free it), catalog slugs, junction pairs, the external-hash triple, and the piece-mapping pair (backing `onConflictDoNothing` batch inserts).
- **Hash normalization** — queue/history writes lowercase infoHashes; lookups compare case-insensitively (migration `0029` lowercased legacy rows).

## Indexes

- **Expression indexes** must match repository query expressions character-for-character: `json_extract(external_ids, '$.tpdb')` on performers/studios/scenes (plus `'$.stashdb'` on scenes), and `lower(trim(torrent_name))` on `torrent_blacklist`.
- **pHash block indexes** (migration `0015`): a 64-bit pHash is 16 hex nibbles; 16 `substr(lower(hash), i, 1)` equality indexes on each of `scene_files` and `scene_external_hashes`. By the pigeonhole principle, any pair within Hamming distance ≤ 15 shares at least one nibble, so the OR-over-blocks candidate query is a guaranteed superset of true matches (configured threshold: 8); an in-memory Hamming filter removes false positives. The indexes are deliberately **non-partial** (SQLite disables the OR-optimization for partial indexes), and each expression is a single `sql.raw` chunk so drizzle-kit emits intact DDL.
- **FTS5 log search** — `app_logs_fts` (on `message`) plus insert/update/delete triggers exist **only in migration `0016`**, outside the Drizzle model. The logs repository searches through FTS5 with an automatic LIKE fallback.

## Migrations and seeds

`runMigrations(sqlite)` replays `packages/database/drizzle` on **every boot**, before seeds and before anything else resolves: it reads `meta/_journal.json`, records applied tags in `__drizzle_migrations`, and runs each migration's SQL **and** its journal insert in one better-sqlite3 transaction — a mid-migration failure leaves no half-applied schema and re-runs whole next boot. A journal entry whose `.sql` file is missing throws; nothing is silently skipped.

There are **35 migrations numbered 0000–0033** (two share the `0011` prefix: `add_app_logs` and `path_refactor`). Landmarks: `0015` pHash block indexes, `0016` drops `sessions` + adds FTS5 and JSON indexes, `0023` API keys, `0026` group fallback, `0028` quality upgrades, `0029` hash normalization + megapack history, `0033` stall detection. Never edit an applied migration — generate a new one with `pnpm db:generate` (drizzle-kit).

Seeds are idempotent: **45 default settings** insert only missing keys (additive settings migration), and **4 quality profiles** — 4K Ultra, **HD 1080p (default)**, SD Compact, Any Quality — insert only into an empty table, hard-coded to user 1.

## Backups and file locations

`BackupService` prefers better-sqlite3's **online `backup()` API** — a consistent snapshot of the live WAL database (a plain file copy can race a checkpoint and tear). Snapshots land in `/config/backups` (`BACKUP_DIR` override) as `eros-backup-<timestamp>.db`; the weekly backup job keeps the **7 newest**. Restore copies the snapshot to a temp file, atomically renames it over the live DB, unlinks the stale `-wal`/`-shm` sidecars, and schedules `process.exit(22)` ~1 s later so the container restart policy reloads the restored file.

> [!NOTE]
> `/config` is the state volume: database, `session.secret`, and backups. Older installations kept the database under `/data`; the compose file still mounts that directory for legacy migration, but new installs leave it empty and use `/config/eros.db`.

See [Configuration](./configuration) for the volume layout and [API reference](./api-reference) for the backup endpoints.
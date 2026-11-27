---
title: "Configuration"
description: "Psyche's DB-resident settings store: every setting group and default, the unified service-connections registry, and the bootstrap env/ports/volumes reference."
section: "User Guide"
order: 20
---

Unlike Zephyrus (one YAML file), Psyche has **no configuration file**. All app configuration lives in the SQLite `settings` key-value table, is Zod-validated against a definitions registry, and is edited in the **Settings UI** (or via `GET`/`PUT /api/settings`). Defaults are seeded on boot for absent keys; nothing needs to be pre-created.

- **Key mapping.** API keys are camelCase dotted paths (`matching.crossEncoderThreshold`); the DB stores snake_case per segment (`matching.cross_encoder_threshold`). The mapping is automatic in both directions.
- **Secrets.** Sensitive values are masked to `********` in every API response. Connection credentials live in [service connections](#service-connections), not in the settings store.
- **Validation.** `PUT /api/settings` validates each key against its definition; invalid values are rejected with a `VALIDATION_ERROR` envelope. Some writes have live side effects (log level, job schedules, storage paths).

The API surface is two routes:

```bash
# Read every defined setting (sensitive values arrive as "********")
curl -H "X-Api-Key: $KEY" http://localhost:9698/api/settings

# Update a subset — only the keys you send are touched
curl -X PUT -H "X-Api-Key: $KEY" -H "Content-Type: application/json" \
  -d '{"search.limit": 200, "torrents.stalledWindowMinutes": 45}' \
  http://localhost:9698/api/settings
```

Sending a masked value back keeps the stored secret; the UI uses the same convention.

## Settings groups

The Settings UI groups these keys into tabs (see [Web UI](./web-ui#settings)). Defaults below are the registry defaults seeded on boot.

### General

| Key | Default | Description |
|-----|---------|-------------|
| `ui.theme` | `dark` | Interface theme (`light` / `dark`). |
| `metadata.language` | `en` | Preferred metadata language for TMDB reads and cache keys (2–10 chars). |
| `metadata.language_fallback` | `['en']` | Ordered fallback languages, tried in order, then the original language. |

### Jobs

| Key | Default | Description |
|-----|---------|-------------|
| `jobs.schedules` | `{}` | Per-job cron overrides (job id → 5- or 6-field expression). Absent id uses the job default. |
| `jobs.disabled` | `[]` | Job ids that never fire on schedule; manual triggers still work. Essential jobs cannot be disabled. |

### Search

| Key | Default | Description |
|-----|---------|-------------|
| `search.limit` | `100` | Max releases per indexer search (0–500, step 10). |
| `search.delayMs` | `1000` | Delay between consecutive indexer searches (0–30000, step 500). |
| `search.timeoutMs` | `180000` | Per-indexer HTTP timeout (5 s–10 min). Prowlarr aggregates many trackers and can be slow. |
| `search.retries` | `3` | Retries after the first attempt for 429/5xx/network errors (0–10). |
| `search.retryBaseDelayMs` | `3000` | Base delay of the exponential retry backoff (0–60 s). |
| `search.subscriptionBudget` | `25` | Max subscription searches per automation cycle (0–500); 0 searches all. |
| `search.wantedMovieRetryDays` | `7` | Days before a wanted movie without a file is re-searched (1–365). |
| `search.indexerErrorThreshold` | `5` | Consecutive indexer failures before the indexer is muted (1–50). |
| `search.indexerErrorMuteHours` | `24` | Hours a muted indexer is skipped (1–720). |

### Matching

| Key | Default | Description |
|-----|---------|-------------|
| `matching.method` | `cross-encoder` | Title-similarity method: `text` (Jaccard) or `cross-encoder`. |
| `matching.textSimilarityThreshold` | `0.4` | Minimum Jaccard similarity (0.1–0.8, step 0.05). |
| `matching.crossEncoderThreshold` | `0.5` | Minimum cross-encoder similarity (0.2–0.9, step 0.05). |
| `matching.crossEncoderModel` | `Xenova/MiniLM-L6-v2` | Bundled model (`…L6-v2` / `…L12-v2`) or `custom`. |
| `matching.crossEncoderModelCustom` | `''` | Custom transformers.js model id; used only when the model is `custom`. |

### Downloads

| Key | Default | Description |
|-----|---------|-------------|
| `downloads.category` | `psyche` | qBittorrent category / Transmission label applied to grabs — the [Zephyrus group contract](./integration#the-zephyrus-contract). |
| `downloads.seedTimeHours` | `72` | Seeding limit applied on the client at grab time (0–8760 hours). |

### Torrents

| Key | Default | Description |
|-----|---------|-------------|
| `torrents.stalledWindowMinutes` | `30` | Minutes without progress before a download counts as stalled (1–1440). |
| `torrents.stalledMinMb` | `50` | Minimum size in MB for the stalled check (1–10000). |
| `torrents.stalledAutoRemove` | `false` | Auto-remove stalled downloads (with files) and blacklist them; otherwise flag only. |
| `torrents.sequentialDownload` | `false` | Request sequential download on grabs (capability-gated). |
| `torrents.firstLastPiecePriority` | `false` | Prioritize first/last pieces on grabs (capability-gated). |
| `torrents.qualityUpgradesEnabled` | `false` | Re-search and upgrade files when a better profile-matching release appears. |

### Files & storage

| Key | Default | Description |
|-----|---------|-------------|
| `library.seriesRoot` | `/media/tv` | TV library root (standard image mount). |
| `library.moviesRoot` | `/media/movies` | Movie library root (standard image mount). |
| `files.paths` | `[]` | Storage paths table (Eros paths model); seeded from the library roots on first boot. |
| `files.diskSelectionMode` | `auto` | Write-target selection: `auto` (free space) or `manual`. |
| `files.folderStructureTv` | `{seriesTitle}/Season {seasonNumber}/{seriesTitle} - S{seasonNumber}E{episodeNumber}` | TV organize template — see [File organization](./file-organization#folder-templates). |
| `files.folderStructureMovies` | `{movieTitle} ({year})/{movieTitle} ({year})` | Movie organize template. |
| `files.cacheArtworkLocally` | `true` | Keep fetched artwork cached on disk. |
| `files.jobLogsRetentionDays` | `30` | Days of job run history before the weekly cleanup prunes it (1–365). |
| `files.cleanupDays` | `14` | Days after completion before the retention sweep removes the torrent from the client (1–365). |

### Logging

| Key | Default | Description |
|-----|---------|-------------|
| `logging.level` | `info` | Minimum level persisted to the log store (`fatal`…`trace`, `silent` disables). Applied live, no restart. |
| `logging.retentionDays` | `7` | Days of application logs before the weekly cleanup prunes them (1–90). |

## Service connections

Every external service — the metadata provider, indexers, and torrent clients — is one row in the unified `service_connections` registry, managed under **Settings → Services** (`/api/service-connections`). There are no separate per-kind config stores.

| Type | Providers | Instances |
|------|-----------|-----------|
| `metadata_provider` | `tmdb` | At most **one** row (the single metadata source). |
| `indexer` | `prowlarr`, `torznab` | Many; all active rows fan out. |
| `torrent_client` | `qbittorrent`, `transmission` | Many; dispatch follows priority. |

- **Priority** (1–99): **lower number = higher precedence** — fan-out and dispatch iterate in ascending order.
- **Credentials** are stored raw at rest but always masked (`********`) in API responses; a PUT with an omitted or masked secret keeps the stored value.
- **Test probe** (`POST /api/service-connections/test`): probe a stored connection (`{id}`, result persisted to `lastTestedAt`/`lastStatus`) or an ad-hoc one (never persisted). A failed probe is a *result* (`ok: false` + message), not an error envelope.
- Deleting a client connection keeps queue history — the queue's client reference goes null.

> [!NOTE]
> The TMDB key used to live in the settings store (`tmdb.api_key`). It was moved into the `metadata_provider` service connection (Eros-parity migration); the legacy settings row was dropped. If you followed older instructions, add the key under Services instead.

## Environment variables

Bootstrap-only (ports and paths) — the full table is in [Installation](./installation#environment-variables). The essentials: `PSYCHE_CONFIG_DIR` (`/config`), `PSYCHE_DATA_DIR` (`/data`), `PSYCHE_DATABASE_PATH` (`<config>/psyche.sqlite`), `PORT` (`3001`), `HOST` (`0.0.0.0`), `SESSION_SECRET` (optional, ≥ 32 chars), `PUID`/`PGID` (`1000`), `TZ` (`UTC`).

## Ports

| Port | Where | Published? |
|------|-------|------------|
| `3000` | Web (Next.js) | Yes — host `9698:3000`. The only host-facing port. |
| `3001` | API (Fastify) | **No** — container-internal, reached through the web app's `/api` proxy. |

The proxy applies per-path timeouts: `/api/search` 240 s, `/api/library` 120 s, `/api/service-connections` 90 s, everything else 30 s. A proxy timeout surfaces as a `504` `REQUEST_ERROR` envelope; an unreachable API as `502`.

## Volumes

| Mount | Contents | Backup? |
|-------|----------|---------|
| `/config` | `psyche.sqlite`, session secret, `backups/` snapshots | **Yes — the only volume that needs backing up.** |
| `/data` | Artwork cache (`metadata/artwork`), cross-encoder model cache | No — regenerable. |
| `/media/tv` | TV library root | Your media backup strategy. |
| `/media/movies` | Movie library root | Your media backup strategy. |
| `/media/downloads` | Torrent client download directory | No — transient. |
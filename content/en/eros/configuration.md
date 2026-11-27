---
title: "Configuration"
description: "Eros's DB-resident settings store: every setting group and default, service connections, job schedules, disk monitoring, and backups."
section: "User Guide"
order: 20
---

Eros has **no configuration file**. All app configuration lives in the SQLite `settings` key-value table and is edited in the **Settings UI** (or via `GET`/`PUT /api/settings`). On every boot, 45 default settings are seeded idempotently — missing keys are added to existing databases, existing values are never overwritten — along with the four default [quality profiles](./quality-profiles) and the default download/storage paths.

- **Key mapping.** The API speaks camelCase (`crossEncoderThreshold`); the DB stores snake_case (`cross_encoder_threshold`). The controller maps both directions; unknown keys in a PUT are skipped with a warning.
- **Secrets.** Values whose keys contain `api_key`, `apikey`, `secret`, `password`, or `token` are masked in every API response; writing a masked value back keeps the stored secret.
- **Validation.** `ui_theme` accepts only `psyche`/`classic`; `disabled_jobs` must be a JSON array of job ids; boolean settings must be `'true'`/`'false'`. Invalid writes return a `VALIDATION_ERROR` envelope.
- **Live side effects.** Some writes apply immediately: log level, path directory creation, a full folder-correction sweep on `folder_structure` change, scheduler start/stop on `disabled_jobs` change, image-cache backfill/cleanup on `store_images_locally` flips, and a stall-tracking reset when the stall thresholds change.

```bash
# Read every setting (camelCase object; sensitive values masked)
curl -H "X-Api-Key: $KEY" http://localhost:9697/api/settings

# Update a subset — only the keys you send are touched
curl -X PUT -H "X-Api-Key: $KEY" -H "Content-Type: application/json" \
  -d '{"seedTimeHours": 48, "subscriptionSearchBudget": 10}' \
  http://localhost:9697/api/settings
```

> [!NOTE]
> Two kinds of defaults exist. Most keys are **seeded rows** (the values below). A few keys are never seeded and fall back to an inline code default when absent — those defaults are marked `*`. Deleting a seeded row restores its seeded value on the next boot; deleting a `*` row activates the code fallback.

## Search & grouping

Settings → Matching. Controls indexer fan-out, the subscription search budget, and how results are clustered into [torrent groups](./torrent-grouping).

| Key | Default | Description |
|-----|---------|-------------|
| `matching_method` | `cross-encoder` | Grouping method: `text`/`jaccard`, `cross-encoder`, or `llm` (LLM picks one torrent; grouping is skipped). |
| `torrent_group_min_members` | `2` | Minimum members for a group to become a scene (floor 2). LLM/JAV synthetic groups bypass it. |
| `prowlarr_search_limit` | `0` | Max results per indexer search; `0` = unlimited, positive values capped at 500 (code fallback 100 if the row is deleted). |
| `search_delay_ms` | `5000` | Delay between subscription/JAV searches. |
| `subscription_search_budget` | `5` | Subscriptions name-searched per scheduled run, bucketed rotation (never-searched first, then oldest-searched). `0` = unlimited; manual runs search all. |
| `jav_codes_per_run` | `30` | Global JAV code budget shared across all subscriptions per run. `0` = unlimited; applies to cron **and** manual runs. |
| `jav_retry_days` | `30` | Days before a searched/failed JAV code re-qualifies; manual runs bypass the window. |
| `indexer_error_threshold` | `3` | Consecutive indexer errors before muting (name + JAV searches). |
| `indexer_error_mute_hours` | `6` | Hours an error-muted indexer is skipped. |
| `jav_indexer_zero_threshold` | `10`* | Consecutive zero-result JAV queries before muting an indexer (JAV only; name-search zeros never mute). |
| `jav_indexer_mute_days` | `7`* | Days a zero-muted indexer is skipped for JAV queries. |
| `text_similarity_threshold` | `0.40` | Jaccard threshold in text mode. |
| `cross_encoder_threshold` | `0.80` | Cross-encoder grouping threshold (code fallback 0.50; relaxed ×0.85 when parsed dates agree). |
| `cross_encoder_model` | `Xenova/ms-marco-MiniLM-L-6-v2` | Local similarity model (cached under `/cross-encoder`). |
| `max_megapacks_per_run` | `3`* | Fresh megapack candidates added per subscription search run; `0` = unlimited, the rest defer to the next run. |
| `llm_provider` | `ollama` | LLM provider: `ollama`, `openai`, or `gemini` (used when `matching_method` is `llm`). |
| `llm_endpoint` | `''` | LLM API endpoint; code fallback `http://localhost:11434`. |
| `llm_local_model` | `llama3.2`* | Ollama model name. |
| `llm_api_key` | `''` | API key for OpenAI/Gemini (masked in responses). |

Per-indexer learning state (query counts, zero/error streaks, mutes) is persisted separately under the internal `indexer_stats` key — it is runtime state, not a user setting.

## Torrent management

Settings → Torrents. Grab labeling, the seed-retention clock, fallback retries, and stall measurement.

| Key | Default | Description |
|-----|---------|-------------|
| `torrent_category` | `eros`* | qBittorrent category applied to every grab — the [Zephyrus group contract](./integration). Subscription grabs also carry the tag `subscription:<id>`. |
| `seed_time_hours` | `72`* | Hours a completed torrent seeds before retention removes it from the client **keeping the files**. The only removal clock. |
| `group_fallback_enabled` | `true` | On repeated download failure, try the remaining members of the same torrent group. |
| `upgrade_scene_quality` | `false` | Replace an existing scene when a subscription search finds a higher-quality release allowed by the quality profile. |
| `stalled_window_minutes` | `30` | Minutes an actively-downloading torrent is measured before it can be judged stalled. |
| `stalled_min_mb` | `10` | Minimum MB that must download within the window, otherwise the torrent is stalled. |
| `stalled_auto_remove` | `false` | Automatically remove stalled torrents (with files) and blacklist them; otherwise flag only. |
| `missing_torrent_grace_hours` | `48`* | Grace window before a queue row whose torrent vanished from the client is cleaned up. |

> [!NOTE]
> Download-phase policy beyond stall measurement — speed schedules, auto-pause/resume, speed limits — was moved out of Eros to [Zephyrus](../zephyrus/). The legacy `speed_schedule*` and `torrent_auto_manage_*` keys are no longer read, and the seeded `auto_manage_torrents` row is inert. There are no speed-schedule settings in the UI.

## Files & disk

Settings → Files & storage. Organization template, the multi-path model, and retention.

| Key | Default | Description |
|-----|---------|-------------|
| `folder_structure` | `/{studio}/{title}` | Organize template. Tokens: `{studio}`, `{title}`, `{year}`, `{performer}`, `{quality}`, `{resolution}`, `{release-date}`; unknown values fall back to `unknown-studio`, `unknown-year`, etc. Changing it triggers a full folder-correction sweep. |
| `paths` | see below | JSON array of download/storage paths (the multi-path model). |
| `disk_selection_mode` | `auto` | Write-target selection: `auto` = most free space, `manual` = lowest `priority` number. |
| `warning_percent` | `15` | Global default free-space warning threshold. |
| `critical_percent` | `5` | Global default free-space critical threshold. |
| `cleanup_days` | `7` | Days completed/organized queue rows are kept before the weekly cleanup prunes them. |
| `job_logs_retention_days` | `30`* | Days of job run history before cleanup prunes it. |
| `store_images_locally` | off* | Cache performer/studio artwork under `DATA_DIR/images`. Enabling backfills in the background; disabling deletes the cache tree (scene-folder posters stay). |
| `extract_posters_enabled` | `true` | Auto-extract a poster frame from the video for scenes without provider artwork. |

The seeded `paths` value contains two entries: **Downloads** (`/downloads`, usage `download`) and **Media** (`/media`, usage `storage`), both active with `warningPercent: 15` / `criticalPercent: 5`. Each entry has `id`, `name`, `path`, `usage` (`download`/`storage`/`both`), `isActive`, optional `priority`, and per-path thresholds (`warningPercent` must be ≥ `criticalPercent`). Boot ensures at least one download and one storage path exist; saving paths creates the directories immediately. Subscriptions can pin a specific download path; otherwise the selection mode decides.

**Disk monitoring.** The `disk-monitor` job (every 30 min, `disk_monitor_cron`) checks free space per configured path against its thresholds — thresholds are **free-space percentages**, so warning fires at ≤ 15% free and critical at ≤ 5% free. Critical paths are surfaced in the job result and on the dashboard, which deep-links into Files settings.

## General & appearance

Settings → General.

| Key | Default | Description |
|-----|---------|-------------|
| `ui_theme` | `psyche` | Dark theme: `psyche` (default) or `classic`. Applied instantly in the UI and persisted. |
| `log_level` | `info` | Job log detail: `info` (summary) or `debug` (full detail). Applied live, no restart. |
| `log_retention_days` | `14` | Days of application logs before the weekly cleanup prunes them. |
| `hover_previews_enabled` | `true` | Jellyfin-style hover preview filmstrips on scene artwork. |
| `preview_frame_count` | `20` | Frames per preview strip, clamped to 4–40; raising it gradually re-extracts existing strips in the background. |
| `contribute_hashes` | `false` | Opt-in: submit the computed OSHASH back to StashDB after a successful match (pHash is never submitted). TPDB hash submission is not gated by this flag. |

## Jobs

Settings → Jobs. Eleven node-cron jobs; each schedule is editable in the UI (presets, validation, next-run preview) and persists to its `<job>_cron` key, restarting the live cron immediately.

| Job | Settings key | Default cron |
|-----|--------------|--------------|
| subscription-search | `subscription_search_cron` | `0 0 * * *` (daily 00:00) |
| torrent-progress-sync | `torrent_progress_sync_cron` | `*/2 * * * *` |
| download-completion | `download_completion_cron` | `*/5 * * * *` |
| torrent-retention | `torrent_retention_cron` | `*/15 * * * *`* |
| early-dedup | `early_dedup_cron` | `*/30 * * * *` |
| torrent-health | `torrent_health_cron` | `*/30 * * * *` (group-fallback sweep only) |
| disk-monitor | `disk_monitor_cron` | `*/30 * * * *` |
| metadata-refresh | `metadata_refresh_cron` | `0 3 * * *` (daily 03:00) |
| file-sync | `file_sync_cron` | `0 */2 * * *` |
| cleanup | `cleanup_cron` | `0 0 * * 0` (Sun 00:00) |
| backup | `backup_cron` | `0 3 * * 0` (Sun 03:00) |

`disabled_jobs` (default `[]`) is a JSON array of job ids whose schedules are stopped. The four **essential** pipeline jobs — `torrent-progress-sync`, `download-completion`, `early-dedup`, `torrent-retention` — can never be disabled; the other seven can. Manual "Run now" triggers work regardless.

## Service connections

Every external service is one row in the `service_connections` registry, managed under **Settings → Services** (`/api/service-connections`). Presets pre-fill the form:

| Type | Providers | Default URL preset |
|------|-----------|--------------------|
| `torrent_client` | `qbittorrent`, `transmission` | `http://localhost:8080` / `http://localhost:9091/transmission/rpc` |
| `indexer` | `prowlarr`, `jackett`, `torznab`, `newznab` | `http://localhost:9696` / Jackett aggregated Torznab endpoint (`:9117`) / `http://localhost:9118/torznab/api` / `http://localhost:8090/api` |
| `metadata_provider` | `tpdb`, `stashdb` | `https://api.theporndb.net` / `https://stashdb.org` |

Rules per type:

- **Torrent client** — only **one** connection can be active; activating one deactivates the others. No priority column.
- **Indexer** — all active connections are queried in parallel on every search; results merge with infohash dedup (highest seeder kept). Jackett, Torznab, and Newznab all speak the Torznab protocol. The lowest-priority-number adapter serves GUID proxy downloads.
- **Metadata provider** — all active providers participate in enrichment; the lowest priority number is the *primary* used for performer-detail lookups. Priority is editable here only.

Credentials are masked in API responses. The test probe (`POST /api/service-connections/test` with `{id}`) runs the adapter's health check, returns `{success, message, responseTimeMs}`, and persists `lastTestedAt`/`lastStatus` (`ok`/`error`). In the compose network use `http://qbittorrent:8180` and `http://prowlarr:9696` — the build args pre-fill these.

## Backups

Settings → Backups. The `backup` job creates an online SQLite snapshot (consistent WAL-included copy via better-sqlite3's backup API) into `/config/backups` (`BACKUP_DIR`) every Sunday at 03:00 and keeps the **latest 7**. The UI lists backups with create-on-demand, download, delete, and a typed-name-confirm restore. Restoring replaces the live database file and schedules a delayed process exit so the container restart policy reloads it — under Docker this is automatic; bare-metal runs must be restarted manually.

## Bootstrap environment

Ports, paths, and the session secret are the only env-based configuration — see the full table in [Installation](./installation). The essentials: `DB_PATH` (`/config/eros.db`), `PORT` (`3001`), `DATA_DIR` (database directory), `BACKUP_DIR` (`/config/backups`), `SESSION_SECRET` (optional, ≥ 32 chars), `PUID`/`PGID` (`1000`).
---
title: "Troubleshooting"
description: "Degraded modes, the setup and auth gates, in-memory sessions, unmapped scenes, indexer mutes, stalled downloads, disk-full behavior, logs, backups, and known limits."
section: "User Guide"
order: 130
---

Eros fails soft where it can: missing services degrade individual features, enrichment and organization errors are non-fatal per scene, and one bad job never blocks the others. First stops for any issue are the **Jobs** and **Logs** tabs in Settings, and the health endpoint:

```bash
curl http://localhost:9697/api/health
```

## Degraded modes

| Missing piece | Symptom | Fix |
|---------------|---------|-----|
| No torrent client | Grabs fail; nothing downloads. | Add and test a client connection in [Settings → Services](./integration). |
| Client unreachable | Progress sync logs per-row failures; queue state goes stale. Rows past `missing_torrent_grace_hours` (default 48) without a client torrent are cleaned up. | Check URL/credentials from Eros's host/container; use the connection test. |
| No indexers | Searches return empty results with zero upstream calls. | Add at least one indexer (Prowlarr, Jackett, Torznab). |
| All indexers muted | Name searches return empty; logs show muted indexers skipped. | Fix the upstream, wait out the mute, or test the connection — a success clears it. |
| No metadata providers | Hash queries find nothing; completed scenes end up `unmapped`. | Add TPDB and/or StashDB credentials. |
| No file on disk yet | Scene stays `discovered`; enrichment waits. | Normal while downloading — the completion job retries. |

## First run and auth

- **`503 SETUP_REQUIRED`** on every API call means no admin user exists yet. Open the web UI and complete the first-run setup wizard. The setup routes, `/api/health`, and `/api/docs` stay reachable before setup.
- **`401 UNAUTHORIZED`** means neither a valid session nor a valid API key was presented; the UI bounces to `/login`. An invalid or revoked API key returns 401 with "Invalid or revoked API key" — key auth is stateless and creates no session.
- **`403 CSRF_CHECK_FAILED`** on a write request means the browser `Origin` is not allowed. Set `CORS_ORIGINS` explicitly if you front Eros with a custom domain; private/local origins are allowed by default.
- **`429 RATE_LIMITED`** — the global limit is 1000 requests/minute, keyed per IP (per key for API-key callers).

## Sessions and /config

Eros registers `@fastify/session` **without a persistent store** — session data lives in process memory (the default MemoryStore). **Every restart logs all users out.** This is Eros's actual behavior, not a misconfiguration; log back in after a restart.

The session *secret* does persist, keeping cookie signing stable:

1. `SESSION_SECRET` env, when set, always wins — and must be **≥32 characters** (a set-but-short value is warned about and ignored).
2. Otherwise the secret lives at `/config/session.secret` (generated once, mode `0600`).
3. If `/config` is **unwritable**, Eros falls back to an ephemeral secret and logs a loud warning.

`/config` holds the entire state — SQLite database, settings, session secret, backups. If it is unwritable, fix the mount ownership to match `PUID`/`PGID` (see [Installation](./installation)). Cookies are httpOnly, SameSite=Lax, 24-hour rolling, `secure: auto` (HTTPS-only when actually detected, so HTTP behind a TLS-terminating proxy works).

## Unmapped scenes and enrichment retries

`unmapped` means enrichment ran and found **no hash evidence** — it is not an error state. Check, in order:

- **Provider outage vs no-match**: provider errors leave the status untouched and arm an exponential backoff (5 min × 2^n, capped at 24 h). A scene stuck at `discovered` with provider errors in the log is waiting out an outage, not unmapped.
- **Evidence gates**: a candidate needs the file's OSHash in the record's hash list, the submission floor (OSHash ≥1, pHash ≥2), and duration agreement within ±60 s. Single-submission pHashes and duration mismatches are rejected by design.
- **Retry paths**: the nightly `metadata-refresh` job re-attempts up to 50 scenes — `discovered`/`unmapped` first, plus `enriched` ones missing a cover or tags (community hashes may have arrived since); **Re-verify Metadata** on the scene forces a fresh attempt, bypassing the backoff. See [Metadata enrichment](./metadata-enrichment).

## Stalled downloads

A torrent is stalled when fewer than `stalled_min_mb` MB (default 10) download within `stalled_window_minutes` (default 30) while actively downloading. Paused/queued/checking/seeding states suspend the window. The stalled list is exposed at `GET /api/downloads/stalled` and in the downloads views.

- With `stalled_auto_remove` off (default), removal is manual. Removal deletes the torrent **with files**, blacklists the hash (`stalled_removed`), and deletes the queue row — **the scene is kept** so another release can retry it.
- Failed downloads additionally get second chances through their torrent group's sibling releases (`group_fallback_enabled`, default on, driven by the `torrent-health` job).
- Speed limits and scheduled pause/resume are not Eros features — they belong to [Zephyrus](../zephyrus/).

## Disk space

Thresholds are **free-space percentages**: warning at ≤15% free, critical at ≤5% (per-path overridable). The `disk-monitor` job checks every 30 minutes.

- Paths below critical are treated as unhealthy and skipped by path selection; if none are healthy, Eros degrades to the most-available path with a warning instead of failing.
- Cross-device placement copies require the file size plus 1% headroom on the target; same-device moves are renames and need no free space.
- The weekly cleanup sweeps orphaned download leftovers only when the client confirms they are orphaned — an unreachable client skips the sweep entirely. See [Deletion semantics](./deletion-semantics).

## Jobs

- **Overlap skip**: a cron tick (or manual Run now) silently skips when the same job is already running — a "missed" run is usually a long previous run, not a fault.
- **Essential jobs** — `torrent-progress-sync`, `download-completion`, `early-dedup`, `torrent-retention` — cannot be stopped or disabled. The other seven can be, via the Jobs tab (`disabled_jobs` setting).
- **Crash recovery**: job runs left `running` by a crash are finalized as `failed` at boot. Schedules re-resolve from settings on every boot; an empty/invalid cron expression leaves that job idle with a warning.
- **Schedule edits apply live** — no restart needed. Manual runs bypass the subscription search budget and JAV retry windows.
- When automation "isn't doing anything", read the last run: `completed` with 0 items usually means nothing was eligible; `completed_with_errors` carries per-step counts in the result JSON; per-scene failures are isolated by design.

## Logging

Pino logs go to the console (pretty in dev, JSON in production) and to the SQLite `app_logs` table behind **Settings → Logs**.

- **Search is FTS5-backed** (input treated as a quoted prefix phrase, metacharacters inert) with automatic LIKE fallback; filter by level, category, source, job type/run, and date range.
- **Sensitive values stay out**: indexer adapter logs redact `apikey` query parameters, and the settings API masks key/secret/password/token values.
- **Retention**: the weekly cleanup prunes app logs older than `log_retention_days` (default 14) and job history older than `job_logs_retention_days` (default 30).
- Job runs have their own history (`job_logs`) with progress counters, statuses, and result JSON — the Jobs tab shows them per job.

## Backups and restore

The weekly `backup` job (Sunday 03:00, `backup_cron`) copies the SQLite database to `/config/backups`, keeping the 7 newest. The Backups tab can create, download, and delete snapshots on demand.

> [!CAUTION]
> Restoring a backup **replaces the database file** and exits the process (code 22) so the container restart policy brings it back on the restored file. Everything recorded since the snapshot — scenes, subscriptions, queue state, settings — is lost. Restore only when the current state is genuinely worse than the snapshot.

Because `/config` holds the entire state, an offline copy of that one volume is a complete backup strategy.

## Known limits

| Limit | Detail |
|-------|--------|
| Performer links accumulate | Enrichment **adds** provider performers alongside the subscription's performer; it never replaces them. |
| Manual downloads have no subscription | Discovery queue rows carry only a scene link — they appear in scene views, not subscription download stats. |
| `file-sync` can hard-delete | A scene whose folder vanished and which has no performer/studio links is permanently deleted (mount-guarded: never on an unmounted/unreachable root). The [library scan](./metadata-enrichment) can re-import the files if they reappear. |
| First retention run is a burst | Accumulated old completed rows are swept in one pass after a deploy — files are kept. |
| Transmission has no piece map | Megapack per-file early dedup no-ops on Transmission; use qBittorrent for packs. |
---
title: "Troubleshooting"
description: "Degraded modes, boot recovery, session persistence, redacted logging, and fixes for the failures operators actually hit."
section: "User Guide"
order: 110
---

Psyche fails soft where it can and loud where it must: missing services degrade individual features instead of crashing, while wiring failures stop the boot. First stops for any issue are the **Jobs** and **Logs** tabs in Settings, and the health endpoint:

```bash
curl http://localhost:9698/api/health
```

## Degraded modes

| Missing piece | Symptom | Fix |
|---------------|---------|-----|
| **No TMDB key** | Discovery/search/detail routes fail with `REQUEST_ERROR`: no TMDB API key configured. Cached pages may still render. | Add the `metadata_provider` connection in [Settings → Services](./configuration#service-connections). |
| **No indexers** | Release searches return empty results with zero upstream calls; wanted rows accumulate. | Add at least one `indexer` connection (Prowlarr or Torznab). |
| **All indexers muted** | Searches return empty; logs show `skipping muted indexer`. | An indexer hit `search.indexerErrorThreshold` consecutive failures. Fix the upstream, wait out `search.indexerErrorMuteHours`, or test the connection — a success clears the mute. |
| **No torrent client** | Grab attempts fail with `REQUEST_ERROR`: no active download client configured. | Add a `torrent_client` connection and test it. |
| **Client unreachable** | Queue polls log per-row failures; progress stops updating. Rows are isolated — one bad client never fails the sweep. | Check the client URL/credentials from Psyche's host/container; use the Services test probe. |

## Boot and recovery

- **Boot smoke-check.** At startup the DI container resolves **every** registration. Any wiring failure throws and the app does not start — failures surface at boot, not on first request. If the container exits immediately, read the fatal log line naming the registration.
- **Migrations** apply automatically on every boot before anything else; a plain restart is always safe.
- **Stale running jobs.** If the process crashed mid-run, `job_logs` rows left in `running` are finalized as `failed` at boot. Run history is never cleared by a restart; re-trigger the job manually if needed.
- **Essential jobs** (queue-poller, library-organizer, download-retention) cannot be stopped or disabled — attempts return `409 CONFLICT`. If downloads seem stuck, check their last runs in the Jobs tab rather than trying to restart them.
- **Supervisor.** The container runs web + API together; if either process dies the container exits and `restart: unless-stopped` brings it back. A restart loop usually means the API is failing boot — check `docker logs psyche`.

## Sessions

Sessions are SQLite-backed with a 24-hour cookie (`psyche.session`, httpOnly, SameSite=Lax). **Restarts never log users out** — that is a core invariant. If you are logged out after every restart, the session secret is not persisting:

1. `SESSION_SECRET` env, when set, always wins — and must be **≥ 32 characters** (set-but-short refuses to boot).
2. Otherwise the secret lives at `/config/session.secret` (generated once, mode `0600`).
3. If `/config` is **unwritable**, Psyche uses an ephemeral secret and logs a loud warning: `CONFIG DIR UNWRITABLE — using an EPHEMERAL session secret; every restart will log all users out`. Fix the mount ownership (match `PUID`/`PGID`) — see [Installation](./installation#first-run).

A `401` on any API call bounces the UI to `/login`; `SETUP_REQUIRED` (no admin exists yet) routes to `/setup`.

## Logging

Psyche uses Pino with two outputs: console (pretty in dev, structured JSON in production) and the persisted `app_logs` table behind **Settings → Logs**.

- **Secrets never land in logs.** Redaction runs before the sink (authorization, API-key, and cookie headers censored to `[redacted]`), plus a binding-level scrub. Connection-error messages strip credential-ish parameters and URLs and are capped at 300 characters.
- **Level is live.** `logging.level` (default `info`) applies without a restart; `silent` disables persistence entirely. Raise it to `debug`/`trace` while diagnosing, then lower it again.
- **Retention.** The weekly cleanup job prunes `app_logs` older than `logging.retentionDays` (default 7). The Logs tab can also clear the store on demand (`DELETE /api/logs`).
- **No request spam.** Per-request info logging is disabled by design; failures (5xx) are logged through the error handler and persist.

Job runs have their own history (`job_logs`, per-job viewer in the Jobs tab, default 20 rows capped at 100) with statuses `running`, `completed`, `completed_with_errors`, `failed`, item counts, and a result JSON.

### Reading job runs

When automation "isn't doing anything", read the last run before guessing:

- `completed` with `itemsProcessed: 0` usually means **nothing was eligible** — no wanted requests, no organizable rows, no due retries. That is correct behavior, not a fault.
- `completed_with_errors` means the sweep finished but individual rows failed; the `result` JSON carries per-row counts (e.g. the poller's `polled`/`completed`/`pausedForError`/`blacklisted`, the organizer's `organized`/`skipped`/`failed`).
- `failed` carries an `errorMessage`; a row left `running` after a crash is finalized as failed at the next boot.
- Per-row failures are isolated by design — one bad torrent or file never aborts a sweep. Check the queue row's `errorMessage` and the app logs for the specific reason.

### Backups and restore

The weekly backup job snapshots the database into `/config/backups` (newest 7 kept); the Backups tab can also create, download, and delete snapshots on demand.

> [!CAUTION]
> Restoring a backup **replaces the single SQLite file** and restarts the process, so everything recorded since the snapshot is lost — library additions, subscriptions, profile assignments, download state, and settings — and in-progress downloads cannot be recovered. Restore only when the current state is genuinely worse than the snapshot.

Because `/config` holds the entire state, an offline copy of that one volume is a complete backup strategy.

## Common problems

| Symptom | Cause and fix |
|---------|---------------|
| `409 CONFLICT` on subscribe | The title is already subscribed (one subscription per entity). Edit the existing subscription instead. |
| `409 CONFLICT` on grab | The infoHash is already in the queue or blacklisted. Pick a different release; remove the blacklist entry only if you truly want that hash back. |
| Wanted row shows a gate reason | The release matched no preference, or the subscription has no profile. Adjust the [quality profile](./quality-profiles#assigning-profiles) or assign one. |
| Download keeps failing, then blacklists | 3 failed attempts exhaust the retry budget (30 s → 60 s → 120 s backoff). The hash is banned permanently; recovery is the subscription search finding a different release. |
| Download flagged `stalled: …` | No progress for `torrents.stalledWindowMinutes`. Resume manually, or enable `stalledAutoRemove` to ban-and-replace automatically. See [Stalled downloads](./download-management#stalled-downloads). |
| `502` / `REQUEST_ERROR` from search or grab | Upstream indexer/client failure, timeout, or malformed response. Messages are sanitized; check the per-indexer results and the Services test probe. |
| `504` from the web UI | The web proxy's per-path timeout elapsed (search 240 s, library 120 s, default 30 s). Slow indexers raise `search.timeoutMs`; a hung API needs a restart. |
| Files not organizing | The organizer only links rows with complete request→subscription linkage. Check the queue row's error message and the library-organizer run history; zero-file rows retry next sweep. |
| Logged out after restart | Ephemeral session secret — see [Sessions](#sessions). |
| Search returns nothing for an anime title | Confirm the series carries the anime flag (Animation + Japanese origin) and the episode has an absolute number; both numbering schemes are queried in one pass. See [Release matching](./release-matching#anime-detection). |
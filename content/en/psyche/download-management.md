---
title: "Download Management"
description: "Torrent clients and their capabilities, the guarded download queue, stalled handling, retry backoff, the blacklist, and retention."
section: "User Guide"
order: 70
---

Psyche adds torrents **directly to your torrent client** and tracks each grab in its own download queue. There is no intermediate download service — [Zephyrus](./integration#the-zephyrus-contract) is an optional policy layer that adopts Psyche's torrents by group, never the other way around.

## Clients

qBittorrent and Transmission are supported behind one adapter contract. Clients are configured as [service connections](./configuration#service-connections) (`type: torrent_client`); multiple clients fan out by priority (lower number first).

| Capability | qBittorrent | Transmission |
|------------|-------------|--------------|
| Categories | yes — the `psyche` category | no — **labels** instead (since 4.0) |
| Tags | yes | no |
| Sequential download | yes | since 4.1 |
| First/last piece priority | yes | **no** |

Grab options are **capability-gated**: `torrents.sequentialDownload` and `torrents.firstLastPiecePriority` (both default `false`) are applied only when the client supports them; otherwise the grab degrades gracefully instead of failing. The group name comes from `downloads.category` (default `psyche`) — qBittorrent category or Transmission label alike.

The adapters also handle the client-specific plumbing: qBittorrent's session-cookie login (4.x `SID` vs 5.x `QBT_SID_<port>`, one re-login on 403), Transmission's session-id handshake, listing/pausing/resuming/removing torrents, listing files, moving data (`setTorrentLocation`), and renaming a single file inside a torrent while preserving seeding metadata.

## The download queue

Every grab creates a `download_queue` row carrying the release title, indexer, infoHash, size, and the **verbatim grab-time score and quality tag**. Status moves through a guarded state machine — the server rejects illegal transitions:

```text
queued → downloading → completed → organized   (terminal)
                    ↘ seeding ↗
failed / paused are recoverable side states
```

| From | Legal targets |
|------|---------------|
| `queued` | downloading, paused, failed |
| `downloading` | completed, paused, failed, seeding |
| `completed` | organized, seeding |
| `seeding` | organized, failed |
| `failed` | queued (retry), paused |
| `paused` | queued, downloading |
| `organized` | — (terminal) |

The **queue-poller** job (every 30 s, essential) mirrors client state into queue rows through this guard: progress, completion, client-reported errors, and pauses. The **Queue** page shows the same rows with pause/resume/retry/delete actions:

- **Pause/resume** also pause/resume the torrent on its client (best-effort).
- **Retry** is legal only from `failed`/`paused`; it bumps the retry counter and clears the backoff.
- **Delete** removes the queue row; removing the torrent from the client is best-effort and never blocks deletion.

A grab that never appears on the client within the **30-minute grace window** (measured from `grabbed_at`, not the release's publish time) is treated as a failed grab.

## Stalled downloads

The poller measures progress only while a torrent is actively downloading. Settings under **Settings → Torrents**:

| Setting | Default | Effect |
|---------|---------|--------|
| `torrents.stalledWindowMinutes` | 30 | Minutes without progress before a download counts as stalled. |
| `torrents.stalledMinMb` | 50 | Downloads smaller than this are exempt from the check. |
| `torrents.stalledAutoRemove` | false | What happens when a stall is detected. |

- **Flag only** (default): the row gets `stalled: <reason>` in its error message and stays in the queue; you can resume or delete it manually.
- **Auto-remove**: the torrent is removed from the client **with its files**, the infoHash is blacklisted, and the row fails finally. A later subscription search picks a different release.

Changing the window/size thresholds resets stall tracking — rows must re-qualify under the new rule, never inherit old flags.

## Failure handling and the blacklist

When the client reports an error (or the grace window expires), the poller **auto-pauses** the row and schedules a resume with exponential backoff measured from grab time:

| Attempt | Delay before resume |
|---------|---------------------|
| 1 | 30 s |
| 2 | 60 s |
| 3 | 120 s |
| … | doubling, capped at 1 h |

After **3 failed attempts** the failure becomes permanent: the infoHash is **blacklisted** (a permanent ban — it is never grabbed again) and the row fails finally with `all retries exhausted — release blacklisted`.

There is **no sibling-release fallback** inside the queue. Recovery is the subscription search re-searching the wanted request and finding a *different* release; the blacklisted hash cannot resurface. The blacklist is visible under **Settings → Blacklist** (`GET /api/blacklist`); removing an entry (`DELETE /api/blacklist/:id`) makes that hash grabbable again.

## Retention

Two mechanisms retire finished downloads:

- **At grab time**, `downloads.seedTimeHours` (default 72) is applied as the client's own seeding limit where supported.
- The **download-retention** job (hourly, essential) removes torrents from the client for `organized` rows whose completion is older than `files.cleanupDays` (default 14 days). **Files stay** — the library copy is the keeper (`deleteFiles: false`). Each removal is self-tracking, so a row is processed once.

## Storage paths

Where grabs land is resolved from the **Files & storage** settings: the `files.paths` table (each entry has a usage of `tv`, `movies`, or `downloads`, an active flag, and used-space warning/critical thresholds of 90%/95%) plus `files.diskSelectionMode`:

- `auto` — pick the active path with the most free space for the usage;
- `manual` — use the configured path directly.

If save-path selection fails, the grab falls back to the client's default download directory. The **disk-monitor** job (every 30 minutes) watches the library roots and config dir, flagging warning below 15% free and critical below 5% in its run result.
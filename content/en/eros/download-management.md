---
title: "Download Management"
description: "qBittorrent and Transmission behind one client contract, the download queue status machine, stall detection and auto-removal, retries, quality upgrades, and seed retention."
section: "User Guide"
order: 70
---

Eros adds torrents **directly to your torrent client** and tracks every grab in its own `download_queue` table — there is no intermediate download service. The **Downloads** page shows the live queue with progress, speeds, and ETA, and per-row pause/resume/retry/remove actions. Download-phase *policy* split: stall measurement and group-fallback retries live in Eros; speed limits and auto-pause/resume belong to [Zephyrus](./integration) and have no settings here.

## Clients and capabilities

qBittorrent and Transmission sit behind one client-agnostic `TorrentClient` contract. **Only one client can be active at a time** — activating one deactivates the other (there is no priority column for clients). Both adapters handle add/pause/resume/recheck/delete, file lists, data relocation (`setTorrentLocation`), and health checks; the difference is what they can *report and control*:

| Capability | qBittorrent | Transmission |
|------------|-------------|--------------|
| `category` | yes — the `eros` category on add | no — category/tags ignored on add |
| `sequential` | yes | no |
| `first-last-piece` | yes — enabled on subscription grabs | no — flag ignored |
| `piece-map` | yes — per-piece states and per-file piece ranges | **no** — piece queries return empty |

Transmission's empty capability set is deliberate honesty: its RPC exposes no per-piece state, so `getPieceStates` and the detailed file list return `[]` rather than approximations derived from byte offsets — wrong piece ranges would corrupt the early OSHASH. The practical consequence: **megapack per-file early dedup no-ops on Transmission** (packs still download and process at completion). File priorities map onto Transmission's model (`0` → unwanted, `1` → normal, `≥2` → high), and a duplicate add (`torrent-duplicate`) counts as success.

Every grab lands in a deterministic **per-hash staging folder** under the selected download path, under the `torrent_category` (default `eros`); subscription grabs additionally carry the tag `subscription:<id>` — the handle Zephyrus adopts them by.

## The queue status machine

Queue rows move through eight statuses:

```text
pending → queued → downloading → seeding → organized   (terminal)
                          ↘ paused ↗        ↗
                          ↘ failed      completed
```

| Status | Meaning |
|--------|---------|
| `pending` / `queued` | Accepted, waiting for the client to start. |
| `downloading` | Actively downloading (includes the client's `stalledDL`, metadata-fetch, forced, and checking states). |
| `paused` | Paused in the client — manually or by the client itself. |
| `failed` | Client error, or retries exhausted. Recoverable via retry or [group fallback](./torrent-grouping). |
| `seeding` | Download finished, torrent still seeding in the client. |
| `completed` | Finished and no longer seeding (stopped/paused at 100%, or gone from the client after finishing). |
| `organized` | Torrent removed after the seed window, files kept and organized. Terminal. |

The **torrent-progress-sync** job (every 2 minutes, essential) mirrors client state into the rows: progress/speed/ETA, and the state mapping above. `completedAt` is stamped on the **first** transition into `seeding`/`completed` and never reset — pause/resume and recheck cycles must not restart the seed-cleanup clock. Finished rows never regress to downloading when the client re-checks them after a restart. Only the **torrent-retention** job writes `organized` (plus one heal path, below).

Two edge cases the sync handles:

- **Torrent gone from the client** — a finished row (`completedAt` set) becomes `completed`; a row that never finished is deleted once older than `missing_torrent_grace_hours` (default **48**), together with any orphan shell scene. Inside the grace window the row is left alone (the add may still be surfacing).
- **`missingFiles`** — if the linked scene is already finalized (organized into the library), the torrent is removed *keeping files* and the row marked `organized`; otherwise a recheck is triggered and the torrent stays. Client torrents in the `eros` category with no queue row are **reported only** — never touched.

## Stalled downloads

Stall detection is in-house, running in the progress-sync job right after the state mirror. One rule with two knobs (**Settings → Torrents**):

| Setting | Default | Effect |
|---------|---------|--------|
| `stalled_window_minutes` | 30 | Measurement window while actively downloading. |
| `stalled_min_mb` | 10 | Minimum MB that must download within the window. |
| `stalled_auto_remove` | false | Automatically remove newly-stalled downloads. |

A torrent is stalled when **fewer than `stalled_min_mb` MB downloaded over the last `stalled_window_minutes` minutes** while active — covering both fully stuck and crawling torrents. Only active download states are measured; paused, queued, checking, and seeding torrents suspend the window and clear any stalled state. `stalledSince` is stamped at the start of the first tripping window and keeps growing while the row stays stalled; when the client reports no total size yet, a scaled progress-ratio fallback applies. Changing either threshold resets all stall tracking — rows must re-qualify under the new rule.

- **Flag only** (default): stalled rows surface in the stalled list (`GET /api/downloads/stalled`) with a human-readable reason; you remove them manually (`POST /api/downloads/stalled/remove`).
- **Auto-remove**: the torrent is deleted from the client **with its files**, the hash+name blacklisted (`stalled_removed`), and the queue row deleted. **The scene row is kept** — a later search can download the content again via a different torrent.

## Manual actions and retries

All queue actions — single-row and bulk — go through `POST /api/downloads/bulk` (`pause`, `resume`, `remove`, `remove_blacklist`, `retry`; up to 100 ids):

- **Pause/Resume** act on the client too. Manual resume is a user override: it resets the retry budget (`retryCount` back to 0).
- **Retry** re-adds the magnet; each row allows `maxRetries` **3** attempts. Past the budget the row fails finally with `Max retries exceeded`.
- **Remove** deletes the queue row and the client torrent (files kept by default); **Remove & Blacklist** additionally bans the hash and torrent name (`user_banned`) so neither resurfaces in searches. Blacklist entries are managed per entity (*Clear Blacklist* on the subscription card) or globally.

A `failed` row with a torrent group gets an automatic second chance through its sibling releases — the **torrent-health** job's [group fallback](./torrent-grouping) sweep (every 30 minutes, `group_fallback_enabled`). Fallback failures are group-scoped, not global blacklists.

## Quality-upgrade replacements

With `upgrade_scene_quality` on (default off), a subscription search that finds a strictly better release of already-owned content queues it as a **replacement**: the new queue row carries `replacesSceneId`. The **download-completion** job (every 5 minutes, essential) executes the swap only once the new scene is finalized (enriched with a folder) — the replaced scene is then deleted with its files and the marker cleared. Until then both coexist; an in-flight download is never replaced. The ranking rules live in [Quality profiles](./quality-profiles).

## Seed retention

Finished torrents seed for `seed_time_hours` (default **72**), then the **torrent-retention** job (every 15 minutes, essential) removes them from the client **keeping the files** (`deleteTorrent(hash, false)`) and marks the row `organized`. Eligible: `completed`/`seeding` rows past the cutoff, plus paused-at-100% rows. The same job then runs the folder-correction, placement, and finalization sweeps that turn staging folders into the library template — see [File organization](./file-organization).

> [!NOTE]
> The first retention run after a deploy sweeps any backlog of old finished rows in one pass — a batch of torrent removals is expected. Files are always preserved.

The four pipeline jobs (progress-sync, download-completion, early-dedup, retention) are **essential**: their schedules always run and cannot be disabled. All job schedules are editable under **Settings → Jobs** (`<job>_cron` keys).

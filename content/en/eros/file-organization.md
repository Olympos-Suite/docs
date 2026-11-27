---
title: "File Organization"
description: "How downloads become library files: folder templates, seed retention, the post-enrichment folder sweeps, NFO and poster sidecars, and multi-path disk selection."
section: "User Guide"
order: 90
---

Eros organizes the library hands-off: download → enrich → seed for a configurable window → remove the torrent **keeping the files** → correct folders to the template. The `folder_structure` template is expanded at **enrichment time** (when the studio/title are finally known); the file organizer is a pure consumer of the resulting `scene.folderPath` and never re-identifies anything. Every sweep below is rename/move-only — organizing never deletes media.

## Folder templates

The `folder_structure` setting (default `/{studio}/{title}`) defines the layout under the library root. Available tokens:

| Token | Expands to | Missing-value fallback |
|-------|-----------|------------------------|
| `{studio}` | First studio name, slugified | `unknown-studio` |
| `{title}` | Scene title, slugified | Scene slug |
| `{year}` | Release year (first 4 chars of the date) | `unknown-year` |
| `{performer}` | First performer name, slugified | Title slug |
| `{quality}` | Quality tag, slugified | `unknown-quality` |
| `{resolution}` | Normalized resolution (`2160p`/`4k`/`uhd` → `4k`, else `1080p`/`720p`/`480p`) | `unknown-resolution` |
| `{release-date}` | ISO `YYYY-MM-DD` release date | `unknown-date` |

Slugs are language-inclusive (diacritics stripped, non-Latin scripts romanized or deterministically hashed). The library root itself is the selected storage path plus the `storage_subfolder` subfolder (default `eros`, empty string opts out), so files land under `<storage-root>/eros/<studio>/<title>` and stay separate from sibling apps sharing the volume.

With the default template, an organized library looks like this:

```text
/media/eros/
  mr-lucky-life/
    busty-beach-vibes/
      movie.nfo
      folder.jpg
      busty-beach-vibes.mp4
  unknown-studio/
    some-unmatched-scene/
      some-unmatched-scene.mp4
```

Unmapped scenes organize under `unknown-studio` too; when a later retry finds hash evidence, the [folder-correction sweep](#the-final-folder-sweeps) moves them to the correct studio folder.

## When organization runs

| Trigger | Cadence | Work |
|---------|---------|------|
| `download-completion` job | Every 5 min | Processes completed megapacks, enriches, then moves completed single-file torrents into their scene folders **via the client** (`setTorrentLocation`) — seeding continues. |
| `torrent-retention` job | Every 15 min | Ends the seed window (below), then runs the three folder sweeps. |
| Template change | On save | Saving a new `folder_structure` triggers a full folder-correction sweep immediately. |

All cadences are overridable via the jobs' `<job>_cron` settings. Moves happen through the torrent client while the torrent is still present, so the client's persisted paths stay truthful and seeding is uninterrupted.

## Seed retention

`seed_time_hours` (default **72**) is the **only** clock deciding how long a finished torrent stays in the client — enrichment progress never defers removal, because hashes are computed from disk files, not from the client.

- Eligible rows: `completed`/`seeding` downloads whose completion is older than the window, plus paused-at-100% rows (their seed clock starts when first seen).
- Removal calls `deleteTorrent(hash, deleteFiles=false)` — the torrent leaves the client, **the files stay on disk**. A torrent already gone from the client is tolerated.
- The queue row is marked `organized`, the terminal state.

> [!NOTE]
> The first retention run after a deploy sweeps any accumulated backlog of old completed rows **in one pass** — a burst of torrent removals is expected. Files are preserved.

## The final folder sweeps

After each retention pass, three sweeps run in order:

1. **Folder correction** (`correctFolderStructures`) — scans enriched/organized scenes with a folder and compares against the template's expected form. Differences are fixed with `fs.rename`: the folder moves (e.g. `unknown-studio/…` → `mr-lucky-life/…` after enrichment), media files are renamed, the NFO is regenerated, and all stored paths are updated. The sweep is incremental (cursor + 1 h lookback); a template change forces a full pass. In `auto` disk mode a placed folder is **pinned to its volume** — free-space ranking never relocates an existing library between disks.
2. **Placement** (`placeSceneFilesIntoFolders`) — moves media still sitting in download staging into library folders. Same-device moves are renames (no free space needed); cross-device copies require the file size plus a 1% free-space headroom on the target. Scenes with any non-organized queue row (including megapack links) are skipped until fully finished.
3. **Finalization** (`finalizeSeededSceneFolders`) — once **all** of a scene's queue rows are `organized`, nested media is flattened and renamed to `<slug>.<ext>`, emptied subfolders are removed. It never overwrites an existing file and never touches files under a still-seeding torrent.

Errors are logged and skipped per scene; every sweep is idempotent.

## NFO and posters

Each scene folder gets Jellyfin-friendly sidecars:

- **`movie.nfo`** — Kodi/Jellyfin movie-format XML: title, plot, premiered date, studio, performers (with thumbs), unique provider IDs, and poster/fanart thumbs. Every generated file carries an `eros-nfo-v2` signature line; older sparse NFOs without it are treated as stale and regenerated, current-format files are left untouched.
- **`folder.jpg`** — the provider cover, downloaded at enrichment time (best-effort; a failure never breaks enrichment). Scenes without provider art can get an auto-extracted poster frame instead.

The optional `store_images_locally` setting (default off) additionally caches artwork under the app data directory and makes the NFO prefer local thumbs. No library server is required — see [Integration](./integration).

## Disks and path selection

Storage is configured as a list of paths (`paths` setting), each with a usage (`download`, `storage`, or `both`), a priority, and free-space thresholds — **warning at ≤15% free, critical at ≤5% free** by default, per-path overridable. The `disk-monitor` job checks every 30 minutes and surfaces warnings/critical paths on the dashboard.

Selection rules (`disk_selection_mode`):

- **`auto`** (default) — the path with the most free space wins; downloads also check that the release fits.
- **`manual`** — the lowest priority number wins.
- A subscription's dedicated download path, when set and healthy, takes precedence for its grabs.
- Paths below their critical threshold are treated as unhealthy and skipped; if *no* path is healthy, selection degrades to the most-available path with a warning rather than failing.

Downloads stage in deterministic per-torrent folders (`<download-path>/eros-<hash12>`), which isolates same-name releases and lets re-adds reuse the folder so the client rechecks instead of re-downloading. Disk-full and orphan-cleanup behavior is covered in [Troubleshooting](./troubleshooting).
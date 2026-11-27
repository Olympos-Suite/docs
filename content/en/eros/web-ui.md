---
title: "Web UI"
description: "A screen tour of Eros's dark-mode-first web app: dashboard, search, subscriptions, downloads, jobs, logs, and settings."
section: "User Guide"
order: 110
---

The web app is a Next.js single-page experience served on port `9697` (container `3000`). It is **dark-mode-first with two selectable dark themes**: `psyche` (the default, neutral palette) and `classic` (the original Eros palette), switchable in Settings → General with instant apply. The choice persists per browser and in the `ui_theme` setting. The sidebar carries seven screens: **Dashboard, Search, Subscriptions, Downloads, Jobs, Logs, Settings**. Filters, tabs, and pagination live in the URL, so any filtered view is shareable and survives back/forward. Before an admin exists the app gates everything behind `/setup`; afterwards, unauthenticated visits land on `/login`.

## Dashboard

The landing page (`/`) is a live overview with a freshness chip ("Updated HH:MM:SS") and a manual refresh button:

- **Summary strip** — one compact card with seven cells: library size (verified on disk), scenes, enriched (with percentage), unmapped, subscriptions, downloads (active count plus queued/seeding sub-line), and stalled. The unmapped and stalled cells link into the relevant lists.
- **Live row** — a downloads card polling every 5 s with per-torrent progress, and a storage-volumes card showing one row per filesystem with free-space status (ok / low / critical) and a "write target" badge on the organizer's current target volume.
- **Stalled band** — appears only while stalled downloads exist; removing one deletes the torrent and its files from the client and blacklists it, while the scene stays in the library for retry.
- **Activity and recent scenes** — a job-labelled activity timeline (consecutive identical runs collapse into one row) and a four-tile poster grid of recent scenes.

A critical-disk-space banner deep-links into Settings → Files & storage when any volume drops below its threshold.

## Search

`/search` has two tabs.

**Metadata** — search TPDB and StashDB for performers and studios (provider toggle: All / TPDB / StashDB; type tabs: All / Performers / Studios). Clicking a card opens the subscribe dialog: a **required quality profile** (the default profile is pre-selected), include/exclude word filters, and toggles for search aliases, megapacks, and compilations. Confirming creates the entity if needed and subscribes in one flow — this is the entry point for automation. See [Subscriptions](./subscriptions).

**Torrents (discovery)** — manual indexer search. The query lives in `?q=`; results are aligned rows with indexer badges, size, seeder/leecher counts, publish date, and client-side sorting (relevance / seeders / size / newest). A match-reason indicator flags blocked or penalized hits (blacklist, queue duplicate, spam, zero seeders) with per-reason tooltips. Searches can take a while — the proxy allows 180 s and the UI shows a live elapsed counter. The download dialog offers scene handling (**Auto / Single scene / Megapack**) and an optional relation to a subscribed performer or studio. See [Discovery](./discovery).

## Subscriptions

`/subscriptions` browses the library in card grids (**Performers / Studios / Scenes** tabs) or a dense table view. Toolbars carry subscribe-state, type, and status filters, search, tag facets, and — on the Scenes tab — Downloads and Quality multi-filters plus sort and per-page controls. Bulk selection drives subscribe/unsubscribe and scene-delete actions with progress toasts.

Subscribed performer/studio cards show a **scene-stats line** under the name: a micro meter plus `downloaded/total` counts answering "how much of this subscription is in my library". Scene cards carry a download-status badge and a bottom overlay bar with quality, file size, and duration (each hidden when unknown).

Opening a subscription (`/subscriptions/:id`) renders the performer or studio detail page with the **subscription control center** — one card directly under the header:

- Status pill and Pause/Resume button.
- Quality profile and download path selects (path options show free space; "Auto" follows the global selection mode).
- Aliases / Megapacks / Compilations toggles that save immediately.
- Include/exclude word filters with a dirty-gated Save button.
- A kebab menu: **Enrich Scenes** (bulk re-verification with a verified/stripped/duplicates summary toast), **Copy External IDs**, **Clear Blacklist**, and **Unsubscribe** (two-outcome confirm: delete scenes or keep scenes — see [Deletion semantics](./deletion-semantics)).

Below the card sits the subscription's scene grid with download badges and live progress. A quick-edit dialog on list cards offers the same settings without leaving the list.

## Scenes, performers, studios

**Scene detail** (`/scenes/:id`) shows the cover artwork, cleaned title with download/metadata status badges, date and duration chips, external TPDB/StashDB links, and the description. The right column carries linked studios/performers, a **File Information** card merging database metadata with live on-disk facts (size, resolution, codec, duration, bitrate, quality label), and NFO/folder paths. Actions: **Re-verify Metadata** (hash-only re-check; the toast tells you whether metadata was refreshed, stripped for lack of evidence, or a duplicate was deleted), copy external IDs, and delete. Deleting an active scene is a **soft delete** — files go, the record stays restorable; deleting an already-deleted scene purges it permanently. Scenes with no relations get a **Relate** card to attach a subscribed performer/studio.

**Hover previews.** Dwell on a scene cover or card for ~500 ms and a Jellyfin-style filmstrip appears (10 frames on the detail banner, 6 on cards): scrub with the pointer or arrow keys to see a highlighted frame and timecode. Frames are extracted from the actual video on demand and cached; the feature is gated by `hover_previews_enabled`. When artwork was auto-extracted from the file instead of a provider, a small wand badge marks it ("Extracted from file — no metadata").

**Performer/studio detail** pages show profile metadata, an image carousel (performers) or hero (studios), the scene grid, and a blacklist card. Deep links to a subscribed entity redirect to its subscription page so the control center is always in reach.

Badge vocabulary across the app:

| Color | Meaning |
|-------|---------|
| Emerald | Downloaded / in library / subscribed |
| Blue | Downloading (in flight) |
| Sky | Pending / discovered |
| Teal | Seeding |
| Amber | Paused / exhausted |
| Red | Failed |
| Muted | No activity |

## Downloads

`/downloads` is the live queue table: progress, speed, and ETA per torrent, polled every 2 s while anything is active (polling stops when the queue is idle). Status is grouped into **To Download / Downloading / In Library / Failed** with a filter row and name search. Progress columns are read-only — download-phase policy (speed limits, auto-pause/resume) belongs to [Zephyrus](../zephyrus/); Eros offers manual actions only: **Pause, Resume, Retry, Remove, Delete & Blacklist**, per row or in bulk via the selection bar. Failed rows show the error message under the torrent name; rows linked to a scene deep-link to its detail page. See [Download management](./download-management).

## Jobs

`/jobs` shows all eleven background jobs as cards sorted running → scheduled → idle: human-readable schedule, next-run countdown, live progress while running, and a mini run history. **Run Now** triggers a job immediately; the history dialog lists recent runs with status, duration, and per-step detail. A recent-activity feed deep-links into the Logs screen filtered by job and level. Schedules and on/off toggles are edited in Settings → Jobs; the four essential pipeline jobs are always on. See [Configuration](./configuration).

## Logs

`/logs` is the unified application log viewer with three genuinely different modes: **Summary** (single-line feed), **Detailed** (default, five-column table), and **Debug** (dense table with job type, run id, and ISO timestamps). Filters — severity chips with counts, category → source selects, job type, search, date range — all live in the URL. Expanding a row opens a structured detail panel; job-run rows also list their individual steps. The header offers manual refresh and CSV export (first 200 filtered records). The list auto-refreshes every 5 s.

## Settings

`/settings` is a grouped left-rail hub with nine sections: **General** (theme picker, hover previews and frame count, change password, community hash contribution), **API keys** (create with one-time reveal, revoke), **Services** (connection CRUD and tests), **Matching** (method, thresholds, models, search budgets), **Quality profiles** (edit/duplicate/delete, default flag), **Torrents** (category, group fallback, quality upgrades, stalled detection, seed time), **Files & storage** (paths and thresholds, disk selection mode, folder template, local image caching, retention, library scan and audit), **Jobs** (automation toggles and per-job cron editor with presets and next-run preview), and **Backups** (create, download, delete, typed-confirm restore). Form pages use an explicit Save with an unsaved-changes guard; action-driven resources (connections, profiles, schedules, theme) save immediately. Every setting is documented in [Configuration](./configuration).
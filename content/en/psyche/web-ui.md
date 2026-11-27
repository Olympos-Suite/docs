---
title: "Web UI"
description: "A tour of Psyche's screens: library, discover, search, wanted, queue, calendar, detail pages, and the tabbed settings page."
section: "User Guide"
order: 90
---

Psyche's web app is a Next.js App Router site served on port `3000` (host `9698`). Pages are thin routing shells over client views; all data flows through the `/api` proxy to the internal Fastify server. View state lives in URL parameters wherever it matters, so screens are linkable and back/forward behaves.

## Navigation

The top nav has seven destinations, with live count badges on Wanted and Queue:

| Screen | URL | Purpose |
|--------|-----|---------|
| Discover | `/discover` | TMDB trending/popular/upcoming surfaces. |
| Search | `/search` | Find series, movies, and people on TMDB. |
| Library | `/library` | Everything you've added, series and movies. |
| Wanted | `/wanted` | Open release requests + interactive search. |
| Queue | `/queue` | Active and historical downloads. |
| Calendar | `/calendar` | Upcoming episodes of monitored series. |
| Settings | `/settings` | All configuration, one tabbed page. |

Unauthenticated visits redirect to `/login`; a fresh install with no admin routes to `/setup` (see [Installation](./installation#first-run)).

### Login and setup

- **`/setup`** appears only while no admin account exists: create the username/password once, and the app signs you in. After that the route is closed (`POST /api/auth/setup` is one-shot).
- **`/login`** is the standard session login. Any `401` from the API bounces the UI back here automatically; `SETUP_REQUIRED` routes to `/setup` instead.
- The admin password can be changed in **Settings → General**; the current session stays valid across the change.

The nav's **Wanted** and **Queue** items carry live count badges, so open work and active downloads are visible from every screen.

## Library

`/library` lists persisted series and movies as poster cards (title, year, added date, status and anime badges). Two tabs — **Series** and **Movies** — with counts; a title filter box narrows the active tab. Tab and filter live in the URL (`?tab=movies&q=...`). Cards link to the detail pages. An empty library points you at Discover and Search.

## Discover

`/discover` shows poster grids for the selected surface (**Trending / Popular / Upcoming**), media (**TV / Movies**), and — for trending — window (**Today / This week**). State is in `surface`, `media`, `window`, `page` params; Previous/Next paginate. Every card has an **Add to library** button opening the subscription flow. Details in [Discovery](./discovery#discover-surfaces).

## Search

`/search` is a debounced query box over TMDB with type tabs (**All / TV / Movies / People**) and pagination; `q`, `type`, `page` live in the URL. Results mix poster cards and person cards, each addable on the spot. This searches *metadata*, not releases — release search lives in the Wanted dialog.

## Wanted

`/wanted` groups open work by kind: episode requests per series (with season/episode and any gate reason), season-pack requests, and wanted movies. Each row opens the **interactive search dialog**: run a release search for that target, review scored candidates (quality tag, seeders, size, score), and grab one. Blocked rows show why — most often a [quality-gate](./subscriptions#the-quality-gate) reason. See [Subscriptions](./subscriptions#wanted).

## Queue

`/queue` lists download rows newest-first with status, progress, size, quality tag, and the linked subscription. An optional status filter narrows the list. Row actions: **pause**, **resume**, **retry** (failed/paused only), and **delete**. Stalled rows carry a `stalled: …` error message; failed rows show the failure reason and retry state. The status vocabulary and actions are documented in [Download management](./download-management#the-download-queue).

## Calendar

`/calendar` renders upcoming/aired episodes of monitored series in the resolved window (default today + 14 days, max 62). The server-resolved `from`/`to` are always displayed, so you can see exactly which range you're looking at. See [Subscriptions](./subscriptions#calendar).

## Detail pages

- **Series** (`/series/:tmdbId`) — poster, title and original title, status (returning/ended/canceled), first/last air dates, overview, seasons list, anime badge when flagged. The **subscription panel** provides the monitored toggle, quality-profile select, and grab-policy override display.
- **Movie** (`/movie/:tmdbId`) — poster, title/original title, release date, runtime, genres, overview, and the same subscribe/panel controls.
- **Person** (`/person/:tmdbId`) — profile, biography, dates, also-known-as, and the combined-credits filmography (cast + crew). Titles are addable individually; people themselves are not subscribable.

## Settings

`/settings` is a **single page with a grouped nav rail** — no per-tab routes. The active tab lives in `?tab=` (deep links work; `general` is the default and omits the param). Tabs with explicit-save forms warn before discarding unsaved edits when you navigate away.

| Group | Tab (`?tab=`) | Contents |
|-------|---------------|----------|
| — | `general` | Theme, metadata language + fallback, account password. |
| — | `api-keys` | Create/revoke API keys; plaintext shown once. |
| Integrations | `services` | Unified connection registry: TMDB, indexers, torrent clients; priority column, test probes. |
| Integrations | `matching` | Similarity method, thresholds, cross-encoder model. |
| Downloads | `quality-profiles` | Profile cards with preference badges; create/edit/delete. |
| Downloads | `torrents` | Stalled policy, sequential download, first/last piece priority, quality upgrades. |
| Downloads | `blacklist` | Banned infoHashes; remove entries. |
| Storage | `files` | Paths table, disk selection mode, folder templates, artwork caching, retention, library audit. |
| Automation | `jobs` | Schedule overrides, enable/disable, run-now, job history. |
| System | `backups` | Create/download/restore/delete SQLite snapshots. |
| System | `logs` | Application log viewer with level/search filters; clear logs. |

The setting keys behind each tab are referenced in [Configuration](./configuration#settings-groups).

## Jobs and logs

The **Jobs** tab lists all ten background jobs with their effective schedule, essential/enabled flags, live progress, and last run; each job has an enable switch (essential jobs never render one), a cron override editor with presets, a run-now trigger, and a run-history viewer. The **Logs** tab shows persisted, redacted application events newest-first, filtered by minimum level and a substring search. Both are covered operationally in [Troubleshooting](./troubleshooting#logging).
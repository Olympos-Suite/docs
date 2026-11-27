---
title: "Discovery"
description: "Find series and movies through TMDB trending surfaces, search, and person filmographies — and add them to the library from anywhere."
section: "User Guide"
order: 30
---

Everything you can add to Psyche comes from **TMDB**, the single metadata source. Discovery is browse-first: you look at what TMDB knows, then subscribe. The library entity is created from TMDB at that moment — before any release is searched. See [Subscriptions](./subscriptions) for what happens next.

## Discover surfaces

The **Discover** page (`/discover`) shows three TMDB surfaces, each for TV or movies:

| Surface | What it shows |
|---------|---------------|
| Trending | What's trending right now — window **Today** or **This week**. |
| Popular | TMDB's popularity ranking. |
| Upcoming | Titles announced but not yet released/aired. |

The state lives in URL parameters — `surface`, `media`, `window` (trending only), `page` — so views are shareable and back/forward works. Pagination is Previous/Next over TMDB's pages.

Every poster card carries an **Add to library** button that opens the subscription flow directly. You do not need to visit the detail page first.

## Search

The **Search** page (`/search`) queries TMDB across four types: **All**, **TV**, **Movies**, **People**. The query box is debounced (400 ms) and mirrors the URL (`q`, `type`, `page`), so a search is a link you can bookmark. Results are a mixed grid of poster cards and person cards, 20 per page.

This is *metadata* search — finding titles to add. Searching for actual releases to download happens later, per subscription, from the [Wanted view](./subscriptions#wanted) or the interactive search dialog.

## People

Person pages (`/person/:tmdbId`) show the TMDB profile: name, photo, biography, birth/death dates, also-known-as, and a **combined-credits filmography** (cast + crew, with character or department).

> [!IMPORTANT]
> People are **browsable, not subscribable**. There is no "monitor this person" feature — you browse a filmography and add individual titles manually. Any title on a person page can be added to the library on the spot.

## Detail pages

Every title has a TMDB-backed detail page, reachable from any grid or from the library:

- **Series** (`/series/:tmdbId`) — poster, title and original title, status (returning/ended/canceled), first/last air dates, overview, the seasons list, and an anime badge when the detection heuristic flags it.
- **Movie** (`/movie/:tmdbId`) — poster, title and original title, release date, runtime, genres, overview.
- **Person** (`/person/:tmdbId`) — the filmography view described above.

Detail reads accept an optional `language` override; otherwise your configured language order applies. Once a title is subscribed, its detail page also hosts the subscription panel (monitored toggle, quality profile) — see [Subscriptions](./subscriptions#managing-subscriptions).

## Adding to the library

You can subscribe/add from three places, all with the same flow:

1. A **Discover** poster card,
2. a **Search** result,
3. a **person's filmography** (or a series/movie detail page).

On submit, the server:

1. **Persists the entity from TMDB first** — series with all seasons and episodes backfilled, or the movie with its metadata. This can take a few seconds for long series.
2. Creates the **subscription** (monitored series, or a wanted movie request), resolving the default [quality profile](./quality-profiles) when you don't pick one.
3. Generates **release requests** for what's missing.
4. Triggers an **immediate auto-search** for the new subscription (a detached lane on top of the hourly cycle).

Adding a title that is already in the library reuses the existing entity — TMDB ids are unique, so nothing is duplicated. Subscribing to an already-subscribed title is a `409 CONFLICT`.

## The metadata cache

All browse traffic is cache-first, which keeps discovery fast and TMDB rate-limit friendly:

| Data | TTL |
|------|-----|
| Search results | 1 hour |
| Discovery surfaces | 6 hours |
| Series/movie/person details | 24 hours |
| Image CDN configuration, genres | 7 days |

Cache keys include the endpoint, ids, and language. Artwork is downloaded once into `/data/metadata/artwork` and served from disk afterwards — the artwork proxy handles posters, backdrops, episode stills, and person profiles. Detail calls fetch translations and images in a single round-trip (`append_to_response`), and localized text resolves through your configured [language fallback](./metadata-pipeline#language-fallback).

If TMDB is unreachable but an entry is cached, browsing keeps working from the cache. Without a configured TMDB key, discovery and search fail fast with an actionable `REQUEST_ERROR` — see [Troubleshooting](./troubleshooting#degraded-modes).
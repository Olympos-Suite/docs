---
title: "Subscriptions"
description: "How Psyche monitors series and movies: grab policies driven by TMDB status, release requests, the wanted view, and the calendar."
section: "User Guide"
order: 40
---

A subscription is Psyche's standing instruction to acquire a title. There are two kinds, and they are **mutually exclusive**: a subscription targets exactly one series *or* one movie (enforced by a database CHECK constraint), and each entity can have at most one subscription.

## Series subscriptions

Subscribing to a series creates a **monitored** subscription. The entity — series, seasons, episodes — already exists in the library from TMDB (see [Discovery](./discovery#adding-to-the-library)). From then on:

- The **subscription-refresh** job (every 6 hours) re-syncs monitored series against TMDB: new seasons, new episodes, status changes.
- The **release-request engine** turns gaps into requests: episodes that have aired but have no file, or whole seasons that are complete.
- The **subscription-search** job (hourly) searches wanted requests within the `search.subscriptionBudget` rotation; subscribing also triggers an immediate search.

Turning **Monitored** off stops *new* request generation and excludes the series from scheduled searches. Existing requests are kept.

## Movie subscriptions

Adding a movie creates a **wanted request**: one `movie` release request, searched immediately and re-searched on the cycle until a file lands. A wanted movie without a file is re-searched after `search.wantedMovieRetryDays` (default 7 days) even if it was searched recently. Movies have no seasons or episodes — the request is satisfied by linking one file.

## Grab policies

For series, the request engine follows **TMDB season status**, not indexer availability:

| Season state | Requests generated |
|--------------|--------------------|
| **Complete** — the series is ended/canceled, or a later season exists | One **season-pack** request for the whole season. |
| **Airing** | One request per **aired** episode (air date ≤ today, UTC). Unaired episodes generate nothing. |

When an airing season completes, its outstanding wanted episode requests are **superseded by a season pack** (status `skipped`, reason `superseded by season pack`) — the pack fetch replaces the episode-by-episode chase. Partial packs import only the episodes they contain; missing ones stay wanted.

A per-subscription **grab policy override** (`season-pack-first` or `episode-first`) can pin the policy regardless of status. It is set via the API (`PUT /api/subscriptions/:id`); the detail page's subscription panel shows the active override.

Every request carries a status — `wanted`, `satisfied`, or `skipped` — and a `reason` when the [quality gate](./release-matching#the-quality-gate) blocks it. Requests are deduplicated server-side; see [Database](./database#the-sentinel) for the mechanics.

## The quality gate

A subscription's [quality profile](./quality-profiles) decides what may be grabbed:

- At creation, a subscription without an explicit profile gets the **default profile's id** stamped in.
- A subscription with **no profile** (no default existed at creation, or its profile was deleted) is gated *before any indexer call*: every open request shows `no quality profile set — set one to enable downloading`. Assign a profile to unblock it.
- During search, a release matching **no preference** is excluded from auto-grab candidates, and the reason is surfaced on the request.

## Wanted

The **Wanted** page (`/wanted`) is the work queue of everything Psyche still needs:

- open **episode requests grouped by series**, with season numbers and gate reasons,
- **season-pack** requests,
- **wanted movies**.

Each row has an **interactive search dialog**: it runs a manual release search (`POST /api/search`) for that exact target, lists scored results, and lets you pick one to grab. This is the escape hatch when automation is blocked or you want a specific release — manual grabs bypass the auto-grab gate but still respect the blacklist and duplicate guards.

## Calendar

The **Calendar** page (`/calendar`) shows upcoming and recently aired episodes of **monitored series** within a resolved window:

- Default window: **today + 14 days**.
- Maximum span: **62 days** (longer requests are clamped).
- `from`/`to` are optional ISO dates; the response always carries the resolved window, and the UI displays it.

The calendar is a view over persisted episode air dates — it does not query TMDB live.

## Monitoring end-to-end

A concrete walkthrough for a monitored, airing series:

1. **Subscribe** — the series, its seasons, and all episodes are persisted from TMDB; the default profile is stamped in; an immediate search runs for anything already missing.
2. **Refresh (every 6 h)** — TMDB is diffed: a newly announced episode appears in the library with its air date. Nothing is searched for it yet — it hasn't aired.
3. **Air date passes** — the next request generation creates a `wanted` episode request (air date ≤ today UTC).
4. **Search (hourly, within budget)** — the request is queried on your indexers; candidates are filtered, deduped, and scored against the profile. A matching release is grabbed; the queue row carries the score verbatim.
5. **Download** — the poller mirrors progress; on completion the organizer links the file to the *existing* episode row and marks the request `satisfied`.
6. **Season completes** — when a later season appears (or the series ends), remaining wanted episode requests are superseded by one season-pack request instead.

If step 4 finds nothing, the request stays `wanted` with a reason (gate block, no results) and is retried on later cycles. If a download fails permanently, its hash is blacklisted and step 4 eventually finds a *different* release — the request never changes.

## Managing subscriptions

There is no standalone subscriptions screen; management happens where the context is:

- **Series/movie detail pages** carry the subscription panel: monitored toggle, quality-profile select (choosing "none" clears the profile), and the grab-policy override display.
- **Wanted** shows per-subscription open work and the search dialog.
- The **API** exposes the full surface: `GET /api/subscriptions` (with wanted counts), `PUT /api/subscriptions/:id` (partial update; `null` clears profile/override), `DELETE /api/subscriptions/:id` (release requests and queue rows cascade).

Deleting a subscription removes its requests and queue history but **never touches library entities or files** — the library is the durable side.
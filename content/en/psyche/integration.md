---
title: "Integration"
description: "Psyche's external contracts: the Zephyrus group-naming adoption pattern, Prowlarr/Torznab indexers, and TMDB as the single metadata source."
section: "User Guide"
order: 100
---

Psyche integrates with three kinds of external system: an optional download-policy layer (Zephyrus), indexers (Prowlarr or Torznab/Newznab), and the metadata provider (TMDB). All three are configured as [service connections](./configuration#service-connections) except Zephyrus, which needs no configuration in Psyche at all.

## The Zephyrus contract

[Zephyrus](../zephyrus/) is the suite's optional torrent download-phase policy service (smart queuing, prioritization, schedules, stalled management). The integration is **one convention and zero API calls**:

1. Psyche adds torrents **directly to its own torrent client**, assigning every grab to the group `psyche` — the qBittorrent **category** or Transmission **label**, set by `downloads.category` (default `psyche`).
2. A Zephyrus instance watching that client with a `psyche` key in its `groups` config **adopts** those torrents on its next group scan and applies its policies from then on.
3. There are **no direct calls in either direction** — no webhooks, no event channel. Psyche never talks to Zephyrus; Zephyrus never talks to Psyche.

Consequences worth knowing:

- **Zephyrus is optional.** Without it, Psyche's torrents download, seed, and are removed by Psyche using the client's defaults. Nothing in Psyche depends on it.
- **Ownership stays with Psyche.** Zephyrus only pauses/resumes/limits torrents it manages, and only resumes ones it paused itself. Removal decisions (the [retention sweep](./download-management#retention)) always belong to Psyche.
- **Pauses don't fight.** When Zephyrus pauses a managed torrent, Psyche's poller mirrors the state into the queue as `paused`. Psyche's automatic resume only fires for its *own* backoff pauses (rows with a due `next_retry_at`), so the two services never tug-of-war over a torrent.
- **Rename the group, lose the adoption.** If you change `downloads.category` away from `psyche`, update the Zephyrus `groups` key to match — adoption is exact, case-sensitive group matching.

The full contract from the other side is in [Zephyrus → Integration](../zephyrus/integration).

## Indexers

Release search fans out over every active `indexer` connection. Two implementations ship:

| Implementation | Wire protocol | Notes |
|----------------|---------------|-------|
| **Prowlarr** | `GET /api/v1/search` (+ `/api/v1/health` for the test probe) | The primary indexer manager — one connection aggregates many trackers server-side. |
| **Torznab/Newznab** | Standard Torznab `search`/`tvsearch`/`movie` queries | Direct indexer endpoints as an alternative. |

Both sit behind the same `SearchProvider` contract with a normalized result shape (title, size, seeders, infoHash, download/magnet URLs, publish date, categories). Connection specifics:

- **Categories are per-connection configuration** — the category ids you set on the connection are sent as the `categories` parameter (Prowlarr) or `cat` (Torznab), mapping the search to your trackers' TV/movie sections.
- **Torznab authenticates only via the `apikey` query parameter** (never logged); its test probe is the lightest possible call, `t=caps`. Prowlarr uses its API key header and probes `/api/v1/health`.
- **Prowlarr releases may ship only a download link** (no magnet). The client adapters resolve such links — they may serve `.torrent` bytes or redirect to a magnet URI — and derive the torrent hash from whichever source answers.

Behavior of the fan-out:

- **Priority order** — lower `priority` number first; searches are staggered by `search.delayMs` (default 1 s) as rate-limit etiquette.
- **Per-indexer isolation** — one indexer's failure never blocks the others. Errors surface per indexer with sanitized messages (no credentials, no full URLs).
- **Manual search is single-attempt per indexer** — no 429 retries on the interactive path; automated indexer calls use `search.retries` with exponential backoff from `search.retryBaseDelayMs`.
- **Error mute** — after `search.indexerErrorThreshold` consecutive failures (default 5), an indexer is muted for `search.indexerErrorMuteHours` (default 24) and skipped on subsequent searches. A success or expiry clears the mute.
- **No indexers configured** → searches return empty results with zero upstream calls.

Results are filtered (spam, zero seeders), deduped by infoHash, and scored once — see [Release matching](./release-matching#the-pipeline).

## TMDB

TMDB is the **single metadata source** — there is no second provider and no fallback source. Its credentials live in the one `metadata_provider` service connection (not in the settings store):

- **v3 API key** (32 hex characters) → sent as the `api_key` query parameter on every call.
- **v4 read-access token** (JWT starting with `eyJ`) → sent as `Authorization: Bearer` on every call.

Credentials are **re-read on every request**, never cached in the adapter; a missing or inactive connection fails fast with actionable guidance before any upstream call. Detail calls use `append_to_response=translations,images` to fetch localized text and artwork in one round-trip.

All reads are cache-first with per-endpoint TTLs and ordered language fallback, and artwork is downloaded once to `/data/metadata/artwork`. The cache layers and fallback order are documented in [Metadata pipeline](./metadata-pipeline#the-tmdb-cache).

## What Psyche does not integrate with

Coming from the *arr ecosystem, some expected integrations are deliberately absent in v1 — they are deferrals, not configuration you haven't found yet:

- **No watchlist/import-list sync** (Trakt, Plex, or similar). Discovery plus manual add covers the core loop; your library starts empty and grows through the UI.
- **No notification webhooks** (ntfy, Discord, Telegram, …). State is visible in the Wanted/Queue screens and the logs instead.
- **No subtitle fetchers** — subtitles are out of scope; dedicated tools own that domain.
- **No request/approval portal** — Psyche is single-admin; there is no multi-user request workflow.

The extension surface that *does* exist is the typed [adapter contracts](./adapters): new metadata providers, indexers, and torrent clients can be added as code. A plugin runtime is not part of v1.

## Connection checklist

A working setup, in order:

1. **TMDB** (`metadata_provider`) — add the v3 key or v4 token, test, save. Verify: Discover shows posters.
2. **Indexer** (`indexer`) — add Prowlarr (base URL + API key) or a Torznab endpoint (URL + apikey + category ids), test, save. Verify: a manual search from Wanted returns results.
3. **Torrent client** (`torrent_client`) — add qBittorrent or Transmission (URL + credentials), test, save. Verify: a grab appears in the client under the `psyche` category/label.
4. **Optional Zephyrus** — point a Zephyrus instance at the same client with a `psyche` group key. Verify: the torrent shows up in Zephyrus's managed set.

Each step is independent: a missing indexer degrades search only, a missing client degrades grabbing only, and a missing Zephyrus changes nothing.
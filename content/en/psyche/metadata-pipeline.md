---
title: "Metadata Pipeline"
description: "The end-to-end flow from TMDB anchor to organized file, the cache layers and ordered language fallback, and the dedup mechanics."
section: "Developer Guide"
order: 20
---

This page traces one title through the whole system. The invariant that shapes every stage: **entities exist before downloads** — each stage consumes the previous stage's persisted output, and nothing downstream ever re-identifies or re-scores.

## End-to-end flow

```text
TMDB metadata → library entity → subscription → release requests
  → indexer search → quality gate → grab → download queue
  → file organizer links files to the pre-existing entity
```

1. **Metadata** (`MetadataService` + TMDB adapter). Search, discovery, series/season/episode details, movie details, person filmography — cache-first reads over the `MetadataProvider` contract. Adding a title persists the entity: series + seasons + all episodes (backfilled), or the movie, plus preferred-language localizations. Anime detection (Animation genre 16 + Japanese language/origin) sets the series flag here.
2. **Subscription** (`SubscriptionService`). One row per entity (XOR series/movie), monitored by default, with the default quality profile stamped in at creation. Subscribe triggers a detached immediate search on top of the hourly cycle.
3. **Release requests** (`ReleaseRequestService`). Complete seasons → one `season_pack` request; airing seasons → per-aired-episode requests; movies → one `movie` request. Completion converts open episode requests to `skipped` (`superseded by season pack`). Generation is idempotent via the dedup UNIQUE key.
4. **Search & match** (`SearchService`, `QueryNormalizer`, `ScoringService`, `SimilarityService`). Normalized queries fan out over active indexers (priority order, staggered, per-indexer isolation); spam/zero-seeder filters, infoHash dedup, title-similarity gate, then score-once against the profile. Only preference-matched releases are auto-grab candidates.
5. **Download** (`QueueService`, `QueuePollerService`). The grab persists score/quality tag verbatim and places the torrent on a client under the `psyche` group. The poller mirrors state through the legal-transition guard, handles stalls, and runs failure backoff → blacklist.
6. **Organize** (`LibraryOrganizerService`). Completed/seeding rows resolve queue → request → subscription → entity; the client moves and renames the data; `episode_files`/`movie_files` rows link absolute paths; NFO + poster sidecars come from cached metadata. Retention later removes the redundant client copy.

The refresh job (every 6 h) re-enters the flow at stage 1 for monitored titles: TMDB diffs produce new seasons/episodes, which produce new requests.

### Stage ownership

| Stage | Service(s) | Driven by |
|-------|------------|-----------|
| Metadata reads | `MetadataService`, `ArtworkService` | API requests (cache-first) |
| Entity persistence | `MetadataService` | Add/subscribe calls |
| Subscriptions | `SubscriptionService` | API + subscribe-time search attach |
| Request generation | `ReleaseRequestService` | `subscription-refresh` job, subscribe |
| Search & scoring | `SearchService`, `QueryNormalizer`, `SimilarityService`, `ScoringService` | `subscription-search` job, manual search |
| Grab & queue | `QueueService` | Auto-grab, `POST /api/queue/grab` |
| State mirror & failure handling | `QueuePollerService` | `queue-poller` job (30 s) |
| Organize & sidecars | `LibraryOrganizerService` | `library-organizer` job (5 min) |
| Client-copy retirement | `LibraryOrganizerService.retainOnce` | `download-retention` job (hourly) |

Each stage reads only persisted output of the previous one — there is no in-memory hand-off that a restart could lose. A crash between any two stages resumes cleanly at the next job tick.

## The TMDB cache

`metadata_cache` is a key-value table (`key`, `payload` JSON, `expiresAt`, `fetchedAt`) fronting every provider call. Keys encode endpoint + ids + language (e.g. `search|<type>|<lang>|<page>|<query>`, `trending|<media>|<window>|<lang>|<page>`).

| Layer | TTL |
|-------|-----|
| Search results | 1 h |
| Discovery surfaces | 6 h |
| Series/movie/person details | 24 h |
| Bootstrap (image CDN config, genres) | 7 d |

Reads are cache-first: a fresh entry serves without any upstream call; an expired entry triggers one provider call and rewrites the row. The hourly `metadata-cache-cleanup` job prunes expired rows. Artwork is a separate disk cache under `/data/metadata/artwork`, keyed by a content hash of (size, path) — each size variant downloads once. The organizer's poster sidecar reads that same cache at the poster size, so a poster you already browsed is copied into the library with no network access.

Detail calls use `append_to_response=translations,images` — one round-trip yields localized text and artwork together, which is what makes per-language caching cheap. Credentials are re-read from the `metadata_provider` connection on **every** call; a missing/inactive row fails fast before any upstream work.

## Language fallback

Localized text resolves per-field through an ordered list, silently (never a UI presentation concern):

```text
request language → metadata.language → metadata.language_fallback[] → original language
```

`languageOrder` deduplicates the chain; if everything is empty it falls back to `en`. The order is a property of **cached metadata**: localizations for the preferred languages are persisted at add time (`series_localizations`, `movie_localizations`), so later reads and refreshes resolve from the library without re-querying TMDB. This is the structural fix for the *arr language-fallback failure mode — fallback never depends on what a release file happens to be named.

## Dedup mechanics

Dedup happens at three distinct layers, each with its own key:

| Layer | Key | Mechanism |
|-------|-----|-----------|
| Release requests | `(subscription_id, request_type, season_number, episode_number)` | UNIQUE index; "not applicable" components use sentinel `-1` (SQLite NULLs are distinct in unique indexes). `createIfAbsent` makes generation idempotent. See [Database](./database#the-sentinel). |
| Search results | `infoHash` | Within one fan-out, duplicate hashes collapse to the highest-seeder instance; hash-less releases skip dedup. |
| Download queue | `infoHash` (UNIQUE) + blacklist | A hash already queued or banned is rejected at grab (409). NULL hashes (non-torrent rows) coexist freely. |

The layers compose: request dedup stops duplicate *work*, search dedup stops duplicate *candidates*, and the queue/blacklist guards stop duplicate *grabs*. Because a failed download's hash is banned permanently, recovery always means a different release — which is exactly what makes the queue's UNIQUE constraint safe long-term.
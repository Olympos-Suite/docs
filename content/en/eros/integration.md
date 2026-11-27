---
title: "Integration"
description: "Eros's external contracts: the Zephyrus category-adoption pattern, Prowlarr/Jackett/Torznab indexers, TPDB and StashDB metadata, Jellyfin-friendly output, and API keys."
section: "User Guide"
order: 120
---

Eros is a standalone app: it talks to indexers, a torrent client, and metadata providers — all configured as service connections under **Settings → Services** — and to nothing else in the suite. No suite app calls another; the only inter-app contract is a naming convention on the torrent client.

## The Zephyrus contract

[Zephyrus](../zephyrus/) is the suite's optional download-phase policy service (speed limits, schedules, smart pause/resume). The integration is **one convention and zero API calls**:

1. Eros adds torrents **directly to its own torrent client**, assigning every grab to the category `eros` (the `torrent_category` setting, default `eros`) and tagging it `subscription:<id>`.
2. A Zephyrus instance watching that client with an `eros` key in its `groups` config **adopts** those torrents on its next poll and applies its policies from then on. Matching is exact and case-sensitive — `Eros` does not match `eros`.
3. There are no calls in either direction. Eros never talks to Zephyrus; Zephyrus never talks to Eros.

Consequences worth knowing:

- **Zephyrus is optional.** Without it, torrents download under the client's defaults and Eros's own lifecycle runs unchanged.
- **Speed limits and schedules stay external.** Eros deliberately implements no speed-limit or auto pause/resume scheduling — that policy belongs to Zephyrus. Eros keeps the parts that need domain knowledge: [stall detection](./download-management) with optional auto-removal, and group-fallback retries of failed downloads through sibling releases.
- **Ownership stays with Eros.** Zephyrus only pauses/resumes/limits torrents it manages and never removes anything. Seed retention, torrent removal, and file organization are always Eros decisions.
- **Rename the category, lose the adoption.** If you change `torrent_category`, update the Zephyrus `groups` key to match.
- **Adoption needs qBittorrent.** Zephyrus v1 ships a qBittorrent adapter only, and Eros's Transmission adapter ignores categories/tags entirely — Transmission grabs are invisible to the group contract.

The full contract from the other side is in [Zephyrus → Integration](../zephyrus/integration).

## Indexers

Release search fans out over **every active indexer connection in parallel**; results are merged and deduplicated by infoHash (highest seeder kept). One indexer's failure never blocks the others.

| Implementation | Wire protocol | Notes |
|----------------|---------------|-------|
| **Prowlarr** | `GET /api/v1/search`, `X-Api-Key` header | One connection aggregates many trackers server-side. Also used for GUID proxy downloads when a release ships no magnet. |
| **Jackett / Torznab / Newznab** | Standard Torznab `t=search` queries, `apikey` query parameter | Direct indexer endpoints. A bare Jackett origin gets the Torznab API path appended automatically; responses are XML, validated and normalized to the same result shape. |

Shared behavior: per-adapter retries with exponential backoff (429-aware), and an indexer **learning/mute** system — after `indexer_error_threshold` consecutive errors (default 3) an indexer is muted for `indexer_error_mute_hours` (default 6) and skipped by both name and JAV-code searches; a success or expiry clears the mute. JAV searches additionally mute indexers on long zero-hit streaks. With no indexers configured, searches return empty results with zero upstream calls.

## Torrent clients

qBittorrent and Transmission sit behind one client contract. **Exactly one client connection can be active** — activating one deactivates the others; there is no priority column for clients.

| Client | Capabilities |
|--------|--------------|
| **qBittorrent** | Full set: categories/tags, piece states, per-file priorities, in-client moves (`setLocation`), first/last-piece priority. Required for megapack early dedup and Zephyrus adoption. |
| **Transmission** | Add/remove/pause/resume/move work, but **no piece-map capability** — megapack per-file early dedup no-ops, and categories/tags are ignored. |

## Metadata providers

[Enrichment](./metadata-enrichment) queries both **TPDB** (REST API, Bearer API key) and **StashDB** (GraphQL, `ApiKey` header) — TPDB first, then StashDB, each active connection in priority order. Credentials live in the service connections, not in the settings store; all active providers participate in hash matching, and the editable priority column picks the primary provider for performer/studio detail lookups.

Both providers are community databases: the hash lists Eros matches against are user submissions, and Eros gives back — contributing the computed OSHash to TPDB on every match, and to StashDB when the opt-in `contribute_hashes` setting is enabled. More submissions mean stronger evidence for everyone.

An optional LLM connection (Ollama, OpenAI, or Gemini) can serve as the release-selection matcher (`matching_method = llm`); it is not a metadata source.

## Jellyfin-friendly output

Eros writes `movie.nfo` sidecars and `folder.jpg` posters into every scene folder — the Kodi/Jellyfin conventions — so a media server can import the library with correct titles, dates, studios, performers, and art. There is **no server coupling**: no Jellyfin connection, API key, or webhook exists. Point Jellyfin (or any NFO-aware server) at the storage root and it works; the bundled docker-compose ships a Jellyfin service for convenience. See [File organization](./file-organization).

## API keys

Third-party tools and scripts can call the REST API with an Eros API key (`eros_` prefix): send it as `Authorization: Bearer <key>` or `X-Api-Key`. Keys are generated in the UI, shown **once**, and stored only as a SHA-256 hash; revocation is instant. Session auth wins over key auth when both are present. Endpoints and schemas: [API reference](./api-reference).

## Networking

Like every suite app, Eros ships as one image running web + API together: web on container port `3000` (published as host `9697`), API on `3001` **container-internal only**. The browser talks to the web port exclusively; `/api/*` is proxied to the API internally. Publish the API port only temporarily for debugging.

## Connection checklist

A working setup, in order:

1. **Torrent client** — add qBittorrent (URL + credentials) or Transmission, test, save. Verify: a grab appears in the client under the `eros` category (qBittorrent).
2. **Indexer** — add Prowlarr (base URL + API key) or a Jackett/Torznab endpoint (URL + apikey), test, save. Verify: a manual search from [Discovery](./discovery) returns results.
3. **Metadata providers** — add TPDB and/or StashDB credentials, test, save. Verify: completed downloads enrich instead of staying `unmapped`.
4. **Optional Zephyrus** — point a Zephyrus instance at the same qBittorrent client with an `eros` group key. Verify: the torrents show up in Zephyrus's managed set.

Each step is independent: a missing indexer degrades search only, a missing client degrades grabbing only, missing provider credentials degrade enrichment only, and a missing Zephyrus changes nothing.
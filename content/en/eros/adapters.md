---
title: "Adapters"
description: "Outbound HTTP adapters behind the SearchProvider and TorrentClient contracts, the capability vocabulary, TPDB/StashDB metadata clients, unified payload schemas, and the provider-extension checklist."
section: "Developer Guide"
order: 30
---

Every external service Eros talks to sits behind an adapter in `apps/server/src/adapters/`: indexers (Prowlarr, Jackett, any Torznab/Newznab endpoint), torrent clients (qBittorrent, Transmission), and metadata providers (TPDB, StashDB). Services consume **contract interfaces** — `SearchProvider` and `TorrentClient` from `adapters/contracts/` — never concrete classes. Connections are data, not code: each `service_connections` row (type, provider, url, credentials, priority) builds an adapter instance, so adding a provider is a factory case, not a refactor.

## BaseAdapter and construction

All adapters extend `BaseAdapter` (`base-adapter.ts`), which implements the `ServiceAdapter` shape — readonly `type`, `provider`, `connection`, and `healthCheck(): Promise<{success, message, responseTimeMs?}>`:

- `fetch(path)` merges default headers with a 30 s `AbortSignal.timeout`; `fetchWithRetry` defaults to **3 retries, 2 s base delay, 60 s per-attempt timeout**, retrying HTTP 5xx/429 and network errors with exponential backoff (`baseDelay × 2^(attempt−1)`). This 429-aware backoff is the built-in rate-limit handling; call sites override the budget (Prowlarr search 180 s, TPDB JAV pagination 60 s).
- Default headers send `Authorization: Bearer <apiKey>`; each adapter overrides per protocol. `performHealthCheck` wraps any failure into a result object — a connection test never throws.

`adapter-factory.ts` normalizes provider aliases (`qbit`/`qbits`, `transmission-daemon`, `the porn db`, `stash-db`, …) and type spelling (`-` → `_`), then dispatches: `torrent_client` → qBittorrent/Transmission, `indexer` → Prowlarr or the Torznab family, `metadata_provider` → TPDB/StashDB; unknown combinations return `null`. `createAdaptersFromConnections` sorts active connections by **priority ascending (1 = primary)** and takes the first match per provider — one qBittorrent, one Transmission, one TPDB, one StashDB — while **every** indexer lands in the neutral `indexerAdapters[]` fan-out list (Prowlarr instances also in the legacy `prowlarrAdapters[]`). `createAdapter` builds a throwaway instance for pre-save connection tests.

The `AdapterProvider` registry holds kinded lists (`indexer → SearchProvider`, `torrent_client → TorrentClient`, `metadata_provider → TPDBAdapter | StashDBAdapter`) with generic `getActive(kind)`/`getPrimary(kind)`, the single-active `torrentClient` getter, priority-ordered TPDB/StashDB accessors, `getPrimaryProwlarrAdapter()` for GUID proxy downloads, and `getAllowedHostnames()` feeding the SSRF guard. Whenever connections change, `refreshAdapters` rebuilds everything and re-registers the five adapter values in Awilix — services resolve adapters **at call time**, so edits apply without a restart.

## The SearchProvider contract

```ts
export type NormalizedSearchResult = ProwlarrSearchResult; // wire-shape alias

export interface SearchOptions {
  categories?: number[];
  limit?: number;
  indexerIds?: number[];
}

export interface SearchProvider extends ServiceAdapter {
  search(query: string, options?: SearchOptions): Promise<NormalizedSearchResult[]>;
}
```

`NormalizedSearchResult` is the only shape search consumers rely on (title, guid, indexer identity, size, seeders/leechers, infoHash, magnet/download links, publishDate); Torznab XML items map into it, and Torznab `<category>` values are intentionally not carried. Options map per protocol: Prowlarr gets `categories`/`limit`/`indexerIds` (server-side scoping to a subset of its managed indexers); Torznab gets `cat`/`limit` and **ignores `indexerIds`** — the endpoint *is* the feed, so scoping means skipping the adapter at the fan-out site. Implementations **must throw on hard failures** so per-adapter isolation distinguishes a failed indexer from an empty result. Fan-out runs in parallel (`Promise.all`) in discovery and the subscription orchestrator, with per-indexer failures non-fatal; `search_delay_ms` (default 5000) paces between subscription searches.

### Indexer adapters

| | ProwlarrAdapter | TorznabAdapter |
|---|---|---|
| Providers | `prowlarr` | `jackett`, `torznab`, `newznab` (one class) |
| Auth | `X-Api-Key` header | `apikey` query parameter |
| Search | `GET /api/v1/search`; array params **repeated**, never comma-joined (ASP.NET binding 400s); 3 retries / 3 s base / 180 s timeout | `GET {endpoint}?t=search&q=…`; RSS XML via `fast-xml-parser` (`XMLValidator` first — malformed XML → warn + empty result); 2 attempts / 180 s timeout |
| Mapping | Zod-validated `ProwlarrSearchResultSchema` | Handles scalar elements **and** `torznab:attr` (Jackett); seeders precedence attr → element → `peers`; magnet/http split; items Zod-validated, invalid dropped |
| Extras | `getIndexers()` enabled `{id,name}` refs, 10-min instance cache; failures return `[]` **without** caching | Bare-origin Jackett URLs get `/jackett/api/v2.0/indexers/all/results/torznab/api` appended |
| Health | `/api/v1/system/status` | `t=caps` (15 s) |

Secrets never reach logs — query-string `apikey` values are redacted.

## The TorrentClient contract

`contracts/torrent-client.ts` defines the capability vocabulary and the consumed client surface. Capabilities are declared honestly — only what the protocol genuinely provides:

| Capability | Meaning | qBittorrent | Transmission |
|------------|---------|-------------|--------------|
| `category` | Server-side category on add | ✓ | — |
| `sequential` | Sequential piece order | ✓ | — |
| `first-last-piece` | First/last piece priority | ✓ | — |
| `piece-map` | Per-piece download state | ✓ | — |

qBittorrent declares the **full set**; Transmission declares an **empty set**. The method surface: `addTorrent({magnetUri?, torrentUrl?, torrentData?, savePath?, category?, tags?, firstLastPiecePrio?})`, `getTorrents()` (neutral `TorrentSummary`), `pauseTorrent`/`resumeTorrent`, `recheckTorrent`, `deleteTorrent(hash, deleteFiles?)`, `setTorrentLocation`, `getTorrentFiles`, `getPieceStates`, `getTorrentProperties`, `getTorrentFilesDetailed`, `setFilePriority({hash, fileIds, priority})`. Shared DTOs: `TorrentProperties` (pieceSize/piecesNum/totalSize/savePath) and `DetailedTorrentFile` whose `pieceRange` comes **from the client's piece-range data, never computed from pieceSize**. Global speed-limit setters are deliberately absent — download-phase policy belongs to Zephyrus; qBittorrent-only extras (`authenticate`, `getTransferInfo`, `toggleFirstLastPiecePrio`) stay off the contract.

### Torrent client adapters

**QBittorrentAdapter** (WebUI API v2) is the reference implementation: username/password login yields a sticky `SID` cookie (shared `authPromise` dedupes concurrent logins; 403/401 triggers re-auth retry). `addTorrent` posts FormData and treats a `'fails.'` body as failure. Pause/resume call the modern `stop`/`start` endpoints first, falling back to legacy `pause`/`resume` **only** on 404/"Endpoint does not exist" (qBittorrent 5.x/4.x compatibility). Piece states, per-file `piece_range`, properties, and file priorities are all native; health check hits `/api/v2/app/version`; requests time out at 30 s.

**TransmissionAdapter** (RPC `POST {url}/transmission/rpc`, bare origins get the path appended) was added with **zero service/job edits** — the contract's proof. HTTP Basic auth plus the 409 `X-Transmission-Session-Id` handshake (acquire, retry once); non-`success` RPC results throw. `addTorrent` sends `filename` (magnet/URL) or base64 `metainfo`; `torrent-duplicate` counts as success; category/tags/firstLastPiecePrio are ignored with a debug log. RPC statuses map to qBit-style states; `torrent-remove` carries `delete-local-data`, `torrent-set-location` uses `move:true`, file priorities map to `files-unwanted`/wanted. Crucially, `getPieceStates` and `getTorrentFilesDetailed` return **`[]`**: Transmission's RPC has no piece map, and offset-derived approximations are forbidden — they would corrupt OSHASH, the core identity invariant. Megapack early-dedup no-ops cleanly on the empty arrays, and the singles early-hash pass gates explicitly on `piece-map`. `getTorrentProperties` is truthfully implemented via `torrent-get`; health check is `session-get`.

## Metadata adapters

**TPDBAdapter** (The Porn Database REST API, Bearer auth): scene/performer/site search and detail (numeric ids normalized to strings), performer filmography and JAV scene pagination bounded by a short-page end condition and a `MAX_PAGINATION_PAGES = 50` cap with a truncation warning. `findByHash(hash, OSHASH|PHASH)` returns `null` **only** on 404/empty payload — network/HTTP errors propagate so enrichment can set `providerErrored` instead of treating an outage as a no-match. `submitHash`/`bulkSubmitHashes` (hash contribution) use `fetchWithRetry`. Health check: `/sites`.

**StashDBAdapter** (StashDB GraphQL, stash-box schema, `ApiKey` header): `graphqlUrl` strips a trailing `/graphql` so both origin and full-endpoint URLs work. Every POST carries a 30 s timeout. `findScenesByFingerprints` wraps inputs in the nested `[[FingerprintQueryInput!]!]!` shape and flattens the result; errors propagate (same outage semantics as TPDB). `submitFingerprint` returns a boolean and is non-fatal; `queryExistingScene` is a lenient sibling probe. The health check runs `queryScenes(per_page:1){count}` — deliberately **no introspection fallback**, since anonymous introspection masked bad keys. Studio detail has no `description` field (schema-invalid on stashdb.org).

Query pattern: enrichment walks TPDB adapters by priority, then StashDB adapters, **sequentially** — each record is fetched in full and verified before the next call (see [Enrichment Pipeline](./enrichment-pipeline)). Performer/studio discovery search likewise queries TPDB then StashDB with per-provider non-fatal catches, normalizing both into `UnifiedPerformer`/`UnifiedStudio`. There is no client-side rate limiter beyond the shared retry/backoff and the subscription search pacing.

## Unified payload schemas

`packages/shared-types/src/external/` holds the inbound-wire Zod schemas. Raw provider fields keep native casing (`num_seeds`, `hair_colour`, `added_on`); adapters `safeParse` responses **before** mapping them into internal DTOs or database rows:

- `ProwlarrSearchResultSchema` / `ProwlarrIndexerSchema` — the latter uses `.catch()` tolerance per field; one strict failure used to invalidate the entire indexer array.
- `QBittorrentTorrentSchema` — `TorrentSummary` is its type alias, so alternative clients map into the same shape.
- `TPDBSceneSchema` / `TPDBSceneHashSchema` and `StashDBSceneSchema` — the `submissions` fields survive parsing into `scene_external_hashes`; they are the evidence weight for identity gates. `FINGERPRINT_ALGORITHM` covers MD5/OSHASH/PHASH.
- `UnifiedPerformerSchema` / `UnifiedStudioSchema` — normalized display fields + `provider` + merged `externalIds`, with opaque `rawData` for the subscribe dialog.
- Service-connection DTOs — `ServiceType` (`torrent_client`/`indexer`/`metadata_provider`), priority 1–99 (lower wins), and the single-active torrent-client rule enforced on update.

## Adding a provider

The extension checklist (from `CONTRIBUTING.md`), using `TransmissionAdapter` and `TorznabAdapter` as references:

1. **Implement the contract** — `TorrentClient` or `SearchProvider` from `adapters/contracts/`, extending `BaseAdapter` for fetch/retry/auth plumbing and `healthCheck()`.
2. **Register in the factory** — add a provider case in `adapter-factory.ts` (both `createAdapter` and `createAdaptersFromConnections` paths). A case, not a refactor.
3. **Test-connection switch** — mirror the case in `service-connection-service.ts` so the Settings "Test" button works.
4. **Settings preset** — add an entry in `apps/web/src/features/settings/components/services/service-presets.ts` (fields, default URL, `NEXT_PUBLIC_…_DEFAULT_URL` override); the add/edit dialogs are preset-driven.
5. **Tests** — adapter unit tests in `apps/server/__tests__/adapters/`: happy path, auth, error paths, mapping behavior (see [Testing](./testing)).
6. **Codemap** — update `apps/server/src/adapters/codemap.md` in the same PR.

> [!IMPORTANT]
> Be honest about capabilities. Declare only what the protocol genuinely provides; features like megapack early-dedup degrade gracefully when a capability is missing. Never approximate data you can't retrieve — piece ranges are not estimated from file offsets, because fingerprint correctness outranks feature coverage.

Services and jobs need **no changes** for a new provider inside an existing kind: they resolve neutral lists from the `AdapterProvider`. See [Architecture](./architecture) for the composition root and [Integration](./integration) for connection setup.
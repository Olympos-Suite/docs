---
title: "Adapters"
description: "The kinded adapter contracts — metadata providers, indexers, torrent clients — and the one-file extension pattern."
section: "Developer Guide"
order: 30
---

Adapters are Psyche's **v1 extension surface**: typed contracts behind a kinded registry, with no plugin runtime (a sandboxed plugin system is explicitly deferred). Every external service integration is an adapter; every configured instance of one is a `service_connections` row passed **per call**, so a single stateless provider serves all instances of its kind.

## The AdapterProvider contract

All adapters implement the same base (`src/types/adapter-contracts.ts`):

```ts
export const ADAPTER_KINDS = ['metadata_provider', 'indexer', 'torrent_client'] as const;

export interface AdapterProvider {
  readonly kind: AdapterKind;
  /** Registry-unique name within the kind, e.g. 'tmdb'. */
  readonly name: string;
}
```

The `AdapterRegistry` stores providers under `kind:name` and resolves them by that pair. Registration happens once at boot in `container.ts`; construction is inert (no network, no credentials needed). The provider vocabulary per kind is pinned in `@repo/shared-types` (`SERVICE_PROVIDERS`): `tmdb` for metadata, `prowlarr`/`torznab` for indexers, `qbittorrent`/`transmission` for clients.

## Kinds and contracts

### `metadata_provider` — MetadataProvider

Search, discovery surfaces (trending/popular/upcoming), series/movie/person details, genres, and image-CDN configuration. Results are **normalized** internal types (series detail carries seasons, localizations, posters/backdrops, and the computed `anime` flag) — API DTOs come from `@repo/shared-types`, never from adapter internals. Single active instance; credentials re-read per call.

### `indexer` — SearchProvider

```ts
search(options: { indexer: IndexerConfig; query: IndexerQuery }): Promise<RawRelease[]>;
testConnection(options: { indexer: IndexerConfig }): Promise<void>;
```

Queries are typed (`tvsearch` with season/episode, bare `search`, `movie`); results normalize to title/size/seeders/infoHash/URLs/categories. `testConnection` is the lightest authenticated reachability probe — the Services tab turns its rejection into a result, not an error envelope. Many instances fan out with priority precedence.

### `torrent_client` — TorrentClient

`addTorrent`, `listTorrents`, `pauseTorrent`, `resumeTorrent`, `removeTorrent` (with `deleteFiles` flag), plus the organizer's file operations: `listFiles`, `setTorrentLocation` (client-side data move), `renameFile` (one file, seeding metadata preserved). Client states normalize to a canonical vocabulary (`downloading`, `queued`, `paused`, `seeding`, `completed`, `checking`, `error`); hashes are uppercase 40-hex.

`AddTorrentInput` carries the grab options: magnet/download URL, category (`'psyche'` or null for label-based clients), `sequentialDownload`, `firstLastPiecePriority`, `seedTimeHours`, and `savePath`. Adapters apply only what their capability entry supports.

## Capabilities and degradation

Capabilities are declared per implementation (`TORRENT_CLIENT_CAPABILITIES`):

| Capability | qbittorrent | transmission |
|------------|-------------|--------------|
| categories | true | false (labels since 4.0) |
| tags | true | — |
| sequential | true | 4.1+ |
| firstLastPiecePrio | true | false |

Features **degrade gracefully** when a client lacks a capability — a Transmission grab simply omits first/last-piece priority instead of failing. The same principle applies to grab options generally: undefined means "leave the client default".

## BaseAdapter

Shared plumbing lives in `base-adapter.ts` / `adapter-network.ts`: headers, auth, retry/backoff, and global fetch (undici) with keep-alive. Rules every adapter inherits:

- **Per-call config re-read** — credentials are never cached inside the adapter.
- **Secrets never logged** — error messages carry paths/status only, never URLs or credentials; the connection-test sanitizer redacts defensively on top.
- **Sanitized failures** — adapter errors arrive as `AppError`s with actionable messages; upstream failures surface as `REQUEST_ERROR` (typically HTTP 502).

## Bundled adapters

| Kind | Name | File |
|------|------|------|
| metadata_provider | `tmdb` | `src/adapters/tmdb/metadata-provider.ts` |
| indexer | `prowlarr` | `src/adapters/prowlarr/prowlarr-adapter.ts` |
| indexer | `torznab` | `src/adapters/torznab/torznab-adapter.ts` |
| torrent_client | `qbittorrent` | `src/adapters/qbittorrent/qbittorrent-adapter.ts` |
| torrent_client | `transmission` | `src/adapters/transmission/transmission-adapter.ts` |

## Adding an adapter

The extension pattern is deliberately small — **one file + one registration + tests, zero service-layer changes**:

1. Write the adapter under `src/adapters/<name>/`, implementing the kind's contract and extending `AdapterProvider` with `kind` + `name`.
2. Add the provider name to the kind's allowlist in `@repo/shared-types` (`SERVICE_PROVIDERS`) so connections can reference it.
3. Register the class in `container.ts` (declaration + the boot registration line).
4. Add tests: contract behavior, capability declaration, and error sanitization (see [Testing](./testing)).

Services resolve adapters through the registry by `kind:name` and iterate `service_connections` rows by type + priority — they never import a concrete adapter. That is what keeps the change surface at one file.
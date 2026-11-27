---
title: "Discovery"
description: "Manual torrent search across every configured indexer, with match-reason indicators, one-click download, and optional performer/studio attribution."
section: "User Guide"
order: 30
---

Discovery is the manual path into Eros: you search the indexers yourself, pick the exact release you want, and download it with one click. It is the counterpart to [subscription automation](./subscriptions) — same download pipeline, same hash-only enrichment, but **you** make the selection instead of the grouping and quality machinery. Single scenes that no subscription covers enter the library this way.

## The Search page

The **Search** page (`/search`) has two tabs, selected with `?tab=`:

| Tab | What it does |
|-----|--------------|
| **Metadata** | Searches TPDB and StashDB for performers and studios. Clicking a card opens the subscribe dialog — the entry point for [subscriptions](./subscriptions). Provider toggle: All / TPDB / StashDB; results split into All / Performers / Studios. |
| **Torrents** | The discovery search described below: ad-hoc torrent queries over your indexers. |

The committed search term lives in the URL (`?q=`), so a search is a link you can bookmark and back/forward restores it. Metadata queries are debounced (450 ms) and fire at 2+ characters; torrent searches run on Enter or the Search button.

## Torrent search

A torrent search (`POST /api/discovery/search`) fans out over **all active indexer adapters in parallel** — Prowlarr, Jackett, and any Torznab/Newznab endpoint configured under [service connections](./configuration). One indexer failing never sinks the search: its error is logged and the other adapters' results still return.

The merged results are **deduplicated by infoHash** (falling back to the indexer GUID), keeping the highest-seeder entry for each hash. Unlike the subscription path, discovery applies **no relevance, word, or quality filters** — you see everything the indexers returned, annotated with reasons (below). Prowlarr sweeps can be slow; the UI allows up to 180 seconds and shows a live elapsed-seconds counter instead of freezing.

Results render as aligned rows — title, indexer badge, size, seeders/leechers, publish date — with client-side sorting (Relevance / Seeders / Size / Newest) and a meta line (`N results · M indexers`).

## Match reasons

Every result carries a `matchReasons` list explaining what automation would think of it. The row shows an indicator with the worst severity and a tooltip listing every message:

| Reason | Severity | Meaning |
|--------|----------|---------|
| `duplicate_infohash` | info | N duplicate results merged into this entry (best-seeder kept). |
| `megapack` | info | Detected as a megapack — downloads as one multi-file pack; per-file scenes are created later. |
| `seeders` | warning | No seeders — a download of this torrent would stall. |
| `spam_filter` | warning | Spam/ad patterns in the title; subscription search deprioritizes these. |
| `spam_indexer` | warning | Indexer is on the spam list; subscription search drops its results. |
| `download_link` | blocked | No resolvable info hash or download URL — the result cannot be downloaded. |
| `queue_check` | blocked | Already in the download queue (links the existing scene when known). |
| `blacklist_check` | blocked | Info hash is blacklisted. |

> [!NOTE]
> The reasons are annotations, not gates: discovery is deliberately unfiltered so you can inspect and override. The add endpoint itself still rejects a hash already in the queue (`409`) and a result whose hash cannot be resolved (`400`).

## Downloading a result

The **Download** button opens a dialog with three decisions:

1. **Scene handling** — `Auto` / `Single scene` / `Megapack`. Auto lets the server decide from the title+size heuristics; the explicit modes override it.
2. **Relate to (optional)** — searchable performer and studio pickers listing your **subscribed** entities only. The choice is stored on the queue row and linked to the scene, so the download is attributed even without a subscription.
3. Confirm — `POST /api/discovery/add-download`.

On submit the server, in order:

1. **Resolves the real infoHash before any write**: the provided hash → the `btih` parsed from the magnet → the hash derived from the download link (a resolved magnet, or the SHA-1 of the fetched `.torrent`'s `info` dictionary). Private/cookie-auth indexers often report no hash; placeholder hashes are never accepted because progress sync matches queue rows to the client by hash. Unresolvable → `400`.
2. **Duplicate pre-check** on the resolved hash — already queued → `409 CONFLICT`, nothing written.
3. Adds the torrent to the client under the `eros` category (`torrent_category`), into a deterministic **per-hash staging folder** under the selected download path.
4. Only after the client accepts: a **single** creates the scene row immediately (status `discovered`, title derived from the torrent name, collision-safe slug) plus the linked queue row (`queued`) in one transaction. A **megapack** creates only the queue row — per-file scenes appear later as the pack's files verify (see [Metadata enrichment](./metadata-enrichment)).
5. Attempts hash-only enrichment right away (non-fatal; failures leave the scene `discovered` for the nightly retry).

The scene is visible in the library immediately, and the download appears on the [Downloads page](./download-management). An existing scene can also be linked to a performer/studio after the fact via `POST /api/discovery/auto-relate` (the Relate section on the scene detail page).

## How it differs from subscriptions

| | Discovery | Subscription search |
|---|-----------|---------------------|
| Trigger | You, on demand | Nightly job + manual "Run now" |
| Selection | You pick the release | Grouping + [quality profile](./quality-profiles) gate |
| Filters | Annotations only | Spam, zero-seeder, relevance, word lists |
| Budget | None | `subscription_search_budget` rotation |
| Attribution | Optional, chosen in the dialog | Automatic from the subscription's entity |
| Queue row | No `subscriptionId` — visible through the scene | Tagged `subscription:<id>` in the client |

Both paths share hash resolution, queue dedup, staging folders, the same [download lifecycle](./download-management), and the same hash-only enrichment — a manual download is a first-class library citizen, not a second-class import.

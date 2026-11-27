---
title: "Torrent Grouping"
description: "Clustering indexer results into torrent groups: exact and fuzzy matching phases, the minimum-member gate, durable member history, and group-fallback retries."
section: "User Guide"
order: 60
---

Indexer results for one subscription are noisy: the same scene appears under different titles, qualities, and release groups across dozens of indexers. **Torrent grouping** clusters those results into `TorrentGroup`s — one group per distinct content — so Eros downloads the single best member instead of ten copies, and keeps the siblings on record as alternatives if the download fails. Grouping runs inside the [subscription search](./subscriptions); manual [discovery](./discovery) downloads skip it.

## Member preparation

Every result becomes a group member through the same cleaning chain:

1. **Spam cleanup** — URLs, streaming-site ads, and Telegram invites are stripped from the title (`cleanSpamFromTitle`); the original is kept and flagged `isSpammy` for later penalization.
2. **Title parsing** — quality, source, date, performer/studio names, and scene code are extracted from the cleaned title.
3. **Core title** — `extractCoreTitle` strips URLs, bracketed tags, codecs, and the subscription's relevance names, leaving the bare content title used for comparison.
4. **Scene code extraction** — patterns like `SEXART-1234`, `ABC-20240109`, or `NFB-2026-01-09`.

A member whose core title ends up empty is treated as a singleton and never grouped.

## Phase 1 — exact matching

Fast and synchronous. Members are clustered by:

| Key | Rule |
|-----|------|
| Scene code | `scene:<UPPERCASED CODE>` — the strongest key; code-bearing releases group together regardless of title wording. |
| Core title | Exact lowercase match against an existing group's key or any member's core title. |
| Date conflict | Two members with **different parsed dates can never share a group** — a hard rejection, even when titles match. |

Members that find no exact match seed their own singleton group and move to phase 2.

## Phase 2 — fuzzy matching

Unmatched members are scored against existing groups in one batched pass:

1. **Jaccard pre-filter** — pairs below **0.15** token similarity never reach the model.
2. **Cross-encoder** — a small local model (`cross_encoder_model`, default `Xenova/ms-marco-MiniLM-L-6-v2`, run via transformers.js) reads the two core titles together, enriched with site-source and date context, and outputs a similarity score. No external service is involved.
3. **Threshold** — `cross_encoder_threshold` (seeded at **0.80** on a fresh install; the engine's built-in fallback is 0.50). When both members carry the **same parsed date**, the threshold relaxes to **×0.85**.
4. **Word-overlap penalty** — protection against false merges of titles that share only a performer name: overlap < 0.30 multiplies the score by 0.5, < 0.50 by 0.7, < 0.65 by 0.9, otherwise no penalty.
5. Each member joins its highest-scoring acceptable group (leaving its phase-1 singleton); members with no acceptable match stay singletons. Pathological result sets are capped at the 2000 highest-pre-filter pairs per call.

With `matching_method` set to `text`/`jaccard`, phase 2 uses plain Jaccard similarity against `text_similarity_threshold` (0.40) instead of the model. With `llm`, grouping is skipped entirely — the LLM picks one torrent, wrapped in a synthetic group (see [Subscriptions](./subscriptions)).

## Group acceptance

Groups below `torrent_group_min_members` (default **2**, floor 2 — smaller values are clamped) are dropped: a lone release is not enough evidence of consensus. Surviving groups are sorted by member count descending, and each gets a pre-selected `bestTorrent` (spam-free > resolution score > seeders > size). This grouping-stage ranking is provisional — the [quality gate](./quality-profiles) re-ranks the members matching the winning preference before anything downloads.

> [!NOTE]
> **Synthetic groups** — the single-torrent wrappers produced by the LLM and JAV code paths — carry `memberCount: 1` but bypass the min-member gate, since those paths never call grouping.

Acceptance is not download: the group still passes the [quality gate](./quality-profiles), duplicate guards, and blacklist before the client add. The scene is created only after the torrent is accepted by the client.

## Durable member history

When a group is accepted, **every member** is persisted to `torrent_group_members` with its trial state, and the chosen member's trial opens as `trying` — in the same transaction as the scene. This history is durable where the download queue is not: queue rows are pruned after ~7 days (`cleanup_days`), but groups with a scene are never auto-cleaned. It powers two guards:

- **Historical duplicate check** — a later search result matching a stored member's infoHash **or exact lowercase title** is skipped as already owned, but only while the group's scene still exists. Deleting the scene legitimately frees the content for re-download.
- **Quality upgrades** — an already-owned hit can instead be accepted as a higher-quality replacement when `upgrade_scene_quality` is on (see [Quality profiles](./quality-profiles)).

## Group fallback

A failed download is not the end of the road: the **torrent-health** job (every 30 minutes) runs the group-fallback sweep, giving the group's sibling releases a second chance. Toggle: `group_fallback_enabled` (default on).

1. The failed member's trial closes (`trying → failed`); siblings whose queue rows already finished flip to `succeeded`.
2. Remaining candidates are the **never-tried** members with a hash, minus blacklisted hashes/names and hashes already queued.
3. The next candidate passes the **same quality gate** as accept time — no profile or no matching preference means nothing downloads. Selection prefers indexers that have not already failed for this group (a soft tiebreak, never an exclusion).
4. The trial is claimed before the client add; the download link is resolved fresh; at most **3 client-add attempts** per group per sweep. A failed add marks that member failed and tries the next.

When no untried candidate remains — or none matches the profile — the group is marked `exhausted` and the subscription carries a visible notice ("All N candidate releases failed" / "No remaining candidate matched the quality preferences (K untried)"), cleared on the next successful accept.

> [!IMPORTANT]
> Fallback failures are **group-scoped**: a failed member's hash is recorded on its trial row but **not globally blacklisted** — fresh search results may offer it again. Megapacks are exempt from fallback entirely.

## Megapack awareness

Megapacks never enter grouping: the [first pass](./subscriptions) admits them whole, and their contents are handled **per file while downloading** — the early-dedup job maps each video file's piece range, computes an early OSHASH as soon as the first and last pieces land, de-prioritizes duplicate files in the client, and creates each file's scene lazily. The full per-file flow lives in [Metadata enrichment](./metadata-enrichment).

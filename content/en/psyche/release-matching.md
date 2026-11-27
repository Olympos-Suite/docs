---
title: "Release Matching"
description: "The quality-gated matching pipeline: TV-aware queries, anime detection, title similarity, score-once semantics, and dedup."
section: "User Guide"
order: 60
---

Release matching turns a wanted request into a grab decision. Every release is parsed, filtered, and **scored exactly once** against the subscription's quality profile; the score and quality tag are then copied verbatim into the download queue and never recomputed. That is what prevents grab/import drift and upgrade loops by construction.

## The pipeline

```text
release request (episode / season pack / movie)
  → normalized indexer queries (from TMDB metadata, not file names)
  → fan-out over active indexers (priority order, staggered)
  → spam / zero-seeder filters
  → infoHash dedup (highest-seeder instance wins)
  → title-similarity gate (text or cross-encoder)
  → quality-profile scoring (first matching preference wins)
  → auto-grab candidates only; grab persists the score verbatim
```

Manual search (`POST /api/search`, the Wanted view's dialog) runs the same pipeline and returns scored results for you to choose from. Automation grabs only releases that matched a preference.

## Query normalization

Queries are built from **cached metadata**, so identity never depends on release naming:

| Request type | Queries sent |
|--------------|--------------|
| Episode | One `tvsearch` (title + season/episode params). Anime-flagged series with a known absolute number **also** get a bare-term `search` (`"<title> <absolute>"`) in the same pass. |
| Season pack | One `tvsearch` (title + season, no episode). Packs are seasonal by definition — no absolute-number variant. |
| Movie | One movie query: `"<title> <year>"` (year from the release date). |

The searchable title prefers the **original title when it is non-empty ASCII** (indexers list international releases under original titles), otherwise the localized title.

## Anime detection

TMDB has no first-class "anime" type, so Psyche detects it with a heuristic at import time:

> **Animation genre (id 16) AND (Japanese original language OR JP origin country)** → the series gets its `anime` flag.

The flag has two effects: episode queries gain the absolute-numbering variant (above), and the organizer can resolve pack files numbered absolutely against `episodes.absolute_number`. Both numbering schemes — `S01E01` and absolute — are accepted in a single matching pass; you never choose one or the other.

## Title similarity

Before quality scoring, candidate titles must resemble the target. Two methods, configured under **Settings → Matching** ([reference](./configuration#matching)):

| Method | Metric | Threshold setting | Default |
|--------|--------|-------------------|---------|
| `text` | Jaccard token similarity | `matching.textSimilarityThreshold` (0.1–0.8) | 0.4 |
| `cross-encoder` | transformers.js cross-encoder logits → sigmoid | `matching.crossEncoderThreshold` (0.2–0.9) | 0.5 |

In plain terms, the cross-encoder is a small local model that reads the two titles together and outputs a similarity score (0–1); the threshold is the minimum score to accept a match, and `text` is the lightweight alternative that needs no model.

The default method is `cross-encoder` with the bundled `Xenova/MiniLM-L6-v2` model (a `…L12-v2` variant and a `custom` model id are available). Models are cached under `/data` after first use. There is no LLM-based method.

## Scoring

For a release that passes the similarity gate, preferences are tried in ascending priority order. The score is deterministic:

```text
total = 1000 − 100 × preferenceIndex + min(200, seeders) + 50
```

- `preferenceIndex` — position of the matched preference in the priority-sorted list; earlier rungs score higher.
- Seeder bonus is capped at 200; unknown seeders contribute 0.
- The +50 term holds because a matched release satisfies `maxSizeGB` by construction.

No matching preference (or no profile) → `{ tierIndex: null, total: 0 }`: the release is **not** an auto-grab candidate. The matched index and score travel with the release into the queue (`score_total`, `quality_tag`) and are never recomputed downstream — the organizer links files without re-scoring.

## The quality gate

The gate is the matching rule itself, applied per preference:

- quality and source agree — `any` wildcards on either side, source aliases normalized (`web` → `webdl`/`webrip`, remux → bluray family);
- seeders ≥ `minSeeders` — null/negative seeders count as unknown and **pass**;
- size ≤ `maxSizeGB` — a hard bound, no soft penalties.

A release matching no preference is excluded and the reason is logged and surfaced on the wanted request. To let more releases through, edit the profile (add a rung, relax a bound) — see [Quality profiles](./quality-profiles#profile-structure). A subscription with no profile at all is blocked before any indexer call.

## Dedup

Three layers keep the same release from being grabbed twice:

1. **Request dedup** — one release request per `(subscription, type, season, episode)`; "not applicable" components use the sentinel `-1` because SQLite treats NULLs as distinct in unique indexes. Details in [Database](./database#the-sentinel).
2. **infoHash dedup** — within a search fan-out, duplicate hashes collapse to the highest-seeder instance; `download_queue.infoHash` is UNIQUE, so a hash already in the queue is rejected at grab (`409 CONFLICT`).
3. **Blacklist** — permanently banned hashes (failed downloads, auto-removed stalled torrents) are rejected at grab and never resurface in search results. Recovery is a *different* release via the subscription search — never a retry of the banned one. See [Download management](./download-management#failure-handling-and-the-blacklist).
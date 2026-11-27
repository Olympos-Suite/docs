---
title: "Subscriptions"
description: "Performer and studio subscriptions: nightly budgeted search, query generation and raw filters, the JAV code layer, indexer learning, and the settings control center."
section: "User Guide"
order: 40
---

A subscription is Eros's standing instruction to keep collecting an entity's releases. There are exactly two kinds — **performer** and **studio** — and a subscription always targets one entity, **never a single scene**. One subscription per entity; subscribing an already-subscribed entity is a `409 CONFLICT`. Individual scenes you want once are grabbed through [Discovery](./discovery) instead.

## Subscribing

Subscriptions are created from the **Metadata** tab of the [Search page](./discovery): find the performer/studio on TPDB or StashDB, click the card, confirm in the subscribe dialog. The entity is found-or-created locally first, then the subscription is attached (`POST /api/subscriptions`). The dialog's options:

| Option | Default | Effect |
|--------|---------|--------|
| Quality profile | the default profile, preselected | **Required** — a subscription cannot be created without one, and it can never be cleared later. See [Quality profiles](./quality-profiles). |
| Search aliases | on | Also match the entity's alias names in result titles. |
| Include megapacks | off | Opt into the one-shot [megapack first pass](#the-megapack-first-pass). |
| Include compilations | off | Allow JAV compilation/omnibus releases (best-of packs, ≥ 240 min). |
| Include / exclude words | empty | Per-subscription title word filters (below). |

Creating a performer subscription also resets that performer's stale `searched`/`failed` JAV codes to `pending`, so a re-subscribe starts searching immediately instead of sitting out the retry window. There is no search-at-creation: the first search happens on the next scheduled run, where never-searched subscriptions go first.

## The nightly search

The **subscription-search** job runs daily at 00:00 (`subscription_search_cron`). Each run makes three decisions once, up front:

- **Budgeted rotation** — `subscription_search_budget` (default **5**, `0` = unlimited) caps how many subscriptions get a name search per run. Ordering is bucketed: never-searched subscriptions first (newest `createdAt` first, so a fresh subscription is searched on the very next run), then previously-searched ones by oldest `lastSearchedAt` (fair LRU rotation). The rest are deferred to later runs; selected/deferred counts are logged.
- **JAV sweep gate** — while any active subscription has never been searched, the JAV code layer is locked for the whole run: name searches warm the infrastructure first.
- **Global JAV code budget** — `jav_codes_per_run` (default **30**, `0` = unlimited) is shared across all subscriptions in the run: each gets a fair share (at least 1) of what remains, and subscriptions that spend less roll their remainder down to the next ones.

A manual **Run now** (`POST /api/jobs/subscription-search/trigger`) bypasses the budget, the sweep gate, and the JAV retry window — every subscription and every retryable code is searched. The code budget still applies (raise it for a big manual sweep). Between subscriptions the run waits `search_delay_ms` (default 5000 ms) to respect indexer rate limits.

## Queries and raw filters

The Prowlarr query is the entity's **canonical name only** — `performers.name`, or the studio name cleaned of TPDB decoration (`FansDB: Zanewalker (onlyfans)` searches as `Zanewalker`). Aliases never enter the query; they join the **relevance name list** used for filtering (unless `searchAliases` is off).

All active indexer adapters are queried in parallel and the results merged, deduplicated by infoHash (GUID, then title+indexer as fallbacks), keeping the highest-seeder entry. Indexers with an active [mute](#indexer-learning-and-muting) are skipped; if all are muted the name query returns empty. Then, in order:

| # | Filter | Rule |
|---|--------|------|
| 1 | Spam indexers | Results from the spam list (e.g. `Sexy-Pics`) are dropped outright. |
| 2 | Spam titles | Flagged, **not** dropped — penalized at selection, cleaned during grouping. |
| 3 | Zero seeders | Dropped from the regular path. (The JAV layer sees them first and keeps magnet/hash-bearing ones.) |
| 4 | Relevance | Title must contain at least one relevance name — normalized substring match (lowercase, alphanumeric-only), so `HotGuysFuck.24.03.15…` matches `Hot Guys Fuck`. |
| 5 | Word lists | `includeWords`: keep only titles containing ≥ 1 word. `excludeWords`: drop titles containing any word. Applied before the megapack phase, so packs obey them too. |

## The megapack first pass

When `includeMegapacks` is on and the one-shot `megapackProcessed` flag is unset, the run filters results to **megapacks only** (title signals like `megapack`/`siterip`/`NN videos`, or `pack`/`collection`/`complete` above 5 GB). Candidates must name the subscription's entity in the pack title, and must be fresh — not queued, not in the durable member history, not in `megapack_history`, not an exact normalized-title repeat of an earlier pack. Fresh candidates are added best-seeder-first, up to `max_megapacks_per_run` (default **3**, `0` = unlimited); the rest continue on later runs.

Quality preferences are **intentionally not applied** to packs. Once nothing fresh remains or every fresh candidate was attempted with ≥ 1 pack added, the subscription flips to `megapackProcessed: true, includeMegapacks: false`. If a pack was added, the run skips regular grouping (the pack covers the singles); if none was added, grouping proceeds normally. Re-enabling the toggle re-arms the phase. Per-file handling while the pack downloads is covered in [Metadata enrichment](./metadata-enrichment).

## Matching branches

The `matching_method` setting (default `cross-encoder`) picks how candidates become downloads:

| Method | Behavior |
|--------|----------|
| `cross-encoder` | Full [torrent grouping](./torrent-grouping): exact + fuzzy clustering, min-member gate, best member per group. |
| `text` / `jaccard` | Same grouping flow, Jaccard similarity with `text_similarity_threshold` (0.40) instead of the model. |
| `llm` | Grouping is skipped. The candidate list (title/seeders/size/quality/indexer) goes to an LLM, which picks one torrent; it enters the pipeline as a synthetic single-member group. Provider: `llm_provider` (`ollama` default, `openai`, `gemini`); external calls time out after 15 s; the JSON answer carries `best_index` + `confidence` + `reason`. On failure the first result is used. |

Every accepted group then runs the same gauntlet: [quality gate](./quality-profiles) → durable historical-duplicate check (with optional [quality upgrade](./download-management)) → blacklist (hash **and** name) → queue dedup → download path selection → link resolution → client add → scene + group creation → queue row → enrichment. The scene is created only **after** the client accepts the torrent, so a failed add never leaves an orphan scene.

## JAV scene-code search

An extra layer for **performer subscriptions with a TPDB id**, running alongside the name search — before relevance filtering, and even when the name query fails or returns nothing. JAV releases are titled by scene code, not performer name, so the name path alone cannot find them.

1. The performer's JAV scenes are fetched from TPDB (cached 24 h via `javScenesCheckedAt`) and their codes stored in `jav_scene_codes`. Compilation entries (title heuristic or duration ≥ 240 min) are stored `skipped` unless `includeCompilations` is on.
2. **Harvest**: name-query results whose titles carry a pending code are accepted directly through the same gates — no extra query spent.
3. Remaining codes are searched in batches of **3 parallel** queries, pausing `max(2000 ms, search_delay_ms)` between batches. A result is accepted only if the searched code appears in its normalized title; zero-seeder results survive when they carry a magnet/hash; megapacks and (by default) compilations are rejected. The best result enters as a synthetic group through the same accept stack.

Code lifecycle: `pending → searched / downloaded / skipped / failed`. `searched`/`failed` codes re-qualify after `jav_retry_days` (default **30 days**) — the lever that stops hundreds of codes being re-queried every night. Manual runs bypass the window; `downloaded`/`skipped` never re-open. A code already downloaded for the performer blocks duplicate adds from either path.

## Indexer learning and muting

Every indexer query — name **and** JAV — feeds a persistent per-indexer record in the `indexer_stats` settings key (versioned JSON: query/hit counts, zero and error streaks, mute state):

| Rule | Threshold | Mute | Applies to |
|------|-----------|------|------------|
| Consecutive errors | `indexer_error_threshold` (3) | `indexer_error_mute_hours` (6 h) | name + JAV |
| Consecutive verified zeros | `jav_indexer_zero_threshold` (10) | `jav_indexer_mute_days` (7 d) | JAV only |

Name-search zeros are tracked but **never mute** — a performer name legitimately returns nothing on many indexers. JAV accounting uses verified hits: only results that pass the code-in-title gate count as hits; junk output counts as a real miss. Muted indexers are skipped in both query kinds (logged once per run). If every indexer is muted, name queries return empty while JAV falls back to an unscoped safety-valve search.

## The settings control center

On performer and studio detail pages, one **Subscription settings card** holds everything:

- **Header**: status pill (Active/Paused), **Pause/Resume** button, and a menu with *Enrich Scenes*, *Copy External IDs*, *Clear Blacklist*, and *Unsubscribe*.
- **Selects**: quality profile (required — clearing is blocked) and download path (Auto or a specific configured path).
- **Toggles**: Aliases / Megapacks / Compilations — saved immediately.
- **Word filters**: include/exclude word chips with a dirty-gated **Save changes** button.

List cards offer the same settings in a quick-edit dialog. **Pause** excludes the subscription from scheduled searches; downloads already in flight continue. When [group fallback](./torrent-grouping) runs dry, the subscription shows an exhaustion notice ("All N candidate releases failed" / "No remaining candidate matched the quality preferences"), cleared on the next successful accept.

## Unsubscribing and re-subscribing

Unsubscribe offers two outcomes — delete the subscription's scenes or keep them — with dependency-aware rules (a scene another subscription still needs is never touched). The subscription's blacklist entries are cleared either way. Re-subscribing the same entity reuses its row: scenes kept at unsubscribe come back, old bans no longer apply, and stale JAV codes reset to pending. The full matrix lives in [Deletion semantics](./deletion-semantics).

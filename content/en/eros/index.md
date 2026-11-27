---
title: "Introduction"
description: "Eros is Olymposuite's adult scene collection manager — fingerprint-based metadata matching against TPDB and StashDB, torrent grouping, and hands-off library organization."
order: 0
---

Eros is Olymposuite's **adult scene collection manager**. It automates torrent discovery through multi-indexer search, matches files to scene metadata using fingerprints (OSHash/pHash) against TPDB and StashDB — trusting the bytes, not the title — and organizes the library hands-off with subscriptions, file organization, and seed retention.

The defining rule is **metadata is the result of a download, not its precondition**. Classic scene tools match releases by parsing titles and exact dates; scene release names are inconsistent, repackaged, and rarely carry clean dates, so strict matching finds torrents but cannot grab them. Eros inverts the bet: grab first, then identify the file by its hashes. Title/date-based matching is removed entirely — the only authoritative evidence is a file fingerprint verified against community submissions.

The whole pipeline in one line:

```text
subscription → indexer search → filters → torrent grouping → quality gate
  → grab → scene created → hash-only enrichment → download → seed (72 h)
  → remove torrent (keep files) → organize folders to template
```

Eros is one app in the [Olymposuite](../) family and works fully standalone. Its only suite contract is group naming: grabs land in the torrent client under the `eros` category (the `torrent_category` setting) tagged `subscription:<id>`, where an optional [Zephyrus](../zephyrus/) instance can adopt them for download-phase policy (speed limits, auto-pause/resume). No app calls another.

## Philosophy

- **Trust the bytes, not the title.** Enrichment is hash-only: OSHash/pHash evidence looked up against TPDB and StashDB, gated on community submissions (≥ 2) and a ±60 s duration check. No title guessing, no wrong-metadata bleed.
- **Torrent grouping.** Results from all indexers are clustered into groups of the same content — exact scene-code/core-title matching first, then fuzzy cross-encoder matching (optional LLM selection) catches what exact matching misses.
- **Megapack aware.** Per-file piece-level fingerprint checks run while packs are still downloading: duplicates are de-prioritized before they waste disk, and scenes appear progressively as each file is verified.
- **Full lifecycle, automatically.** Download → enrich → seed for N hours → remove the torrent but keep the files → organize folders to your template. Hash-duplicate scenes are deleted with their files; scenes without evidence are marked `unmapped` and retried nightly.
- **Download-phase policy is external.** Stall measurement and group-fallback retries live in Eros; speed schedules and auto-pause/resume belong to Zephyrus and have no settings here.
- **SQLite is permanent.** One database file under `/config` holds the entire state — the only volume you need to back up.

## Features

- **Subscriptions** — follow performers and studios; nightly budgeted search with quality preference lists, include/exclude word filters, alias/megapack/compilation toggles, and a JAV scene-code search layer.
- **Discovery** — manual indexer search with one-click download, match-reason indicators, and optional performer/studio attribution at download time.
- **Multi-indexer search** — Prowlarr, Jackett, and Torznab/Newznab endpoints, queried in parallel, merged and deduplicated by infohash, with per-indexer error learning and muting.
- **Download clients** — qBittorrent and Transmission behind one client contract; one active client at a time.
- **Metadata providers** — TPDB and StashDB queried in priority order (TPDB first, then StashDB); sibling records detected across providers by hash intersection and deleted with their files.
- **Quality profiles** — four seeded preference profiles (quality × source × seeders × size); optional quality-upgrade replacement of existing scenes.
- **File organization** — folder templates (`/{studio}/{title}` …), seed retention, folder-correction sweeps, NFO generation, poster extraction, Jellyfin-friendly output.
- **Operations** — eleven cron-scheduled jobs with UI-editable schedules and run history, disk monitoring with multi-path selection, application logs, and online SQLite backups.
- **API keys** — third-party tools call the REST API via `Authorization: Bearer` or `X-Api-Key`; OpenAPI docs at `/api/docs`.
- **Modern UI** — dark-mode-first dashboard with two selectable dark themes, scene/performer/studio views, hover preview filmstrips, and real-time job progress.

To run Eros you need at least one indexer (Prowlarr, Jackett, or a Torznab/Newznab endpoint) and a torrent client (qBittorrent or Transmission). TPDB and StashDB API keys are optional but recommended — without a metadata provider, scenes download and organize but stay `unmapped`. Everything is configured in the web UI after boot; there is no app config file to edit — Docker's `.env` covers bootstrap only (ports, paths, PUID/PGID).

## User Guide

| Page | What it covers |
|------|----------------|
| [Installation](./installation) | Docker Compose stack, ports and volumes, `/data` → `/config` upgrade, environment variables, first-run setup |
| [Configuration](./configuration) | The settings store, every setting group and default, service connections, job schedules, disk monitoring, backups |
| [Discovery](./discovery) | Manual torrent search, match reasons, the download dialog, metadata search and subscribing |
| [Subscriptions](./subscriptions) | Performer/studio subscriptions, search budgets, word filters, megapacks, pause/resume, unsubscribe outcomes |
| [Quality profiles](./quality-profiles) | Seeded profiles, preference structure, the priority-ordered quality gate, quality upgrades |
| [Torrent grouping](./torrent-grouping) | Exact and fuzzy grouping phases, thresholds, min members, group fallback |
| [Download management](./download-management) | Clients and capabilities, the queue status machine, stalled detection, retries, blacklist |
| [Metadata enrichment](./metadata-enrichment) | Hash-only matching, verification gates, sibling dedup, `unmapped` retries, hash contribution |
| [File organization](./file-organization) | Folder templates, seed retention, the organizer sweeps, NFO and posters |
| [Deletion semantics](./deletion-semantics) | Soft delete vs hard delete, subscription dependency rules, restore, cleanup sweeps |
| [Web UI](./web-ui) | Screen tour: dashboard, search, subscriptions, downloads, jobs, logs, settings |
| [Integration](./integration) | The Zephyrus category contract, indexers, torrent clients, TPDB/StashDB, Jellyfin |
| [Troubleshooting](./troubleshooting) | Setup gate, sessions, degraded modes, logging, common failures |

Developers can continue with the Developer Guide: start with [Architecture](./architecture) for the codebase map, then [Enrichment pipeline](./enrichment-pipeline), [Adapters](./adapters), [API reference](./api-reference), [Database](./database), [Invariants](./invariants), and [Testing](./testing). The invariants page is the binding contract for contributions — read it before changing behavior.
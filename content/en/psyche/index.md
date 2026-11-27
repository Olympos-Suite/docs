---
title: "Introduction"
description: "Psyche is Olymposuite's metadata-first TV and movie library automation app — a Sonarr/Radarr alternative where every entity is TMDB-anchored before any download."
order: 0
---

# Psyche

Psyche is Olymposuite's **TV-series and movie library automation** app — the suite's Sonarr/Radarr slot. You subscribe to series and movies; Psyche finds releases on your indexers, grabs the ones that pass your quality profile, downloads them through your torrent client, and organizes the files into a clean library with NFO and artwork.

The defining rule is **metadata first, download second**. In the classic *arr model, files arrive first and are identified afterwards from release names. Psyche inverts this: every library entity — series, seasons, episodes, movies, people — is anchored to TMDB and created **at subscribe/add time**, before any download exists. Downloads are then matched *against* known entities, never the other way around.

The whole pipeline in one line:

```text
TMDB → library entity → subscription → release requests → indexer search
     → quality gate → grab → download → organize (link, never identify)
```

Psyche is one app in the [Olymposuite](../) family and works fully standalone. Its only suite contract is group naming: grabs land in the torrent client under the `psyche` group, where an optional [Zephyrus](../zephyrus/) instance can adopt them for download-phase policy. No app calls another.

## Philosophy

- **Identity never depends on release naming.** Entities come from TMDB, so scoring cannot drift between grab and import, and there are no upgrade loops or language-fallback failures by construction.
- **The subscription engine diffs TMDB, not indexers.** New seasons and episodes are detected from metadata; indexers are consulted only when there is something to find.
- **Post-download work is organizing, not identification.** The file organizer links files to pre-existing entities — it never creates, re-scores, or re-identifies anything.
- **The quality gate is explicit.** A release that matches no preference in your profile is never auto-grabbed. There is no unlimited "best torrent" fallback.
- **Scope is acquire + organize.** Playback, transcoding, and streaming are permanently out of scope; subtitles belong to dedicated tools.
- **SQLite is permanent.** One file under `/config` holds the entire state — the only volume you need to back up.

## Features

- **Discovery** — TMDB trending/popular/upcoming surfaces, multi-type search, and person filmographies you can browse and add from.
- **Subscriptions** — monitored series with TMDB-status-driven grab policies (season packs for complete seasons, episodes for airing ones) and wanted movie requests.
- **Quality profiles** — ordered preference lists (quality × source × seeders × size) with a single default profile.
- **Release matching** — TV-aware queries including anime absolute numbering, text or cross-encoder title similarity, and score-once semantics.
- **Downloads** — qBittorrent and Transmission behind one contract, a guarded queue status machine, stalled handling, retry backoff, and a permanent blacklist.
- **Organization** — configurable folder templates, canonical file names, NFO + poster sidecars from cached metadata.
- **Operations** — ten background jobs with persisted run history, redacted application logs, and online SQLite backups.

To run Psyche you need a TMDB API key, at least one indexer (Prowlarr or Torznab), and a torrent client (qBittorrent or Transmission). Everything is configured in the web UI after boot — there is no config file to edit.

## User Guide

| Page | What it covers |
|------|----------------|
| [Installation](./installation) | Docker Compose, bare-metal pnpm, environment variables, first-run setup |
| [Configuration](./configuration) | The settings store, all setting groups and defaults, service connections, ports and volumes |
| [Discovery](./discovery) | Discover surfaces, search, person filmographies, adding to the library |
| [Subscriptions](./subscriptions) | Series vs movie subscriptions, grab policies, wanted view, calendar |
| [Quality profiles](./quality-profiles) | Seeded profiles, preference structure, default semantics, assignment and deletion |
| [Release matching](./release-matching) | The quality-gated pipeline, anime detection, similarity settings, dedup |
| [Download management](./download-management) | Clients and capabilities, the queue, stalled handling, backoff and blacklist |
| [File organization](./file-organization) | Folder templates, file naming, NFO and artwork, when organizing runs |
| [Web UI](./web-ui) | Screen tour: library, discover, wanted, queue, calendar, detail pages, settings |
| [Integration](./integration) | The Zephyrus group contract, Prowlarr/Torznab indexers, TMDB as metadata source |
| [Troubleshooting](./troubleshooting) | Degraded modes, boot recovery, sessions, logging, common failures |

Developers can continue with the Developer Guide: start with [Architecture](./architecture) for the codebase map, then [Metadata pipeline](./metadata-pipeline), [Adapters](./adapters), [API reference](./api-reference), [Database](./database), [Invariants](./invariants), and [Testing](./testing). The invariants page is the binding contract for contributions — read it before changing behavior.
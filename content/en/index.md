---
title: "Olymposuite"
description: "A self-hosted media automation suite of Greek-mythology-named apps, one repository per application."
order: 0
---

# Olymposuite

Olymposuite is a self-hosted media automation suite. Each application is a separate repository with its own release cycle and deployment — the Sonarr/Radarr model: install only the apps you need, run them side by side, and let them cooperate through well-defined contracts rather than a shared runtime.

The names come from Greek mythology, and the metaphors are deliberate. Zephyrus is the west wind that carried Psyche to Eros' palace: it moves data without being the hero of the story. Morpheus shapes dreams into new forms: it changes a file's encoding without changing its substance.

## Applications

| App | Role | Default port | Status |
|-----|------|--------------|--------|
| **Zephyrus** | Torrent download-phase policy service: smart queuing, prioritization, weekly bandwidth schedules, stalled-torrent management for one torrent client connection | `9695` | [Documentation live](./zephyrus/) |
| **Eros** | Adult scene collection manager: torrent discovery, fingerprint-based metadata matching, hands-off library organization | `9697` | Coming soon |
| **Psyche** | Metadata-first TV/movie library automation: every library entity is anchored to TMDB metadata before any download starts | `9698` | [Documentation live](./psyche/) |
| **Morpheus** | Media-archive compression: one-way h264 → h265 re-encoding to keep the archive storage-optimal | `9699` | [Documentation live](./morpheus/) |

## How the apps fit together

The suite's integration model is intentionally loose:

- **Eros and Psyche add torrents directly to their own torrent clients.** They do not call Zephyrus, and Zephyrus does not call them. Each app works fully standalone.
- **Zephyrus adopts torrents by group scan.** The keys of its `groups` configuration (for example `eros` and `psyche`) define which torrent groups — qBittorrent categories — it manages. It discovers matching torrents on every poll and applies download-phase policy to them. It never adds or removes torrents and never touches files. Group naming is the only contract between the apps.
- **Morpheus compresses via workers.** A management service hands transcode jobs to headless worker processes that claim work over a long-poll protocol; the archive files themselves are processed in place or on mounted shares.

Because Zephyrus is an optional layer, removing it breaks nothing: torrents simply download, seed, and get removed on each app's own terms.

## Shared stack baseline

All suite apps share one technology baseline: Node.js 24, pnpm, and Turborepo monorepos (`apps/web`, `apps/server`, `packages/*`), with Next.js on the frontend and Fastify 5, Drizzle ORM, and SQLite on the backend, validated with Zod. Every app ships as a multi-stage Docker image that drops privileges via `PUID`/`PGID` and persists state in two volumes: `/config` (database and settings) and `/data` (application data). Zephyrus deviates from this baseline deliberately: it is a single-package pnpm repo (no Turborepo), serves a React + Vite dashboard statically from Fastify instead of running Next.js, and requires Node.js 22 or newer. Its Docker shape (`/config` + `/data`, user drop, healthcheck) follows the suite standard.

## Where to go next

- [Zephyrus documentation](./zephyrus/) — introduction, installation, configuration, and the full User Guide for the download-phase policy service.
- [Psyche documentation](./psyche/) — the metadata-first library automation app: installation, subscriptions, quality profiles, release matching, and the full Developer Guide.
- [Morpheus documentation](./morpheus/) — the archive compression app: installation, rulesets, the seven verification gates, workers, and the full Developer Guide.

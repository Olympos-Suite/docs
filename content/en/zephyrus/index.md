---
title: "Introduction"
description: "Zephyrus is a client-agnostic download-phase policy layer for a single torrent client connection."
order: 0
---

# Zephyrus

Zephyrus is Olymposuite's torrent **download-phase policy service**. It connects to one torrent client (qBittorrent 5.x in v1) and centrally applies four policies to the torrents it manages:

- **Smart queuing** — global and per-group caps on how many torrents are started at once.
- **Prioritization** — deterministic resume order by group weight and torrent age, plus a manual pin for user priority.
- **Weekly schedule** — day/hour windows that switch between unlimited bandwidth, aggregate speed caps, and full pauses.
- **Stalled management** — pausing torrents the client reports as stalled, retrying them with growing backoff, and extra patience for torrents close to completion.

One Zephyrus instance manages exactly **one client connection**. If you run several torrent clients, deploy one instance per client — with Docker Compose this is just another service block.

## Philosophy

Zephyrus is built on a small set of non-negotiable principles:

1. **It is an optional layer.** No suite app depends on Zephyrus. Without it, torrents download, seed, and are removed by their owning app using the client's defaults. Uninstalling Zephyrus — even deleting its database — breaks no critical flow; you only lose the smarter management. On graceful shutdown it resumes every torrent it paused.
2. **The torrent client is the single source of truth.** Zephyrus's SQLite database stores only what the client cannot know: a log of its own actions and policy bookkeeping (pause flags, retry counters, pins). Delete the database and all management state is rebuilt from the client on the next poll.
3. **It never adds or removes torrents.** Pause, resume, reannounce, and per-torrent speed limits are the entire action vocabulary. Removal decisions — seed windows, cleanup — always belong to the owning app. The adapter interface has no `add`, `delete`, `rename`, or `setCategory` methods at all; the ban is enforced by the type system, not by code review.
4. **It never touches files.** No moving, renaming, deleting, folder creation, or file-priority changes. Those are domain operations and belong to the apps.
5. **It has zero domain knowledge.** Zephyrus does not know what a scene, subscription, series, movie, or metadata record is. The only things it understands are: **torrent + group + client state**.
6. **Apps never call Zephyrus.** Eros and Psyche add torrents straight to the client. Zephyrus discovers them by scanning groups ("adoption") and manages them from there. There is no webhook or event channel in v1, in either direction.

## Managed groups

Ownership is expressed entirely through **groups** — the client's category/label mechanism. The keys of the `groups` block in `config.yaml` are the *managed groups*:

```yaml
groups:
  eros:
    max_active_downloads: 4
    weight: 10
  psyche:
    max_active_downloads: 3
    weight: 5
```

Only torrents whose group matches one of these keys are managed. Torrents in any other group — including ones you added by hand — and torrents with no group at all are **untouchable**: Zephyrus never pauses, resumes, or limits them. Remove a group from the configuration and its torrents become unmanaged; any that Zephyrus had paused are resumed and released. See [Integration](./integration) for the full contract.

A second correctness rule runs through everything: Zephyrus only ever resumes torrents **it paused itself** (the write-ahead `pausedByUs` flag). A torrent paused by you or by an app is never touched, under any circumstance.

## User Guide

| Page | What it covers |
|------|----------------|
| [Installation](./installation) | Docker Compose, bare-metal setup, environment variables, qBittorrent prerequisites |
| [Configuration](./configuration) | Complete `config.yaml` reference, `env:` resolution, hot-reload, speed units |
| [Smart queuing](./smart-queuing) | Active-download caps, the started set, the boot adoption sweep, coexistence with qBittorrent's own queue |
| [Prioritization](./prioritization) | Group weight + FIFO resume order, manual pins |
| [Weekly schedule](./weekly-schedule) | Day/hour windows, speed profiles, aggregate bandwidth splitting, midnight-crossing windows |
| [Stalled management](./stalled-management) | Stall detection, backoff retries, give-up, completion bias, slow slot-yielding |
| [Dashboard](./dashboard) | First-run setup, login, and the four dashboard screens |
| [Integration](./integration) | The group-naming contract with Eros/Psyche, ownership lifecycle, safe removal |
| [Troubleshooting](./troubleshooting) | Degraded mode, safe mode, auth warnings, common problems |

Developers can continue with the [Architecture](./architecture), [Policy engine](./policy-engine), [Adapters](./adapters), [API reference](./api-reference), [Database](./database), [Invariants](./invariants), and [Testing](./testing) pages.

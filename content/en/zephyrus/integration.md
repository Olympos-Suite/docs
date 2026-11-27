---
title: "Integration"
description: "The group-naming contract with Eros and Psyche, ownership lifecycle, and why removing Zephyrus is always safe."
section: "User Guide"
order: 8
---

# Integration

Zephyrus integrates with the suite's applications through exactly one contract: **group naming**. There are no API calls between apps and Zephyrus in either direction, and no webhook or event channel in v1 — that is a deliberate design decision, not a missing feature.

## The contract: groups

Eros and Psyche add torrents **directly to their own torrent clients**, assigning each torrent to a category (qBittorrent's group mechanism). Zephyrus manages a torrent if and only if its group is a key of the `groups` block in `config.yaml`:

> [!IMPORTANT]
> Zephyrus manages **only** torrents whose qBittorrent category **exactly matches** a key of `config.groups` — the match is **case-sensitive** (`Eros` does not match `eros`). Torrents in any other category, and torrents with no category at all, are **untouchable by design**: never paused, resumed, or limited.

```yaml
groups:
  eros:      # Eros assigns its torrents to the "eros" category
    max_active_downloads: 4
    weight: 10
  psyche:    # Psyche assigns its torrents to the "psyche" category
    max_active_downloads: 3
    weight: 5
```

That is the entire integration surface. To connect an app to Zephyrus:

1. Configure the app to use a torrent client that a Zephyrus instance watches.
2. Make the app's category name match a managed group key.
3. Nothing else. Zephyrus discovers the torrents on its next poll ("adoption") and applies policy from then on.

The group names themselves are arbitrary — `eros` and `psyche` are the suite convention, but any key works. Each app remains fully functional without Zephyrus.

## Ownership rules

| Torrent | Zephyrus behavior |
|---------|-------------------|
| Group is a key of `config.groups` | **Managed** — all policies apply. |
| Group exists but is not configured | **Untouchable** — never paused, resumed, or limited. |
| No group at all | **Untouchable** — including torrents you added by hand. |
| Paused by the user or an app | **Never resumed**, even if managed — Zephyrus only resumes torrents it paused itself (`pausedByUs`). |

Zephyrus also never assigns or changes groups on the client. Ownership is read-only: it classifies, it never relabels.

## Ownership lifecycle

Group membership is re-evaluated on every poll, so changes take effect within one poll interval:

- **A group is removed from the config** (or a torrent's group is no longer managed): the torrent becomes unmanaged. If Zephyrus had paused it, it is **resumed and released**; any per-torrent speed limits Zephyrus applied are cleared; an `unmanage` entry is written to the action log. The torrent keeps downloading under the client's defaults.
- **A torrent's group changes**: if the new group is managed, the new group's policies apply; if not, the torrent is released as above.
- **A torrent disappears from the client** (the owning app removed it after its seed window): Zephyrus drops its database row and writes an informational note. It never removes torrents itself — removal decisions and execution always belong to the app.

## Zero domain logic

Zephyrus knows only **torrent + group + client state**. It has no concept of:

- metadata, scenes, subscriptions, series, or movies;
- seed counting or seed retention windows;
- removal timing, file organization, renaming, or any file operation.

Those are domain concerns owned by Eros and Psyche. The boundary is structural: the adapter interface exposes only `connect`, `listTorrents`, `pause`, `resume`, and optional `reannounce` / speed-limit methods. There is no `add`, `delete`, `rename`, or `setCategory` in the type at all — the ban is enforced at compile time. Client global settings are likewise never modified; the [weekly schedule](./weekly-schedule) works exclusively through per-torrent limits.

## Removing Zephyrus is safe

Zephyrus is an optional layer, and the exit path is designed:

- **Graceful shutdown** (SIGTERM/SIGINT, `docker stop`): Zephyrus resumes every torrent it paused — best-effort, with a 10-second timeout — clears the per-torrent limits it applied, logs each release, and closes the database.
- **Worst case** (crash, forced kill, client unreachable at shutdown): its paused torrents simply stay paused in the client. No data is lost; resume them manually or restart Zephyrus.
- **Delete the database too**: all management state is rebuilt from the client on the next boot. Unknown paused torrents are treated as not-ours ([safe mode](./troubleshooting)) rather than risk a wrong resume. Pins are lost with the database and fall back to normal management.
- **The apps notice nothing.** They never called Zephyrus; their torrents download, seed, and are removed on their own terms. You lose only the smarter management.

## Multiple clients

One Zephyrus instance manages exactly one client connection. Apps may talk to several clients; to cover them all, deploy one Zephyrus instance per client — separate config, database, and port each. With Docker Compose this is just another service block. New client types (Transmission, Deluge, …) require only a new adapter; the policy engine is client-agnostic (see [Adapters](./adapters)).

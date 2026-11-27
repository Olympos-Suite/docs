---
title: "Smart queuing"
description: "Global and per-group active-download caps, the started set, the boot adoption sweep, and coexistence with qBittorrent's own queue."
section: "User Guide"
order: 3
---

# Smart queuing

Smart queuing caps how many managed torrents are **started** at once, so a large queue downloads in an orderly, prioritized fashion instead of saturating the client with hundreds of half-active torrents.

Two ceilings apply simultaneously:

- [`global.max_active_downloads`](./configuration#global) — total started managed torrents across all groups.
- [`groups.<name>.max_active_downloads`](./configuration#groups) — per-group ceiling (optional; omit for no group cap beyond the global one).

Both caps count the [started set](#the-started-set) defined below.

```yaml
global:
  max_active_downloads: 6
groups:
  eros:
    max_active_downloads: 4
  psyche:
    max_active_downloads: 3
```

With these values, at most 6 managed torrents are started in total, of which at most 4 belong to `eros` and at most 3 to `psyche`.

## The started set

The caps count the **started set**: managed torrents whose canonical client state is one of:

| State | Meaning | Why it counts |
|-------|---------|---------------|
| `downloading` | Actively transferring (qBit `downloading`, `forcedDL`, `metaDL`, `allocating`) | Obviously occupies a slot. |
| `checking` | Recheck or file move in progress (`checking*`, `moving`) | Started and busy; pausing it would be wrong. |
| `queued` | Waiting in **qBittorrent's own internal queue** (`queuedDL`) | Zephyrus started it; qBit just hasn't given it a transfer slot yet. |
| `stalled` | Started, but the client reports no peers/progress (`stalledDL`) | Still started — it holds its slot until the [stalled module](./stalled-management) evicts it via the threshold pause. |

Counting `queued` and `stalled` is what keeps the accounting honest. If `queued` waiters didn't count, the ceiling could never be satisfied and Zephyrus would over-start. If `stalled` torrents didn't count, the natural `stalledDL ↔ downloading` flapping would oscillate the active count, fabricate free slots, and drive pause/resume ping-pong. With both counted, the started set is stable: exactly N started, dead ones evicted after the stall threshold, then the next waiter starts.

**Resume grace window.** A torrent Zephyrus just resumed may still appear `paused` in the client for a poll or two (start propagation gap). Until its start lands, it keeps occupying its slot for a grace window of **2× the poll interval**, anchored at the moment of resume (`queueResumedAt`). This prevents a second resume from overshooting the cap when both starts land.

## Over the cap: pausing

When the started set exceeds a ceiling, Zephyrus pauses the excess with `pausedByUs=true` and reason `queue`:

1. **Per-group violations first** — each over-cap group pauses its own excess.
2. **Then the global violation** — further picks in the same order until the global cap is met.

The pause order is the inverse of resume priority: **lowest group weight first, then newest added first** (the most recently added torrent is the least invested). Ties break deterministically by info hash.

Two guarantees:

- **Pinned torrents are never paused by the caps.** They still *count* toward the active totals (they consume slots), but the ceilings only ever trim unpinned torrents. See [Prioritization](./prioritization).
- **Pauses never enable same-tick resumes.** A slot freed by a pause becomes available at the next evaluation, which keeps the engine from oscillating within one cycle.

## Slot frees: resuming

When slots free up (a torrent completes, is removed by its app, or is evicted by the stalled module), Zephyrus resumes its own paused torrents in priority order — **group weight descending, then torrent age FIFO (oldest first)**. Resumes happen in two tiers:

1. **Queue waiters** — torrents paused with reason `queue` only. They must first wait out a **resume cooldown** of `max(2× poll interval, 60 s)` measured from their queue pause. This hysteresis stops flapping and queue-position churn from oscillating the active count; a just-paused torrent stays paused for at least one cooldown.
2. **Slow-paused torrents** — torrents that [yielded their slot for being slow](./stalled-management). No extra cooldown (the slow threshold already gated the pause), and a torrent paused by slow in the current tick is never resumed in the same tick.

Tier 1 is fully served before tier 2: healthy waiters always get freed slots before slow returns. [Stalled retries](./stalled-management) run after both tiers and only consume leftover free slots, respecting the same global and group ceilings.

Only torrents Zephyrus paused itself (`pausedByUs=true`) are ever resumed. Torrents you or an app paused are untouchable.

## Boot adoption sweep

> [!NOTE]
> **What to expect at first startup.** On the first successful evaluation after boot, the adoption sweep pauses every managed started-phase torrent Zephyrus did not pause itself, then resumes the highest-priority set within the caps once the resume cooldown (`max(2× poll interval, 60 s)` — at least 60 s) elapses. A burst of pauses followed by orderly resumes is **normal, temporary, and one-time per boot** — not a fault. Seeding torrents and user/app pauses are never touched.

Zephyrus's queue is authoritative. On the **first successful evaluation after startup** (the adoption sweep), it pauses every managed started-phase torrent — `downloading`, `stalled`, `checking`, or `queued` — that it did not pause itself, under reason `queue`. Then the ordinary tier-1 resumes (after the cooldown) start the top set from a clean slate, in weight/FIFO order up to the caps.

Hard exclusions, structurally guaranteed:

- `seeding` / `completed` torrents — seeds are never touched.
- `paused`, `error`, `unknown` torrents — a client-paused torrent may be user/app-paused; it is never claimed.
- Unmanaged groups and groupless torrents — the ownership rule.
- Torrents already carrying any Zephyrus pause reason — no double-pause.
- **Pinned torrents** — exempt from the sweep entirely.

The sweep latch is consumed only by a cycle that actually evaluates snapshots: if the client is unreachable at boot (degraded mode), the sweep fires on the first *successful* poll instead. This also acts as a safety net after a restart: torrents left running in qBit's queue are adopted and re-ordered rather than ignored.

## Coexistence with qBittorrent's own queue

qBittorrent's internal queueing (`max_active_downloads` / `max_active_torrents` in qBit's settings) **may stay enabled**. The division of labor:

- **Zephyrus decides how many torrents are started** (the started set and its caps).
- **qBittorrent decides which of the started torrents actually transfer.** A started torrent waiting in qBit's queue sits in canonical `queued` state: it occupies its Zephyrus slot, is never stall-tracked, and is otherwise neutral.

Zephyrus never changes qBit's global settings to enforce its caps — it uses per-torrent pauses only, so unmanaged torrents are unaffected.

Operational note: the repository's compose file recommends disabling qBit's internal queueing or setting both limits generously, because two competing queues can cause start/stop thrash. Coexistence is fully supported either way; generous qBit limits simply let Zephyrus's ordering decide everything.

---
title: "Stalled management"
description: "Client-signal stall detection, threshold pauses, backoff retries, give-up, completion bias, and slow slot-yielding."
section: "User Guide"
order: 6
---

# Stalled management

A stalled torrent holds a [started slot](./smart-queuing) without making progress. Zephyrus evicts it after a threshold, retries it periodically with growing patience intervals, and eventually deprioritizes it — without ever removing it (removal is the owning app's job).

Two distinct concepts are handled here:

- **Stalled** — the torrent makes no progress at all, as reported by the client.
- **Slow** (optional) — the torrent downloads, but below a speed floor. It only ever yields its slot to waiters; it is never treated as stalled.

## Stall detection: the client signal is authoritative

A torrent is stalled when its canonical state is `stalled` — for qBittorrent, the `stalledDL` state. There is **no speed-observation fallback**: a crawling-but-downloading torrent is never "stalled" here; that case belongs to the slow detector. `queued` torrents (waiting in qBit's own queue) are never stall-tracked either.

When a managed torrent stays continuously stalled for `stalled.threshold_minutes` (default **30**), Zephyrus pauses it (`pausedByUs=true`, reason `stalled`), freeing its slot. The continuity clock resets if the torrent leaves the stalled state on its own; brief `stalledDL ↔ downloading` flapping therefore never triggers a pause.

## Retry cycle with growing backoff

A stalled-paused torrent is retried after a wait that grows with each consecutive failure:

```
wait = interval_minutes × backoff_multiplier^retryCount
       capped at max_interval_minutes
```

Defaults: `interval_minutes: 15`, `backoff_multiplier: 2`, `max_interval_minutes: 1440` (24 h):

| Consecutive no-progress retries (`retryCount`) | Wait before next retry |
|------------------------------------------------|------------------------|
| 0 | 15 min |
| 1 | 30 min |
| 2 | 1 h |
| 3 | 2 h |
| 4 | 4 h |
| 5 | 8 h |
| 6 | 16 h |
| 7+ | 24 h (ceiling) |

Set `backoff_multiplier: 1` for a fixed interval (the documented opt-out). The ceiling must be ≥ the base interval; validation rejects anything else.

**Meaningful progress resets the backoff.** If the torrent downloaded a significant amount since the last retry, `retryCount` resets to 0 and the next wait is the base interval again. The significance threshold is **proportional**:

```
threshold = min(progress_reset_bytes, max(1, floor(remaining_at_last_retry / 2)))
```

"Remaining" is the unfinished byte count at the moment of the last retry. The proportional half-of-remaining term matters near completion: a torrent at 99% may have fewer bytes left than the fixed `progress_reset_bytes` (default 10 MiB), so a fixed threshold could never be reached and its backoff would sit at the ceiling forever. The floor is 1 byte; zero or negative gain never resets. The first retry has no measurement baseline, so it never counts as progress.

**Retry mechanics.** At most **one** torrent is retried per evaluation, and only when:

- `stalled` is its **only** active pause reason (a schedule or queue gate blocks the retry), and
- the effective wait has elapsed (measured from the threshold pause / last retry).

Candidates are picked least-recently-retried first (ties: oldest stall, then info hash), and the pick must fit the queue ceilings — global and group caps count everything already started plus resumes emitted earlier in the same tick. If the head candidate is blocked, the next one is tried; if all are blocked, nothing happens and eligibility is preserved.

A retry **reannounces first** (when the adapter supports it — qBittorrent does), then resumes. This asks the tracker for fresh peers before spending the slot. If the torrent demonstrably finished on its own (state `seeding`/`completed`), the stalled pause is healed and all stall bookkeeping resets.

## Give-up: deprioritize, never delete

`stalled.retry.give_up_hours` (default **72**) is measured from the **first threshold pause** of the torrent's stall saga — the clock survives retries. If the torrent still hasn't completed after that window:

- A warning is written to the action log ("stalled retry abandoned after 72h: … — retried again only when nothing else is left to download") and surfaced in the dashboard.
- The torrent gets the `givenUp` flag and drops out of the normal retry pool **while the system is busy** — busy meaning any active download or any torrent waiting for a queue slot.

This is a *conditional* give-up, not abandonment. When the system goes **idle** — nothing actively downloading, no queue waiters, no started stalled runners — given-up torrents rejoin the retry pool as a **last resort** and keep being tried at their capped backoff intervals. The `givenUp` latch stays set: as soon as activity returns, they park again automatically. The decision to actually remove a hopeless torrent always belongs to the owning app; Zephyrus never deletes.

## Completion bias (optional)

An unfinished torrent is permanent waste: apps won't re-add it, and Zephyrus can't touch files. The optional `stalled.completion_bias` block therefore increases the effort to finish a torrent **the closer it gets to completion**:

```yaml
stalled:
  completion_bias:
    tiers:
      - min_progress: 0.5    # 50–90%: give-up ×2, retry ceiling 6 h
        give_up_multiplier: 2
        max_retry_interval_minutes: 360
      - min_progress: 0.9    # 90–99%: give-up ×5, retry ceiling 2 h
        give_up_multiplier: 5
        max_retry_interval_minutes: 120
      - min_progress: 0.99   # ≥99%: give-up ×10, retry ceiling 1 h
        give_up_multiplier: 10
        max_retry_interval_minutes: 60
```

Tiers must be strictly ascending by `min_progress`. On every evaluation, the **highest tier whose `min_progress` ≤ the torrent's current progress** applies; below the lowest tier (or with the block absent) behavior is exactly the plain policy. Matching is re-evaluated against live progress each tick — bias state is never persisted.

A matching tier has three effects:

1. **Longer give-up window** — `give_up_hours × give_up_multiplier`, matched against the progress at check time. With the defaults above and `give_up_hours: 72`, the effective windows are 144 h (≥50%), 360 h (≥90%), and 720 h / 30 days (≥99%).
2. **Tighter retry ceiling** — the wait is capped at `min(max_interval_minutes, tier.max_retry_interval_minutes)`. Even with a huge backoff exponent, a near-complete torrent is retried frequently — more chances to catch a rotating seeder.
3. **Unpark (amnesty)** — a `givenUp` torrent whose current progress matches a tier rejoins the retry pool **even while the system is busy**. The latch itself stays set (only the busy-park behavior is suspended), and these attempts are labeled "completion bias — unparked" in the action log. Regular bias-assisted retries carry a "completion bias" label.

## Slow slot-yielding (optional)

The `stalled.slow` block handles the other case: a torrent that *is* downloading, but slowly.

```yaml
stalled:
  slow:
    speed_floor_bytes: 5242880   # 5 MiB/s
```

A `downloading` torrent whose speed stays continuously below `speed_floor_bytes` for `stalled.threshold_minutes` — the **same shared wait** as the stalled pause; the slow block has no threshold of its own — is paused with reason `slow`, **but only while at least one other torrent is waiting for a queue slot**. No waiters, no yield: a slow torrent keeps running when nobody needs its slot.

The stalled and slow continuity clocks (`stalledSince` / `slowSince`) are independent. Slow-paused torrents are resumed in [queue resume tier 2](./smart-queuing) — after healthy queue waiters, with no extra cooldown — and their slow clock resets on resume. Absent `slow` block = the feature is disabled.

## Slot priority summary

Freed slots are spent in this order:

1. **Queue waiters** — group weight descending, then FIFO.
2. **Slow-paused torrents** — same ordering, after tier 1 is exhausted.
3. **Stalled retries** — only leftover free slots, at most one per evaluation.

Healthy waiters always beat stalled/slow returns. [Pinned](./prioritization) torrents are exempt from all stall and slow management: no detection, no threshold pause, no give-up clock, no retry candidacy.

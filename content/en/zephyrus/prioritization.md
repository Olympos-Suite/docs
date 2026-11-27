---
title: "Prioritization"
description: "Resume order by group weight and torrent age, and the manual pin for user priority."
section: "User Guide"
order: 4
---

# Prioritization

When more torrents want a slot than the [caps](./smart-queuing) allow, prioritization decides who gets it.

## Resume order

Candidates are sorted by two criteria, in this order:

1. **Group weight** (`groups.<name>.weight`, integer, default `0`) — higher weight first.
2. **Torrent age** — the time the torrent was added to the client (`addedAt`), **oldest first** (FIFO).

Ties break deterministically by info hash, so the order is stable across evaluations.

```yaml
groups:
  eros:
    weight: 10   # eros torrents resume before psyche torrents
  psyche:
    weight: 5
```

With equal weights, the torrent that has been waiting in the client longest resumes first — no torrent starves behind newer arrivals.

The **pause order is the exact inverse**: when a cap is exceeded, the lowest-weight group's newest torrent is paused first. Weight therefore expresses a consistent preference in both directions.

This ordering applies to queue-waiter resumes and slow-paused returns alike. Stalled retries use their own eligibility order (least recently retried first) and only consume leftover slots — see [Stalled management](./stalled-management).

## Manual priority: pin

A **pin** is a user override that exempts one managed torrent from automatic management. Pin it from the Torrents screen in the [dashboard](./dashboard) (the pin toggle on each row), or via the API:

```bash
# Pin a managed torrent (204 No Content on success)
curl -X POST -H "Authorization: Bearer $ZEPHYRUS_TOKEN" \
  http://localhost:9695/api/torrents/<infoHash>/pin

# Remove the pin — back to normal management (204)
curl -X DELETE -H "Authorization: Bearer $ZEPHYRUS_TOKEN" \
  http://localhost:9695/api/torrents/<infoHash>/pin
```

An unknown info hash, or a torrent whose group is not managed, returns `404`.

### What a pin does

A pinned torrent is **never paused** by:

- the global or per-group queue caps,
- slow slot-yielding,
- stalled threshold pauses, retries, or the give-up clock,
- the boot adoption sweep.

The **weekly schedule still applies** to pinned torrents: speed limits and `paused` windows are enforced as usual (a pin is priority over other torrents, not an exemption from your bandwidth policy).

Pinned torrents that are downloading or checking **count normally toward the global and group active totals** — they consume slots. The caps only ever trim *unpinned* torrents; if pinned torrents alone overflow a ceiling, fewer (or zero) pauses are possible rather than violating a pin.

### What happens at the moment of pinning

Pinning takes effect immediately (it triggers an evaluation without waiting for the next poll):

- Any `queue`, `stalled`, or `slow` pause reason is cleared, and the stalled/queue bookkeeping resets (`stalledSince`, `firstStalledAt`, `retryCount`, `progressAtLastRetry`, `slowSince`, `queuePausedAt`, `queueResumedAt` → null/0). The retry history latches (`lastRetryAt`, `givenUp`) are kept as history.
- The `schedule` reason is **not** cleared by a pin — a schedule pause is released normally when its window ends.
- If no pause reason remains and the client still shows the torrent paused **because Zephyrus paused it**, it is resumed right away. A pause made by you or an app is never lifted, pin or no pin.

Like any resume, a pin release holds its slot through the **2× poll grace window** anchored at `queueResumedAt` until the start actually lands in the client, so the caps cannot overshoot while the resume propagates.

### Persistence

Pins are stored in the `torrents.pinned` column and survive restarts. If the database is lost, pins are lost with it and the torrents return to normal management — the fail-safe direction. Unpinning simply re-opens the torrent to ordinary policy; the next evaluation applies whatever the caps and priorities dictate.

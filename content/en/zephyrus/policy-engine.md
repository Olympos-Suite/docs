---
title: "Policy Engine"
description: "The pure evaluation function: composition order, module responsibilities, key types, and why pauses always precede resumes."
section: "Developer Guide"
order: 2
---

The policy engine lives in `src/core/policy/` and is the heart of Zephyrus. It is a **pure function**: identical inputs always produce identical outputs, it performs no I/O, never reads the clock (`now` is injected), uses no randomness, and never mutates its inputs (the state map is cloned up front). All side effects — adapter calls, DB writes, logging — belong to the orchestrator. This makes every policy rule unit-testable without a client, a database, or timers.

## Entry point

From `src/core/policy/policy-engine.ts`:

```ts
export function evaluatePolicies({ snapshots, state, config, capabilities, now, lastSchedule = null, adoptSweep = false }: EvaluatePoliciesInput): PolicyEvaluation
```

| Input | Meaning |
|-------|---------|
| `snapshots` | Canonical `TorrentSnapshot[]` from the adapter (all client torrents, managed or not) |
| `state` | `PolicyStateMap` — per-torrent policy bookkeeping keyed by infoHash |
| `config` | Validated `ZephyrusConfig` (groups, ceilings, stalled, schedule) |
| `capabilities` | What the adapter supports (reannounce / downloadLimit / uploadLimit) |
| `now` | Epoch ms, injected by the caller |
| `lastSchedule` | Previous schedule key (kept for API/cron compatibility; limit sync is per-torrent via `appliedLimits`) |
| `adoptSweep` | One-shot boot latch from the orchestrator (see [Architecture](./architecture)) |

Output: `{ actions: EngineAction[], nextState: PolicyStateMap, schedule: string | null }`. The orchestrator executes `actions` in order, persists `nextState`'s flag deltas, and feeds `schedule` back as the next `lastSchedule`.

## Composition order (pinned)

Actions are emitted in a fixed order. **All pauses come before the resume tiers**, and **queue resumes come before stalled retries**. The order is a correctness invariant, not a style choice:

| Position | Module call | What it does |
|----------|-------------|--------------|
| 1 | schedule pause / release | `paused` profile window → pause managed torrents (reason `schedule`); any other resolution releases the schedule reason, resuming only when no other reason remains |
| 1b | schedule limit sync | `limited` profile → per-torrent `setLimits` (equal shares of the total ceiling); `unlimited` → `clearLimits`. Per-torrent `appliedLimits` keying catches mid-window adoptions and partial failures; paused torrents are skipped |
| 1c | `applyPinnedReleases` | Pinned torrents: clear `queue`/`stalled`/`slow` reasons, reset their bookkeeping, resume when eligible. The `schedule` reason is never cleared by a pin |
| 1d | `applyAdoptionSweep` | Boot latch only: stop running managed download-phase torrents under reason `queue` (pauses only) |
| 2 | `applyQueuePauses` | Enforce global + per-group ceilings; pause lowest-priority torrents (reason `queue`) |
| 2b | `applySlowTracking` | Optional slow slot-yielding pauses (reason `slow`), only while queue waiters exist |
| 3 | `applyStalledTracking` | Stall detection, threshold pauses (reason `stalled`), give-up notes |
| 4 | `applyUnmanaged` | Release torrents whose group left config (resume if ours + clear limits + `unmanage`); note disappeared torrents |
| 5 | `applyQueueResumes` | Freed slots go FIRST to queue waiters (tier 1), then slow-paused retries (tier 2) |
| 6 | `applyStalledRetry` | At most ONE stalled retry per evaluation, using only leftover free slots; reannounce → resume |

### Why this order is safe

The engine's own comment gives the safety argument: no pause is ever emitted after position 3/2b. Resumes at positions 1/1c/4 are safe because those torrents are still `paused` in *this tick's* snapshots, so the pause modules at 2/2b/3 (which only pick download-phase snapshots) cannot select them. Anything paused at 1–3/2b carries a pause reason that excludes it from same-tick resume candidacy at 5/6 (the exactly-single-reason rules, the tier-1 cooldown, and the same-tick slow-pause exclusion passed from 2b into 5).

Two slot-accounting mechanisms keep ceilings honest across the resume tiers:

- **`pendingResumes`** — the set of resume hashes *actually emitted earlier this tick* (positions 1/1c/4/5, managed only). The stalled retry at position 6 counts them against the global and group ceilings, so earlier resumes correctly shrink what the retry may spend. User/app-paused torrents are never inferred into this budget.
- **`queueResumedAt` grace** — a resumed torrent whose start has not landed yet (snapshot still `paused`) occupies its slot for a 2×poll grace window, across ticks. Without it, the start-propagation gap would trigger a second resume and overshoot the ceiling.

## Module responsibilities

### `queue.ts` — smart queuing + adoption sweep

- **Started set** (`collectActiveDownloads`): managed torrents in `downloading`, `checking`, `queued`, or `stalled`. `queued` is the client's internal queue waiting room — started by Zephyrus, transferring nothing, but occupying a slot and never stall-tracked. `stalled` runners hold their slot until the stall module evicts them. Excluding either fabricates free slots and causes over-start or pause/resume ping-pong.
- **Pauses**: per-group ceiling violations first, then the global ceiling. Pause priority is the inverse of resume priority: lowest group weight first, then newest `addedAt` first, infoHash as deterministic tiebreaker. Pinned torrents count toward active totals but are never pause candidates.
- **Resumes**: two tiers sorted by group weight DESC → `addedAt` ASC (FIFO) → infoHash. Tier 1 = entries with reasons exactly `['queue']`, gated by a resume cooldown of `max(2 × poll_interval_seconds, 60 s)` measured from `queuePausedAt` (hysteresis against flapping). Tier 2 = reasons exactly `['slow']`, no cooldown (the slow threshold is the hysteresis), minus torrents slow-paused this tick. One slot loop books global + group ceilings across the combined list.
- **Adoption sweep** (`applyAdoptionSweep`): see [Architecture](./architecture).

### `schedule.ts` — weekly windows

- `resolveSchedule` converts `now` to (weekday, minutes-since-midnight) in `config.timezone` via a cached `Intl.DateTimeFormat`, then returns the **first matching window** in config array order; no match → `unlimited`.
- Window matching: `days` lists the day the window *opens*; `to` is exclusive; `from > to` is a midnight-crossing window (matches late on a listed day or early on the following day); `from === to` is a degenerate zero-length window, never active.
- Profile kinds: `limited` (named speed profile), `paused` (reserved keyword — pause window), `unlimited`. The config schema rejects a user profile named `paused`.
- `computeScheduleShares` splits a limited profile's **total** bandwidth equally: download divisor = `downloading` + `stalled`; upload divisor = those plus `seeding`. `floor(total / n)` with a 1 B/s floor (a share must never read as unlimited); total 0 stays 0 (unlimited); zero active torrents → the full total for the next one.

### `stalled.ts` — stalled + slow + retry

- **Stalled definition**: the client's canonical `state === 'stalled'` signal is authoritative. There is no speed-observation fallback; a crawling-but-downloading torrent is the *slow* detector's job.
- **Slow** (optional `stalled.slow` block): a `downloading` torrent below `speed_floor_bytes`, continuously slow for the shared `stalled.threshold_minutes`, yields its slot **only while at least one queue waiter exists** (an entry with reasons exactly `['queue']`). `stalledSince` and `slowSince` anchors are independent.
- **Threshold pause**: continuous stall ≥ threshold → pause with reason `stalled`; seeds `lastRetryAt` at the pause tick so a pause can never be self-cancelled by a same-tick retry. `firstStalledAt` anchors the give-up clock at the first threshold pause of the saga and survives retries; it clears only on a completion heal (`seeding`/`completed`).
- **Retry cycle** (position 6): eligible when `stalled` is the only reason and the effective interval elapsed: `interval_minutes × backoff_multiplier^retryCount`, capped at `max_interval_minutes` (and at a matching completion-bias tier's tighter ceiling). `retryCount` resets to 0 on meaningful progress: new bytes since the last retry ≥ `min(progress_reset_bytes, max(1, floor(remaining_at_last_retry / 2)))` — the proportional term keeps near-complete torrents resettable. Pick order: least recent `lastRetryAt`, then oldest `stalledSince`, then infoHash; first-fit through candidates against the slot budget; at most one pick. Emits `reannounce` first when capable, then `resume`.
- **Conditional give-up**: after `give_up_hours` from `firstStalledAt`, a warning note is logged and `givenUp` latches. Given-up torrents are skipped while the system is busy (any active download or queue waiter) and rejoin the pool only when fully idle ("revived — queue idle"). The latch never clears — they park again automatically when activity returns.
- **Completion bias** (optional `stalled.completion_bias`): strictly ascending tiers keyed by `min_progress`; the highest tier ≤ current progress applies. It scales the give-up window (`give_up_hours × give_up_multiplier`), tightens the retry ceiling (`max_retry_interval_minutes`), and grants busy-park amnesty ("completion bias — unparked"). Tier matching is re-evaluated against live progress every tick; nothing about the bias is persisted.

### `unmanaged.ts` — ownership

`isManagedSnapshot`: managed iff the torrent's group is a key of `config.groups` (groupless → never). `applyUnmanaged` reconciles the state map: disappeared torrent → `note` + drop; group left config → resume if paused by us, clear any applied per-torrent limits (capability-gated), `unmanage`, drop. Also exports `getGroupWeight` (default 0) and `getGroupMaxActive` (null = no group ceiling).

### `pinned.ts` — user manual priority

Pin releases at position 1c: clear `queue`/`stalled`/`slow` reasons and reset stalled/queue bookkeeping (`lastRetryAt` and `givenUp` are history latches and kept). Resume promptly when no reason remains, the pause was ours, and the client still shows `paused`. A user/app pause is never lifted. Pinned torrents remain exempt from queue ceilings, slow/stalled tracking, and the adoption sweep; schedule windows still apply. See [Prioritization](./prioritization).

## Key types

### `TorrentPolicyState` (`state.ts`)

Per-torrent bookkeeping, keyed by infoHash in `PolicyStateMap`:

| Field | Purpose |
|-------|---------|
| `reasons: PauseReason[]` | Active reasons Zephyrus wants the torrent paused; empty = not paused by us |
| `pausedByUs` | Mirrors the DB write-ahead flag; invariant: `pausedByUs === reasons.length > 0` for engine-touched entries |
| `stalledSince` / `firstStalledAt` | Current stall episode anchor / saga-level give-up clock anchor |
| `lastRetryAt` / `retryCount` / `progressAtLastRetry` | Retry clock, backoff exponent, progress baseline |
| `slowSince` | Continuous slow-episode anchor |
| `queuePausedAt` | Cooldown anchor (first queue pause of the saga) |
| `queueResumedAt` | Cross-tick in-flight slot anchor (2×poll grace) |
| `givenUp` | Conditional give-up latch (deprioritize, never delete) |
| `appliedLimits` | Schedule key of limits currently applied in the client (null = unlimited) |
| `pinned` | User manual priority; mirrors the DB column (DB loss → pin lost → normal management, fail-safe) |

`addPauseReason` / `removePauseReason` maintain the ownership invariant; `clonePolicyState` guarantees the engine never mutates caller input. Multi-reason pauses resume only when **all** reasons clear. The DB stores a single `pause_reason` column; the orchestrator picks one by priority `schedule > stalled > slow > queue` (`pickPauseReason`) for DTOs and persistence — after a restart the engine re-derives every still-valid reason from live state within one tick.

### `EngineAction` (`actions.ts`)

```ts
export type EngineAction =
  | { kind: 'pause'; hashes: string[]; reason: PauseReason; description: string }
  | { kind: 'resume'; hashes: string[]; description: string }
  | { kind: 'reannounce'; hashes: string[]; description: string }
  | { kind: 'setLimits'; hashes: string[]; downloadBytesPerSec: number; uploadBytesPerSec: number; description: string }
  | { kind: 'clearLimits'; hashes: string[]; description: string }
  | { kind: 'unmanage'; hash: string; description: string }
  | { kind: 'note'; hash: string | null; description: string }
```

Pure data. `description` is the human-readable reason written to `action_log` — every action carries one. `unmanage` and `note` are bookkeeping/audit only; nothing is sent to the client. `setLimits` values are per-torrent bytes/s (0 = unlimited); client global settings are never touched.

## Purity and testability

Because the engine is a pure function, tests construct snapshots + state + config fixtures (`src/core/policy/test-fixtures.ts`), call `evaluatePolicies` with a fixed `now`, and assert on the emitted actions and next state — no adapters, no DB, no timers. The 171 engine tests cover resume ordering (weight + FIFO), `pausedByUs` gating, midnight-crossing windows, cooldowns, backoff/give-up/completion-bias, pin releases, and the adoption sweep. Integration tests additionally run the engine through the orchestrator with the [scriptable mock adapter](./adapters). Never test the engine against a live client.

Related pages: [Architecture](./architecture) (execution model), [Adapters](./adapters) (capabilities), [Testing](./testing) (suite layout), [Invariants](./invariants) (rules the composition protects).
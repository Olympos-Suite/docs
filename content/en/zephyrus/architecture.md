---
title: "Architecture"
description: "How Zephyrus is layered: the pure policy engine, the adapter boundary, the orchestrator poll loop, and boot/shutdown wiring."
section: "Developer Guide"
order: 1
---

Zephyrus is a single-package TypeScript service (Node >= 22, Fastify 5, better-sqlite3 + Drizzle, Zod, node-cron, Pino). It applies download-phase policy — smart queuing, prioritization, weekly bandwidth scheduling, stalled-torrent management — to exactly one torrent client connection. This page maps the codebase for contributors; the feature behavior itself is documented in the User Guide ([Smart Queuing](./smart-queuing), [Weekly Schedule](./weekly-schedule), [Stalled Management](./stalled-management)).

## Design pillars

Three decisions shape every module:

1. **The torrent client is the source of truth.** SQLite holds only a mirror of client state, policy flags (`pausedByUs`, `pinned`), and the action audit trail. Everything except policy flags is rebuildable from the client at any time.
2. **The policy engine is a pure function.** `(snapshots, state, config, capabilities, now) → actions + next state`. No I/O, no clock reads, no randomness, no adapter calls. All side effects live in the orchestrator and the adapter layer.
3. **The adapter boundary is narrow and mutation-banned.** The `TorrentClient` type exposes only connect/list/pause/resume plus optional reannounce and per-torrent limits. `add`, `delete`, `rename`, `setCategory` are absent by design — enforced by types, not code review. See [Adapters](./adapters) and [Invariants](./invariants).

## Layering (mandatory)

HTTP handling follows a strict chain; no layer may be skipped. A route never calls a repository, and no route or controller imports the database. From `src/http/routes/api-routes.ts`:

```ts
/**
 * /api route table (spec §9 + setup/auth wizard). Routes ONLY wire HTTP to
 * controllers — controllers talk to services (orchestrator / config / setup /
 * auth); no route or controller ever imports a repository or the database.
 */
```

```
HTTP request
    |
    v
+---------------+   src/http/routes/api-routes.ts
| Routes        |   wire HTTP verbs/paths to controllers, nothing else
+---------------+
    |
    v
+---------------+   src/http/controllers/*-controller.ts
| Controllers   |   call services, shape pinned DTOs (src/http/dto.ts),
+---------------+   choose status codes (204/400/404/409/422...)
    |
    v
+---------------+   src/services/orchestrator.ts, config-service.ts,
| Services      |   setup-service.ts, auth-service.ts
+---------------+
    |
    v
+---------------+   src/db/repositories/*-repository.ts
| Repositories  |   Drizzle queries, one class per table
+---------------+
    |
    v
+---------------+   better-sqlite3 (WAL, foreign keys on)
| SQLite        |   src/db/db.ts opens + migrates
+---------------+
```

The orchestrator sits beside this chain rather than inside it: it owns the poll loop, calls the pure engine, executes actions through the adapter, and persists results through repositories. Controllers read its live views (`getStatusSnapshot`, `getTorrentsView`, `listRecentActions`) instead of querying the DB themselves.

## Canonical types

`src/core/types.ts` is the single vocabulary imported by every layer — engine, adapters, DB schema, and DTOs all reference it:

```ts
export const TORRENT_STATES = ['downloading','queued','stalled','paused','seeding','completed','checking','error','unknown'] as const
export type TorrentState = (typeof TORRENT_STATES)[number]

export const PAUSE_REASONS = ['queue','stalled','slow','schedule'] as const
export type PauseReason = (typeof PAUSE_REASONS)[number]

export const ACTION_KINDS = ['pause','resume','reannounce','limit','unmanage','note'] as const
export type ActionKind = (typeof ACTION_KINDS)[number]
```

Plus `TorrentSnapshot` (infoHash, name, group, state, addedAt, downloadSpeed, size, progress) and `ClientCapabilities` (reannounce, downloadLimit, uploadLimit). Adapters map client-specific states into this canonical model; the engine never sees raw client strings. Note the engine's action union (`src/core/policy/actions.ts`) uses `setLimits`/`clearLimits`, which the orchestrator collapses to the single `limit` audit kind when writing `action_log`.

## The orchestrator poll loop

`src/services/orchestrator.ts` polls the client every `client.poll_interval_seconds` (default 5 s). One tick:

```
poll timer / cron trigger / forced trigger (pin, hot-reload)
    |
    v
[1] connect if needed, then client.listTorrents()          (adapter)
    |        failure -> degraded mode + backoff retry, tick ends
    v
[2] reconcile: upsert torrents mirror, adopt policy state,
    drop rows for disappeared torrents, safe-mode check
    |
    v
[3] evaluatePolicies({ snapshots, state, config,            (pure engine)
      capabilities, now, lastSchedule, adoptSweep })
    |
    v
[4] WRITE-AHEAD: persist pausedByUs=true + reason for every
    pause action BEFORE any adapter call
    |
    v
[5] execute actions in emitted order via the adapter
    (pauses always precede resumes; batch stops on first error)
    |
    v
[6] persist flag deltas; roll back state of resumes/limits
    that never executed; append every action to action_log
    |
    v
[7] feed evaluation.schedule back as lastSchedule
```

Details that matter when modifying the loop:

- **In-flight guard.** A `tickInFlight` promise deduplicates concurrent triggers (poll timer, cron, pin mutation, hot-reload). A second trigger while a tick runs is skipped, not queued.
- **Write-ahead ownership.** Step 4 is the crash-safety core: the DB records *intent* before the client call. If the process dies mid-batch, the flag survives and the next boot knows the pause was ours. Resumes that failed or were never attempted keep their write-ahead flags (the orchestrator restores the pre-evaluation entry for those hashes), so a failed resume can never silently release ownership. See [Database](./database).
- **Audit granularity.** Pause/resume/reannounce actions write one `action_log` row per affected hash; `setLimits`/`clearLimits` write a single summary row (null hash, "(N torrents)" suffix) because limit syncs can span the whole managed set on every share change.
- **Cron tick.** A node-cron job runs every minute in `config.timezone`; when the resolved schedule key differs from `lastSchedule` it forces a tick, so window transitions apply within a minute even between polls. It is guarded against degraded/no-snapshot states.

## Boot adoption sweep

Zephyrus's queue is authoritative. On the **first successful evaluation** after boot, a one-shot latch (`sweepPending`) makes the engine stop every managed started-phase torrent (`downloading`, `stalled`, `checking`, `queued`) that Zephyrus did not pause itself, under reason `queue`. Ordinary queue resumes then start the top set by group weight + FIFO after the resume cooldown. Hard exclusions: seeding/completed torrents, client-paused torrents (possibly user/app pauses), unmanaged groups, pinned torrents, and entries already carrying any pause reason. Degraded or failed ticks never consume the latch — the sweep fires on the first cycle that actually evaluates snapshots. Implementation: `applyAdoptionSweep` in `src/core/policy/queue.ts`, invoked at composition position 1d.

## Degraded mode and safe mode

Two independent failure postures, both surfaced by `GET /api/status` (the Docker healthcheck):

- **Degraded** — the client is unreachable. Adapter errors of type `ClientUnreachableError` set `degraded = true`; the orchestrator keeps the last known state, logs a warning once, and retries with exponential backoff (`computeBackoffDelayMs`, capped so retries never run less often than the poll interval). A successful fetch clears degraded. `ConnectionUnsupportedError` (bad credentials, banned host, Web API too old) also degrades but is logged at error level: blind retries cannot fix it, an operator must act. The process never crashes on client failure.
- **Safe mode** — ownership is uncertain. During reconciliation, a *managed* torrent that is `paused` in the client with no record of Zephyrus having paused it (missing DB row or `pausedByUs = false`) is adopted as not-ours and latches `safeMode` for the process lifetime. Such torrents are never touched — inaction over wrong action. This is the DB-loss fail-safe: delete the database, restart, and Zephyrus rebuilds its mirror from the client while refusing to resume anything it cannot prove it paused. `GET /api/status` lists the affected torrents in `safeModeTorrents`.

## Boot and shutdown wiring

`src/index.ts` boots in this order:

1. `ensureConfigFile` — create a self-contained default `config.yaml` when missing (first boot / empty Docker volume must boot, not crash), then `loadConfig` (YAML → `env:NAME` resolution → Zod validation; invalid config exits with a clear aggregated error).
2. `openDatabase` — create the parent dir, open SQLite with WAL + foreign keys, **auto-apply Drizzle migrations** from `drizzle/`.
3. `createQbittorrentClient` + `createOrchestrator` (with an `onConfigApplied` hook that applies `server.log_level` live).
4. `buildApp` (`src/app.ts`) — Fastify with the Pino logger, auth plugin, `/api` routes, and static serving of `web/dist` when present.
5. `app.listen` on `config.server.port` (default 3030), then `orchestrator.start()` — which prunes `action_log` rows older than 90 days, arms the poll timer and cron job, and runs the first tick.

`SIGTERM`/`SIGINT` trigger graceful shutdown: close the HTTP server, then `orchestrator.shutdown()` — stop timers, await any in-flight tick, best-effort resume **every `pausedByUs` torrent** (10 s timeout), clear their per-torrent limits, write `resume` audit rows only for releases that actually succeeded (failures keep the flag and get an error note), and close the DB. A second signal during shutdown is ignored so the release is never hard-killed mid-flight. If Zephyrus is removed entirely, torrents simply continue under client defaults — it is an optional layer.

## Hot reload

`PUT /api/config` validates, then calls `orchestrator.applyNewConfig`: if any `client` connection field changed, the adapter is recreated via the injectable `clientFactory`; a changed poll interval re-arms the timer; all `appliedLimits` markers are invalidated so schedule limits re-apply even when the profile key string is unchanged; and a tick is forced when snapshots exist. The config is then persisted atomically to the same `config.yaml` the process booted from. See [API Reference](./api-reference).

## Where to go next

- [Policy Engine](./policy-engine) — composition order and module internals.
- [Adapters](./adapters) — the client contract and the qBittorrent implementation.
- [API Reference](./api-reference) — every HTTP endpoint.
- [Database](./database) — schema, repositories, write-ahead rationale.
- [Invariants](./invariants) — the non-negotiable rules and where each is enforced.
- [Testing](./testing) — suite layout, mock scripting, conventions.
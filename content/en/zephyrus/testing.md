---
title: "Testing & Conventions"
description: "The Vitest suite layout, mock-adapter scripting, commands, code conventions, and the contribution workflow."
section: "Developer Guide"
order: 7
---

Zephyrus is tested with **Vitest** (node environment, `src/**/*.test.ts` co-located with the code). The suite currently has **350 tests across 19 files**, all passing without a live torrent client, network access, or real timers. A live qBittorrent 5.x is required only for manual/E2E verification — never in CI.

## Commands

Root package (Node >= 22, pnpm):

| Command | What it does |
|---------|--------------|
| `pnpm install` | Install deps (better-sqlite3/esbuild builds allow-listed in `pnpm-workspace.yaml`) |
| `pnpm dev` | `tsx watch src/index.ts` — auto-creates `./config.yaml` on first run |
| `pnpm build` / `pnpm start` | `tsc` → `dist/`, then `node dist/index.js` |
| `pnpm test` / `pnpm test:watch` | `vitest run` / `vitest` watch mode |
| `pnpm typecheck` | `tsc --noEmit` (strict) |
| `pnpm db:generate` / `pnpm db:migrate` | drizzle-kit generate / migrate (migrations also auto-apply on boot) |

The dashboard is a **nested package, not a pnpm workspace member**: `cd web && pnpm install --ignore-workspace && pnpm build` (→ `web/dist`, served statically by Fastify); `pnpm dev` inside `web/` runs the Vite dev server with an `/api` proxy.

Runtime env for local runs: `ZEPHYRUS_CONFIG` (default `./config.yaml`), `ZEPHYRUS_DB` (default `./data/zephyrus.db`), `ZEPHYRUS_TOKEN` (static bearer token; unset = warning + session auth only), plus any `env:NAME` refs in the config (e.g. `QBIT_PASSWORD`).

## Suite layout (verified counts)

| Area | Files | Tests |
|------|-------|-------|
| Policy engine (`src/core/policy/`) | `stalled.test.ts` 75, `policy-engine.test.ts` 37, `queue.test.ts` 28, `schedule.test.ts` 11, `pinned.test.ts` 10, `unmanaged.test.ts` 10 | **171** |
| Adapters (`src/adapters/`) | `qbittorrent-client.test.ts` 24, `state-mapping.test.ts` 22, `backoff.test.ts` 4, `mock-client.test.ts` 4, `torrent-client.test.ts` 1 (compile-time ban guard) | **55** |
| Orchestrator + HTTP (`src/services/`, `src/http/`) | `orchestrator.test.ts` 27, `setup-auth.test.ts` 21, `api.test.ts` 10 | **58** |
| Config + DB foundation (`src/config/`, `src/db/`) | `schema.test.ts` 28, `loader.test.ts` 20, `torrents-repository.test.ts` 9, `action-log-repository.test.ts` 5, `db.test.ts` 4 | **66** |
| **Total** | 19 files | **350** |

### What each layer's tests prove

- **Engine tests are pure-function tests**: fixtures in, `evaluatePolicies` with a fixed `now`, assertions on actions + next state. They cover the spec §13 acceptance criteria: resume ordering by group weight + FIFO, never resuming user/app-paused torrents (`pausedByUs` gating), midnight-crossing schedule windows, cooldown/backoff/give-up/completion-bias behavior, pin releases, and the adoption sweep.
- **qBit adapter tests mock HTTP** via the injectable `fetchImpl` — auth shapes (200 "Ok." vs 204 empty), cookie handling, re-login-once on 401/403, `rid` incremental merge, pipe-joined hash POSTs, version gate, error taxonomy. State mapping and backoff are tested as pure functions.
- **Orchestrator + API tests are integration tests** with the mock adapter, a temp-dir SQLite DB, and `fastify.inject` — no sockets, no live client. They cover the poll loop, write-ahead semantics, degraded/safe mode, graceful shutdown, hot-reload, the setup wizard, and session auth.
- **Config/DB tests** cover Zod validation (speed units, reserved `paused` profile, midnight windows, tier ordering), `env:NAME` resolution, atomic save round-trips, WAL/FK/migrations, and repository behavior (upsert never clobbers policy flags, audit ordering, retention prune).

## The mock-adapter scripting pattern

Integration tests build a "world" with `src/services/test-support.ts`:

```ts
import { createWorld, makeIntegrationConfig, makeIntegrationSnapshot, istanbulMs } from '../services/test-support.js'

const clock = { value: istanbulMs({ day: 6, hour: 12 }) } // mutable epoch-ms box
const world = createWorld({
  config: makeIntegrationConfig({ globalMaxActiveDownloads: 2, pollIntervalSeconds: 1 }),
  snapshots: [
    makeIntegrationSnapshot({ infoHash: 'a', group: 'eros', state: 'downloading', addedAt: 1000 }),
    makeIntegrationSnapshot({ infoHash: 'b', group: 'eros', state: 'downloading', addedAt: 2000 }),
    makeIntegrationSnapshot({ infoHash: 'c', group: 'eros', state: 'queued', addedAt: 3000 }),
  ],
  now: () => clock.value,
})

await world.orchestrator.tick()          // one full poll cycle, deterministically
clock.value += 61_000                    // advance past the 60 s resume-cooldown floor
await world.orchestrator.tick()

const calls = world.client.getCalls()    // ordered adapter interactions
// assert on calls, world.client.getSnapshots(), and the DB via repositories
world.testDb.cleanup()
```

Harness facts worth knowing:

- `createWorld` wires `createMockClient` + `createTestDb` (temp dir, real migrations) + `createOrchestrator` with a silent Pino logger and the injectable clock. **No timers are started** — tests drive `tick()` manually.
- `makeIntegrationConfig` defaults `pollIntervalSeconds` to 3600 to keep any accidental timer quiet; the queue-resume cooldown is `max(2 × poll, 60 s)`, so lower the poll interval (or advance the clock) to test resumes deterministically.
- `makeIntegrationSnapshot` fills sensible defaults (group `eros`, downloading, 1 GB, progress 0.5) — override only what the scenario needs.
- `istanbulMs` converts Europe/Istanbul wall-clock (fixed UTC+3) to epoch ms for schedule-window tests.
- Failure injection: `failures: { failNextList: 2 }` for degraded-mode scenarios, `failPauseHashes`/`failResumeHashes` for mid-batch adapter errors, `delays` for re-entrancy tests. See [Adapters](./adapters) for the full scripting API.

HTTP tests add `buildApp` + `app.inject` on top of the same world, with `vi.stubEnv('ZEPHYRUS_TOKEN', ...)` for auth scenarios (and `vi.unstubAllEnvs()` in `afterEach`):

```ts
const response = await app.inject({
  method: 'GET', url: '/api/torrents',
  headers: { authorization: `Bearer ${TOKEN}` },
})
expect(response.statusCode).toBe(200)
```

## Code conventions (suite standard)

From `AGENTS.md` — these differ from common defaults and are enforced in review:

- **No `enum`** → `as const` objects + inferred types (also for `TorrentState`, `pause_reason`, `action` values).
- **No `any`** → `unknown` + type guards.
- **No `I` prefix** on interfaces.
- **Exported functions must declare return types.**
- **2+ parameters → a single object-destructured parameter** (`fn({ a, b })`, not `fn(a, b)`).
- **File names kebab-case** (`policy-engine.ts`); React components PascalCase.
- **API layering is mandatory, no layers skipped**: Routes → Controllers → Services → Repositories → Database. A route never calls a repository; no route or controller imports the DB.
- TypeScript **strict** mode; `pnpm typecheck` must pass.

## Contribution workflow

1. **Read the maps first.** `codemap.md` at the repo root (and the folder-level `codemap.md` for deep work) describes responsibilities, entry points, and data flow. `Zephyrus.md` is the authoritative spec (Turkish); `AGENTS.md` carries the invariants. If code and spec disagree, the spec wins until the spec itself is changed.
2. **Check your change against the [invariants](./invariants).** Anything touching the adapter surface, ownership semantics, or engine purity needs extra scrutiny — several rules are enforced by types and will fail the build, but others (layering, no domain logic) are review-enforced.
3. **Write tests at the right layer.** Engine behavior → pure fixture tests in `src/core/policy/`. Runtime behavior → mock-adapter world tests. HTTP behavior → `fastify.inject` tests against pinned DTOs. Adapter behavior → `fetchImpl`-mocked tests. New policy rules need acceptance-style coverage (ordering, ownership, windows, audit reasons).
4. **Schema changes**: edit `src/db/schema.ts`, `pnpm db:generate`, commit the migration. Migrations auto-apply on boot; keep them additive and compatible with the rebuild-from-client contract.
5. **Run `pnpm typecheck` and `pnpm test`** before submitting; both must be green (350 tests at the time of writing). Keep DTO field names stable — the dashboard is built against `src/http/dto.ts`.
6. **New torrent client?** Follow the step-by-step in [Adapters](./adapters): the engine and its tests must not change a single line (acceptance criterion 12).

Related pages: [Architecture](./architecture), [Policy Engine](./policy-engine), [Adapters](./adapters), [API Reference](./api-reference), [Database](./database), [Invariants](./invariants), [Troubleshooting](./troubleshooting) (runtime failure modes).
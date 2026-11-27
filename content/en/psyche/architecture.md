---
title: "Architecture"
description: "Psyche's monorepo layout, mandatory server layering, Awilix composition root, kinded adapter registry, and the ten background jobs."
section: "Developer Guide"
order: 10
---

Psyche is a pnpm + Turborepo monorepo (Node ≥ 24, pnpm 12.7.0): a Fastify 5 API, a Next.js 16 web app, and shared packages. SQLite (better-sqlite3 + Drizzle) is the only database; Zod schemas are shared between frontend and backend. This page maps the codebase; behavior is documented in the User Guide.

## Monorepo layout

```text
apps/web               # Next.js + React 19, App Router (thin page shells)
apps/server            # Fastify API (routes → controllers → services → repositories)
packages/database      # Drizzle schema + migrations + createDatabase factory
packages/shared-types  # Zod schemas/DTOs shared by web and server
packages/typescript-config  # shared tsconfigs (base / nextjs / node)
```

`pnpm-workspace.yaml` covers `apps/*` and `packages/*`. Cross-package imports use workspace names (`@repo/database`, `@repo/shared-types`); local imports use the `@/` alias. The server never imports Zod into the web bundle — the web imports **types only** from `@repo/shared-types`.

## Layering

Server code follows a strict chain; **no layer may be skipped**:

```text
Routes → Controllers → Services → Repositories → Database (SQLite / Drizzle)
```

- **Routes** (`src/routes/*-routes.ts`) bind URLs to controller methods and contain no logic. Registered in `app.ts` via `register*Routes`.
- **Controllers** are thin, constructor-injected, one-liner delegations to services.
- **Services** hold all business logic (subscription, search, scoring, queue, organizer, …).
- **Repositories** are the only code that touches Drizzle.

The rule is **lint-enforced** (ESLint `import-x/no-restricted-paths`): routes importing services/repositories/adapters and controllers importing repositories or the database are errors; services importing drizzle/better-sqlite3 directly is a warning pending refactor. `pnpm lint` fails on violations — layering is mechanical, not review-based.

### Plugin stack

`buildApp` registers cross-cutting plugins in a fixed order before any route:

```text
error-handler → logging → db → session → security (helmet/cors/rate-limit/csrf)
  → auth gate → OpenAPI (swagger) → routes
```

Order matters: the error handler must wrap everything to emit envelopes on every branch; the auth gate runs as an `onRequest` hook so anonymous callers 401 before body parsing. Fastify shares the container's pino instance (a live `logging.level` change applies to request logs too), and per-request info logging is disabled — the Logs page shows meaningful events, not polling spam. An `onClose` hook flushes the persisted log sink **before** the DB closes, because Awilix disposers run concurrently and cannot be ordered.

## Dependency injection

One composition root (`src/container.ts`) wires everything with **Awilix**, `InjectionMode.PROXY`, constructor injection everywhere. Every registration is an explicit `asClass().singleton()` — transient-by-default is the known Awilix trap. No service-locator patterns elsewhere.

`bootContainer` runs an explicit async boot sequence before jobs start:

1. Open the database (WAL + foreign keys, migrations applied).
2. Attach the persisted log sink; early boot lines buffered in memory flush here.
3. Resolve the session secret (env → `/config/session.secret` → ephemeral with warning).
4. Seed settings defaults; apply `logging.level`; sweep expired sessions.
5. Register the bundled adapters (construction is inert — no network or keys needed).
6. Seed default quality profiles (empty table only).
7. **Smoke-check: resolve every registration.** Any failure throws — the app does not start.
8. Register all jobs, finalize stale `running` rows as failed, bind late attaches (search trigger, similarity gate, disk management, storage side-effects), then start the scheduler.

Late-bound dependencies use an attach pattern (`attachSubscriptionSearcher`, `attachSimilarityService`, …) to avoid DI cycles.

## Adapter registry

External services sit behind a **kinded adapter registry** keyed by `kind:name` — three kinds: `metadata_provider`, `indexer`, `torrent_client`. Adding a provider is one adapter file + one registration line + tests, with zero service-layer changes. Configured instances live in the unified `service_connections` table; adapters re-read credentials per call. See [Adapters](./adapters) for the contracts and extension pattern.

## Background jobs

Ten jobs run on node-cron (6-field seconds syntax supported). Schedules are defaults; `jobs.schedules` overrides per job, `jobs.disabled` silences non-essential ones. Run history persists in `job_logs` and survives restarts.

| Job id | Default schedule | Essential | Purpose |
|--------|------------------|-----------|---------|
| `queue-poller` | `*/30 * * * * *` (30 s) | yes | Mirror client state through the transition guard; stalled detection; failure backoff/blacklist. |
| `library-organizer` | `*/5 * * * *` | yes | Link completed downloads to pre-existing entities; NFO/artwork. |
| `download-retention` | `0 * * * *` (hourly) | yes | Remove organized torrents past `files.cleanupDays`; files stay. |
| `subscription-search` | `0 * * * *` (hourly) | no | Search wanted requests within the budget rotation. |
| `subscription-refresh` | `0 */6 * * *` | no | Diff monitored titles against TMDB; regenerate requests. |
| `metadata-cache-cleanup` | `5 * * * *` (hourly :05) | no | Prune expired metadata cache entries. |
| `session-cleanup` | `0 * * * *` (hourly) | no | Delete expired sessions. |
| `cleanup` | `0 0 * * 0` (Sun 00:00) | no | Prune job logs, terminal queue rows (>7 d), app logs. |
| `backup` | `0 3 * * 0` (Sun 03:00) | no | Online SQLite snapshot into `/config/backups`; keep newest 7. |
| `disk-monitor` | `*/30 * * * *` | no | Free-space watch on library roots + config dir (warn <15%, critical <5% free). |

Essential jobs **cannot be stopped** (`POST /api/jobs/:name/stop` → 409) and cannot enter `jobs.disabled`. Manual triggers (`POST /api/jobs/:name/trigger`) return the running job immediately — the run continues detached and is polled; triggering a running job is a 409. Manual triggers work even on stopped jobs.

## Response envelope

Every API branch emits the suite envelope — `{ success: true, data }` or `{ success: false, error, code, details? }` with `code` always present. A centralized error handler covers Zod errors, app errors, Fastify-native errors, not-found, and unknowns. The web API client preserves `code`/`details` on thrown errors. See [API reference](./api-reference#response-envelope).

## Web app

The web app is App Router with **thin server-component shells**; views are client components over TanStack Query hooks. All API traffic goes through one catch-all proxy route (`/api/[[...path]]`) with a per-path timeout map (search 240 s, library 120 s, service-connections 90 s, default 30 s) — Next.js rewrites are forbidden because they cannot express per-route timeouts. The API port is never published; the browser only ever talks to the web port. URL parameters carry view state (tabs, filters, pagination, settings `?tab=`).
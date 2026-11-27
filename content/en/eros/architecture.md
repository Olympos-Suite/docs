---
title: "Architecture"
description: "Eros's monorepo layout, lint-enforced server layering, Awilix boot sequence, session/API-key auth, frontend proxy layering, and the eleven background jobs."
section: "Developer Guide"
order: 10
---

Eros is a pnpm + Turborepo monorepo (Node ≥ 24, pnpm 12.7.0): a Fastify 5 API on port 3001, a Next.js 16 + React 19 web app on port 3000, and shared packages. SQLite (better-sqlite3 + Drizzle) is the only database; Zod 4 schemas in `@repo/shared-types` are the single contract source for both apps. This page maps the codebase; pipeline internals live in [Enrichment Pipeline](./enrichment-pipeline) and [Adapters](./adapters), behavior in the User Guide.

## Monorepo layout

```text
apps/web               # Next.js 16 + React 19, App Router (thin page shells), :3000
apps/server            # Fastify 5 API (routes → controllers → services → repositories), :3001
packages/database      # @repo/database — Drizzle schema, migrations 0000–0033, createDatabase
packages/shared-types  # @repo/shared-types — Zod 4 contracts, DTOs, error envelope
packages/typescript-config  # shared tsconfigs (base / nextjs / node)
```

`pnpm-workspace.yaml` covers `apps/*` and `packages/*`. Cross-package imports use workspace names; local imports use the `@/` alias. The web app imports **types only** from `@repo/shared-types` (the single runtime import is `ThemeSchema` for theme validation); the server validates requests with the same schemas via `fastify-type-provider-zod`. Both packages export raw source in dev and compile to `dist/` for Docker.

## Backend layering

Server code follows a strict chain; **no layer may be skipped**:

```text
Routes → Controllers → Services → Repositories → Database (SQLite / Drizzle)
```

- **Routes** — 19 route plugins registering 99 `/api/*` endpoints (plus `/api/health` in `app.ts`); URL templates, Zod schemas, rate limits, no logic.
- **Controllers** — 21 controllers + a `zod-request` helper; thin delegations to injected services, emitting `{success,data}` envelopes or binary streams.
- **Services** — 53 modules in 8 groups (search/downloads, enrichment/identity, megapack, library/dedup/files, quality, entities, platform, utils); all business logic and cross-entity orchestration.
- **Repositories** — 18 domain repositories over a generic `base-repository.ts`; the only code that owns Drizzle queries.

The rule is **lint-enforced** with ESLint `import-x/no-restricted-paths` zones defined in the root `eslint.config.mjs`: routes importing services/adapters/repositories is an `error`; controllers importing the database layer is an `error` except three files downgraded to `warn` (`log-controller`, `job-controller`, `service-connection-controller` — pre-existing type-only DI imports of repository classes plus a runtime adapter-factory call); services importing `drizzle-orm`/`better-sqlite3` drivers is a `warn` pending refactor. Documented runtime exceptions: the `backup.ts` streaming routes resolve `backupService` from `diScope` directly, the setup middleware queries `users` via `app.db`, and several pipeline services take `DbType` for queries no repository method covers (junction upserts, `json_extract` lookups, megapack joins) — deliberate, commented in code. See [Invariants](./invariants).

## Composition root and boot sequence

One composition root (`src/container.ts`) wires everything with **Awilix**, `InjectionMode.PROXY`, constructor injection everywhere. The graph is 80 **lazy registrations** — every `asClass`/`asFunction` entry is `.singleton()`; only `db`, `sqlite`, `jobLoggerFactory`, and the five boot-time adapter snapshots are `asValue`. `bootContainer` runs the IO-bound work eagerly, in order:

1. `createDatabase(dbPath)` (WAL + foreign keys) → `runMigrations` → `seedDatabase` (45 settings defaults) → `seedQualityProfiles`.
2. Register the flat layer block (repositories → services → scheduler → controllers).
3. `createLogger` — the SQLite-backed multistream logger must exist before services/jobs log.
4. Build adapters from active `service_connections` rows and update the `AdapterProvider`.
5. `ensureDefaultPaths` — seed `/downloads` and `/media` path defaults when missing.
6. Apply the `disabled_jobs` setting (essential job ids filtered out defensively).
7. `markStaleRunningAsFailed` — reap zombie job runs from a previous process.
8. **`resolveAllRegistrations`** — smoke-resolve every registration so a wiring mismatch fails loudly at boot, not at first request.

Then `index.ts` runs the **one-shot startup dedup repair** while the `dedup_repair_done` settings flag is unset — after the container, before the app and jobs, so no job can prune repair-relevant rows mid-run (see [Enrichment Pipeline](./enrichment-pipeline)). It reads `log_level`, builds the app, and listens on `0.0.0.0:3001`; SIGINT/SIGTERM close the app gracefully.

`createApp` registers plugins in a fixed order: error-handler → security (helmet/rate-limit/CORS) → database → session → api-logging-hooks → OpenAPI (Swagger UI at `/api/docs`, JSON at `/api/docs/json`) → the 19 route plugins → all jobs. Setup/auth middleware register **last** as `onRequest` hooks; `onReady` re-starts all job schedules and ensures configured paths exist; `onClose` stops the scheduler.

## Auth

Two credential paths, session first:

- **Cookie sessions** — `@fastify/session` with the default in-memory store (the DB `sessions` table was dropped in migration 0016). Cookie: `httpOnly`, `sameSite: 'lax'`, `secure: 'auto'`, 24 h rolling. The secret resolves `SESSION_SECRET` env (≥ 32 chars) → `/config/session.secret` (generated once, mode 0600) → ephemeral with a loud warning. Passwords hash with bcryptjs.
- **API keys** — `eros_` + 32 hex chars, **SHA-256 hashed at rest**, plaintext returned once at creation. Sent as `Authorization: Bearer` or `X-Api-Key`; verification loads the owning user statelessly. Rate limiting buckets per key hash instead of per IP.

A **first-run gate** returns 503 `SETUP_REQUIRED` until an admin exists; the auth guard then 401s everything outside the public allowlist (login/verify/setup/setup-status/health). `/api/docs` is exempt from both gates. API-key management is admin-only. See [API reference](./api-reference) and [Integration](./integration).

## Frontend layering

One direction, no shortcuts:

```text
app/ (thin Server Component pages)
  → features/<domain>/components/*-view.tsx (12 feature modules, Client Components)
    → hooks/ (17 TanStack Query hook modules)
      → lib/api-client.ts (ApiError with code/details; 401 → /login)
        → app/api/[[...path]]/route.ts (catch-all proxy) → Fastify :3001
```

The catch-all Route Handler is the **only** proxy mechanism — Next.js rewrites are forbidden because they expose a single global timeout. Its per-path timeout map allows `discovery/search` **180 s** (Prowlarr multi-indexer fan-out) and defaults everything else to **30 s**; timeouts emit a 504 envelope, an unreachable backend a 502. Session cookies relay via `getSetCookie()`, request bodies stream through, and client disconnects abort the upstream fetch. The API port is never published to the browser.

Page navigation is guarded by `middleware.ts` with a 60 s auth-result cache (fail closed). Filter/pagination/tab state lives in URL params (`useSearchParams` + `commitSearchParams`; nuqs removed). The `QueryClient` defaults to `staleTime` 60 s, retry 1, no refetch-on-focus; most list hooks override to 30 s. Two selectable **dark themes** drive the chrome: `psyche` (OKLCH tokens, default) and `classic` (HSL tokens), switched via `data-theme` on `<html>` — a pre-paint script reads localStorage (`eros.theme`), and the backend `ui_theme` setting wins once loaded. See [Web UI](./web-ui).

## Background jobs

Eleven node-cron jobs run on one scheduler; every job is a thin factory delegating to services, with per-step error isolation and `job_logs` persistence. Schedules are defaults — each job reads a `<job>_cron` settings override (`JOB_SETTINGS_KEYS` is the single name↔key map), and edits restart the live cron without a process restart. Both cron ticks and manual runs **skip silently when the job is already running** (no overlap); manual runs set a marker jobs can read to relax policy.

| Job | Default cron | Essential | Purpose |
|-----|--------------|-----------|---------|
| `torrent-progress-sync` | `*/2 * * * *` | yes | Mirror client state into the queue; stall detection + optional auto-removal. |
| `early-dedup` | `*/30 * * * *` | yes | Mid-download OSHASH for megapack files and active singles; duplicates torn down. |
| `download-completion` | `*/5 * * * *` | yes | Process megapacks, guarantee hashes, enrich, NFO/posters/previews, organize, quality upgrades. |
| `torrent-retention` | `*/15 * * * *` | yes | End seeding after `seed_time_hours` (72 h default), keep files; three folder sweeps. |
| `subscription-search` | `0 0 * * *` | no | Full subscription automation cycle (daily 00:00). |
| `torrent-health` | `*/30 * * * *` | no | Group-fallback retries of failed downloads through sibling releases. |
| `metadata-refresh` | `0 3 * * *` | no | Retry up to 50 scenes; backfill studio banners / performer tags. |
| `file-sync` | `0 */2 * * *` | no | Library reconciliation: folders, quality, sizes, import, dedup, orphan audit. |
| `cleanup` | `0 0 * * 0` | no | Prune job/app logs and terminal queue rows; orphaned download sweep. |
| `backup` | `0 3 * * 0` | no | SQLite file-copy backup; keep the 7 newest. |
| `disk-monitor` | `*/30 * * * *` | no | Free-space thresholds per configured path (warn ≤ 15%, critical ≤ 5%). |

The four **essential** jobs are the core download pipeline: they always start and cannot be stopped via `disabled_jobs` or the stop endpoint. The other seven are disableable through the persisted `disabled_jobs` JSON array; disabled jobs stay registered (status `idle`) and can be started explicitly. See [Configuration](./configuration) for the tuning keys.

## Response envelope

Every API branch emits the suite envelope — `{ success: true, data }` or `{ success: false, error, code, details? }` with `code` always present. The centralized error-handler plugin maps Zod/app/Fastify errors onto the shared `API_ERROR_CODES` taxonomy; the web `api-client` preserves `code`/`details` on thrown `ApiError`s, and the proxy emits the same envelope for gateway failures. See [API reference](./api-reference).

## Process model

The Docker image is a multi-stage build (deps → builder → prod-deps → runner); the entrypoint starts as root, creates the `eros` user from PUID/PGID, chowns the mounts, and drops privileges. The runtime CMD is a dependency-free Node supervisor (`docker/supervisor.mjs`) that spawns `next start` and the compiled `node dist/index.js` as direct children, forwards SIGTERM/SIGINT with a 10 s grace period, and **exits non-zero as soon as either child dies** — the compose restart policy recovers the container. The server always runs compiled output, never `tsx`, in production. Standard mounts: `/config` (database + session secret — the only volume that needs backing up), `/data`, `/downloads`, `/media`. See [Installation](./installation).
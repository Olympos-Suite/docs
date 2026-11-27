---
title: "Testing"
description: "Eros's test stack: the 127-file server Vitest suite, web unit tests, sequential Playwright e2e, monorepo commands, lint layering gates, and CI."
section: "Developer Guide"
order: 70
---

Eros tests with **Vitest** (server + web) and **Playwright** (web e2e). The server suite is the safety net: **127 test files** covering every layer, run against real migrated SQLite databases and a booted Fastify app. Toolchain baseline: Node ≥ 24 (`engines`), pnpm 12.7.0 (`packageManager`), Turborepo orchestrating the workspace.

## Test stack

| Package | Runner | Config | Scope |
|---------|--------|--------|-------|
| `apps/server` | Vitest, node env, globals | `vitest.config.ts` — includes `src/**/*.test.ts` + `__tests__/**/*.test.ts`, setup file `__tests__/setup.ts`; coverage v8 (`text`/`json`/`html`), excludes `index.ts`, `types/`, `jobs/` | 127 files in a dedicated `__tests__/` tree (not colocated). |
| `apps/web` | Vitest, node env, explicit imports | `vitest.config.ts` — includes `src/**/*.test.ts`, `@/` alias | Unit tests for the HTTP boundary: `api-client.test.ts` pins error-envelope parsing (`ApiError` keeps `code`/`details` across the transport). |
| `apps/web` e2e | Playwright (chromium) | `playwright.config.ts` — `testDir: ./e2e`, sequential (`fullyParallel: false`, `workers: 1`), 60 s timeout, html reporter | 15 spec files against a running stack; `baseURL` `http://localhost:9697` (`E2E_BASE_URL` override). |

`packages/database` and `packages/shared-types` have no test scripts of their own — their contracts are pinned from the server suite: `__tests__/database/` (connection pragmas, indexes, migration runner, migration 0016), `__tests__/shared-types/` (api-envelope, add-download and studio schemas), and `__tests__/domain/` (entity schemas).

The server suite by layer:

| Area | Files | Area | Files |
|------|-------|------|-------|
| services | 52 | plugins | 4 |
| controllers | 20 | database | 4 |
| repositories | 15 | shared-types | 3 |
| jobs | 12 | lib | 3 |
| adapters | 8 | middleware | 2 |
| routes / domain / helpers / container | 1 each | | |

## Commands

From the repository root (Turborepo runs every package that defines the script):

| Command | What it runs |
|---------|--------------|
| `pnpm test` | `turbo test` — server + web Vitest suites (uncached). |
| `pnpm typecheck` | `turbo typecheck` — `tsc --noEmit` per package. |
| `pnpm lint` | `turbo lint` — ESLint flat config, including the server layering zones. |
| `pnpm build` | `turbo build` — server `tsc`, web `next build`, package builds. |
| `pnpm db:generate` / `pnpm db:migrate` | drizzle-kit migration authoring (migrations still auto-apply on boot). |

Per-package:

```bash
pnpm --filter @repo/server test            # vitest run (full server suite)
pnpm --filter @repo/server test:watch      # vitest watch mode
pnpm --filter @repo/server test:coverage   # vitest run --coverage (v8)
pnpm --filter @repo/web test               # web unit tests
pnpm --filter @repo/web test:e2e           # playwright test (needs a running stack)
pnpm --filter @repo/web test:e2e:ui        # playwright --ui
```

Focused runs — pass a file filter or name pattern straight through to Vitest:

```bash
pnpm --filter @repo/server test __tests__/services/scene-service.test.ts
pnpm --filter @repo/server test -t "soft delete"
```

Dev setup is `corepack enable && pnpm install && pnpm dev` (web :3000, server :3001). Before opening a PR, `pnpm build` must pass clean and the suite must be green; add tests for any service/controller/adapter logic you introduce.

## Writing tests

Follow the existing helpers in `apps/server/__tests__/helpers/`:

- **Real database, in memory** — `createTestDb()` opens `:memory:` SQLite with WAL + foreign keys, then runs the **actual migration runner and seeds** (`runMigrations`, `seedDatabase`, `seedQualityProfiles`). Schema tests exercise the same DDL production boots with. `seedAdmin()` creates known credentials for auth flows.
- **Booted app, no network** — `buildTestApp()` assembles the Fastify app through the real container (temp paths, overrideable dependencies); route/controller tests use Fastify's `inject`. `closeTestApp()` tears it down.
- **Mind the fire-and-forget** — services kick off background work (enrichment, upserts) that can hit constraint errors after a test ends; `__tests__/setup.ts` suppresses exactly those `SQLITE_CONSTRAINT`/unique/not-null rejections and rethrows anything else.
- **Pin the contracts** — envelope codes, settings keys, status vocabularies, and schema constraints are asserted verbatim (`__tests__/shared-types`, `__tests__/database`). Changing one is a deliberate contract change: update the pin and the docs together.
- **Test the guards** — auth/setup gates, essential-job stop refusal, soft-delete/restore, dedup and blacklist checks all have dedicated negative tests; new behavior needs the same.

## Lint and typecheck

`pnpm lint` is a layering gate, not just style: `import-x/no-restricted-paths` zones make routes→services/adapters/DB and controllers→DB imports **errors** (three legacy controllers sit at `warn`), and services importing `drizzle-orm`/`better-sqlite3` drivers directly are flagged. See [Invariants](./invariants) for the zone rules and documented exceptions. `pnpm typecheck` runs strict `tsc --noEmit` in every package.

## CI gates

`.github/workflows/ci.yml` runs on every push to `main`, every PR, and `v*` tags. The `check` job (20-minute timeout) runs sequentially:

```text
pnpm install --frozen-lockfile → typecheck → lint → test → build
```

Node 24 is installed explicitly; pnpm comes from `packageManager` via `pnpm/action-setup`. The `docker` job runs **only on `v*` tags** after `check` passes: buildx builds and **pushes** the image to GHCR (`ghcr.io/<repo>:<tag>` — repository names must be lowercased for GHCR), with GitHub Actions cache.

## End-to-end tests

Playwright e2e is **deliberately outside CI** — it needs a running stack (web + server + database). Bring the stack up (the compose file exposes the web UI on `:9697`), then:

```bash
pnpm --filter @repo/web test:e2e
```

The suite is **sequential by design** (`workers: 1`, no parallelism): specs build ordered state across auth, dashboard, discovery, downloads, scenes, performers, studios, subscriptions, quality profiles, jobs, settings, service connections, torrent blacklist, and backup flows. `e2e/global-setup.ts` waits for `/api/health` and creates the admin account via `/api/auth/setup` if the instance is fresh. Failures capture screenshots and first-retry traces; the html reporter summarizes the run. Override the target with `E2E_BASE_URL` when the stack lives elsewhere.
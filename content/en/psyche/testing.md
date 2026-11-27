---
title: "Testing"
description: "Psyche's test stack: Vitest with v8 coverage, colocated test files, the monorepo commands, and the CI gate sequence."
section: "Developer Guide"
order: 70
---

Psyche tests with **Vitest 5** across the monorepo, with `@vitest/coverage-v8` on the server. Test files live **alongside source** (`*.test.ts` / `*.test.tsx`) — there is no separate test tree. Every package with behavior has a `test` script; Turborepo pipelines them.

## Test stack

| Package | Runner | Config | Scope |
|---------|--------|--------|-------|
| `apps/server` | Vitest, node env | `vitest.config.ts` — includes `src/**/*.test.ts`; coverage v8, reporters `text` + `lcov`, tests excluded from coverage | ~70 test files: container boot, envelope, routes, services, repositories, adapters, jobs. |
| `apps/web` | Vitest, node env | `vitest.config.ts` — includes `src/**/*.test.{ts,tsx}`, `@/` alias resolved | Unit tests for lib utilities (URL params, API proxy, formatting, status vocabularies) and hooks/components. |
| `packages/database` | Vitest | per-package | Schema constraints, migrations, `createDatabase` pragmas. |
| `packages/shared-types` | Vitest | per-package | Settings registry pins (keys, defaults, ranges), DTO contracts, mapping functions. |

Coverage is server-focused:

```bash
cd apps/server
pnpm test:coverage    # vitest run --coverage (v8 provider)
```

The run prints a text summary and writes an `lcov` report for tooling; test files themselves are excluded from the measured source.

## Commands

From the repository root (Turborepo orchestrates all packages):

| Command | What it runs |
|---------|--------------|
| `pnpm test` | `turbo test` — every package's Vitest suite. |
| `pnpm typecheck` | `turbo typecheck` — `tsc` across all packages. |
| `pnpm lint` | `turbo lint` — ESLint 9 flat config, including the server layering rules. |
| `pnpm build` | `turbo build` — server `tsc`, web `next build`, package builds. |

Per-package, `pnpm test` runs `vitest run` and `pnpm dev` runs watch mode (`tsx watch` for the server, `next dev` for the web). The server also exposes `test:coverage`; the database package exposes `db:generate` / `db:migrate` (drizzle-kit) for migration authoring — migrations still auto-apply on boot.

## What is covered

The suite pins the invariants mechanically, not just behaviorally:

- **Boot & wiring** — `container.test.ts` exercises the composition root and smoke-check; job scheduler tests cover registration, stale-run finalization, and essential-job guards.
- **Envelope & errors** — the error-handler plugin tests assert `{ success, error, code }` on every failure branch (Zod, app, native, not-found, unknown).
- **Contracts** — shared-types tests pin the settings registry (exact key set, defaults, ranges, the absence of removed keys like `tmdb.api_key`), quality-profile vocabulary, and the download status transition map.
- **Domain services** — subscriptions, release requests (sentinel dedup, pack supersession), search fan-out (isolation, mute, dedup), scoring (formula pinned by tests), queue poller (backoff, grace window, blacklist), organizer (linkage, partial packs, naming).
- **Adapters** — contract behavior per provider, capability declarations, and error sanitization (no secrets/URLs in messages).
- **Schema** — XOR constraint, cascades, unique indexes, WAL/foreign-key pragmas, and migration behavior.
- **Layering** — `pnpm lint` fails on restricted imports (routes→services/repositories/adapters, controllers→repositories/DB). See [Architecture](./architecture#layering).

When adding an adapter, the contract tests are part of the required one-file + one-registration + **tests** pattern — see [Adapters](./adapters#adding-an-adapter).

## Writing tests

The codebase is shaped for testability; follow the existing patterns:

- **Narrow structural dependencies.** Services accept `Pick<Repository, …>` views or small interfaces, not concrete classes — tests pass object literals with just the methods they exercise. Job factories take their dependencies as arguments (the backup job accepts a fake `DatabaseBackuper`; the scheduler tests inject clocks).
- **Container overrides.** `createAppContainer` accepts `configDir`/`dataDir` (tests use temp dirs), a custom `settingsDefinitions` set, and a logger override; `buildApp` accepts `logger: false`. Route tests use Fastify's `inject` against a booted app — no network needed.
- **Pin the constants.** Schedules, score weights, seeded profiles, the settings key set, and the status transition map are asserted verbatim in tests. Changing one of these is a deliberate contract change: update the pin and the docs together.
- **Test the guards, not just the happy path.** Illegal status transitions, essential-job stop attempts, duplicate grabs, name collisions, and sentinel dedup all have dedicated negative tests — new behavior needs the same.

## CI gates

`.github/workflows/ci.yml` runs on every push and PR, sequentially:

```text
typecheck → lint → test (vitest) → build
```

Node 24 and pnpm 12.7.0 are installed explicitly (corepack avoided); dependencies install with `--frozen-lockfile`. The Docker image job runs **only on `v*` tags**, after the pipeline passes (buildx, no push — publishing is a separate release step).

## E2E status

The spec reserves **Playwright** for web end-to-end tests (critical flows: login → library → discover → subscribe → wanted → search → grab → organize), running locally/out-of-CI by design. That suite belongs to the Phase-7 hardening work and is **not shipped yet** — the current repo has no Playwright dependency or e2e directory. Until it lands, the Vitest suites plus the CI gates are the whole automated safety net; don't claim e2e coverage in reviews.
---
title: "Architecture"
description: "The two-image topology, monorepo layout, vendored ffmpeg rationale, image-size gates, storage layout, and boot wiring."
section: "Developer Guide"
order: 10
---

Morpheus is a pnpm + Turborepo monorepo (Node ≥ 24, pnpm 12.7.0 pinned): a Next.js App Router web app, a Fastify 5 API with better-sqlite3 + Drizzle, Zod contracts in a shared package, and a standalone worker engine shared by the headless and embedded workers. This page maps the shape; the behavioral contracts live in [Worker protocol](./worker-protocol), [Transcode engine](./transcode-engine), and [Verification internals](./verification-internals).

## Two images, one engine

| Image | Runs | Why |
|-------|------|-----|
| `morpheus` (management) | Web (3000) + API (3001) under a supervisor, embedded worker in-process | Suite-standard single web+API image; the embedded worker makes one container sufficient |
| `morpheus-worker` | Headless worker entry only — no UI, no published ports | Recorded deviation A.12 #1: transcode capacity scales horizontally without duplicating the management stack |

The supervisor (`docker/supervisor.mjs`) runs the compiled API (`dist/index.js` — never tsx) and the web standalone server, prefixes their output, forwards signals with a 10 s grace before SIGKILL, and **exits when either child dies** so the restart policy brings the whole app back. The embedded worker needs no supervisor change — it lives inside the API process.

The **transcode engine is shared code** (`apps/server/src/worker/`): the headless entry (`worker.ts`) and the embedded worker run the same claim loop, budget logic, and ffmpeg runner. The embedded worker talks to the loopback API with its own key (stored 0600 under `/config`); a dedicated worker talks to the same protocol over the network. There is no second implementation to drift.

```text
                        management container (morpheus)
 ┌──────────────────────────────────────────────────────────────┐
 │  supervisor ── web :3000 ── /api proxy ──► API :3001          │
 │                                             │                │
 │   SQLite (/config) ◄── services ◄───────────┤                │
 │   verify + replace ◄── accept seam ◄────────┤                │
 │   embedded worker ── loopback API ──────────┘                │
 └──────────────────────────────────────────────────────────────┘
        ▲  register / claim / heartbeat / transfers (HTTP, API key)
        │
 ┌──────┴─────────┐   ┌────────────────┐   ┌────────────────┐
 │ morpheus-worker│   │ morpheus-worker│   │ remote worker  │
 │ cpus: 2        │   │ cpus: 4        │   │ (LAN, published│
 │ (GPU optional) │   │                │   │  API port)     │
 └────────────────┘   └────────────────┘   └────────────────┘
```

## Monorepo layout

| Path | Responsibility |
|------|----------------|
| `apps/web` | Next.js App Router; thin Server Component shells, logic in `src/features/<domain>/components/*-view.tsx`; single catch-all `/api` proxy with a per-path timeout map (never Next rewrites) |
| `apps/server` | Fastify API: routes → controllers → services → repositories; Awilix DI; the worker engine under `src/worker/` and the headless entry `src/worker.ts` |
| `packages/shared-types` | The API contract: Zod schemas for every endpoint, settings registry + defaults, error taxonomy, zod-free codes for the client bundle |
| `packages/database` | Drizzle schema + migrations; `createDatabase` (WAL + foreign keys) and `migrateDatabase` |
| `packages/typescript-config` | Shared strict tsconfigs |
| `docker/` | Both Dockerfiles, entrypoint (PUID/PGID drop), supervisor, compose example |

## Vendored ffmpeg

Both images vendor the **same pinned BtbN FFmpeg-Builds GPL artifact** at build time, installed to `/usr/local/bin/ffmpeg` (PATH-shadows the distro binary, which stays as an explicit-path fallback; ffprobe stays distro). A build-time gate fails the image if the binary lacks the libvmaf filter. The reasons differ per image:

- **Management:** Debian ships no libvmaf package — the vendored build is what makes the optional VMAF gate possible at all (A.12 #5).
- **Worker:** the probe-passed vendored path prevents Blackwell NVENC misdrive on RTX 5060 Ti-class hardware (A.12 #10) — the distro build misdrives the encoder; the pinned build does not.

## Image size budgets

The D.3 budgets are **targets, not achieved sizes**:

| Image | Budget | Actual (Phase 0–1) |
|-------|--------|--------------------|
| Management | ≤ ~800 MB | ~1.14 GB |
| Worker | ≤ ~500 MB | ~1.08 GB |

The vendored ffmpeg costs ~139 MB (management) / ~173 MB (worker) over budget. CI enforces the budgets at **warning level** (`::warning` above them) and a **hard fail above 2 GiB**. Budget levers (a minimal ffmpeg build) are planned, not shipped — do not document the targets as current sizes.

## Storage layout

| Location | Contents |
|----------|----------|
| `/config` | SQLite DB, settings, session secret, embedded worker API key (0600), default embedded staging (`worker-staging/`). **The only backup-worthy volume.** |
| `/data/...` | Archive roots (operator mounts) |
| `<root>/.morpheus-staging/` | Per-attempt staging outputs: `<jobId>.a<attempts>.mkv` |
| `<root>/.morpheus-trash/` | Hard-linked replaced originals, purged by mtime after `trash_retention_days` |
| `/data/.morpheus-gpu` (management) / `/app/.morpheus-gpu` (worker) | Runtime NVIDIA encoder cache — deliberately **outside `/config`** so config backups stay lean |

## Layering and DI

HTTP handling follows a strict chain, enforced mechanically by ESLint `import-x` zones: **Routes → Controllers → Services → Repositories → Drizzle**. A route never touches a repository; SQLite is accessed only through Drizzle. Awilix runs in `InjectionMode.PROXY` with constructor injection and singleton registrations — one composition root (`container.ts`). Background work uses exactly one pattern: registered `JobDefinition`s (in-process like `library-scan`, or worker-claimed like `transcode`), scheduled by node-cron (`lease-sweep` every minute, `trash-purge` daily).

## Boot sequence

The API boots in this order: logger → database + migrations → container registrations → session secret → settings defaults seed → **`finalizeStaleJobs`** (mode-aware: in-process runs finalized as failed, worker rows requeued under the attempts cap) → **staging orphan cleanup** → estimator backfill (idempotent, machine-managed marker) → a smoke-check resolving every registration so wiring failures surface at startup → scheduler + embedded worker (settings-gated) → listen. See [Verification internals](./verification-internals) for the orphan-cleanup contract and [Database](./database) for the schema.
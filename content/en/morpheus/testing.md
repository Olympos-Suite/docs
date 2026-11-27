---
title: "Testing"
description: "Vitest layout and counts, the key protocol and verification suites, real-toolchain guards, local-only Playwright, and the CI pipeline."
section: "Developer Guide"
order: 80
---

Server and package tests run on **Vitest** with `@vitest/coverage-v8`; the web e2e suite is Playwright, kept local-only (A.10). Every package defines real `lint`, `typecheck`, `test`, and `build` scripts — a silent no-op task is a bug.

## Commands

```bash
pnpm test                     # vitest for server + packages (web e2e excluded)
pnpm --filter @repo/server test          # single package (vitest run)
pnpm --filter @repo/server test:watch    # watch mode
pnpm --filter @repo/server exec vitest run src/tests/worker-protocol.test.ts   # single file
pnpm --filter @repo/server exec vitest run --coverage    # coverage-v8 report
pnpm typecheck && pnpm lint && pnpm test && pnpm build    # full chain (CI order)
```

Server tests live in `apps/server/src/tests/`, built on a real-container harness (`helpers/test-app.ts`) with repo-local scratch dirs, fake ffprobe/ffmpeg adapters, and job-polling helpers — most suites run the actual Awilix container against a real SQLite DB, not mocks of the services.

## Test counts

Snapshot after the Phase 4 fixes (2026-11-15 owner-approved changes: VMAF gate, decode thread cap, ffmpeg pin):

| Package | Passed | Skipped |
|---------|--------|---------|
| `@repo/server` | 618 | 8 |
| `@repo/shared-types` | 305 | 8 |
| `@repo/database` | 17 | 8 |

The skips are the **ffmpeg-gated real-toolchain suites** — they skip locally without the binaries and run in CI, where runners ship both ffmpeg and ffprobe with loud guards (a missing binary fails CI loudly rather than silently skipping).

## Key suites

| File | Covers |
|------|--------|
| `transcode-flow.test.ts` | E2E: enqueue → claim → upload → verification → atomic replace (fake toolchain) |
| `transcode-flow-real.test.ts` | The same flow with real ffmpeg/ffprobe (gated) |
| `worker-protocol.test.ts` | Register/claim/heartbeat/progress/fail contract, long-poll hold, lease semantics |
| `two-worker-requeue.test.ts` | Crash → lease expiry → requeue → second worker restarts from scratch |
| `lease-sweep.test.ts`, `priority-claim.test.ts` | Sweep requeue, priority order, re-rank piggyback |
| `vmaf-gate.test.ts`, `vmaf-enqueue.test.ts` | Gate 7 fail-closed semantics, score parsing, payload freezing |
| `verify-threads.test.ts` | 13 fixtures for the auto thread formula (cgroup v1/v2, cpuset, RAM ceiling) |
| `verify-decode-mode.test.ts`, `decode-budget.test.ts` | full/light/off modes, scaled budgets, watchdog branch |
| `verify-serialization.test.ts`, `verify-replace-failure.test.ts` | Single-flight FIFO, failure paths keep the original |
| `embedded-worker-toggle.test.ts` | 4 tests: off→on cycle, boot-disabled→runtime-enable, unrelated change no-churn, mid-job disable→retryable requeue |
| `worker-gpu.test.ts` | GPU detection and runtime provisioning/artifacts |
| `hw-dispatch.test.ts`, `mount-mode.test.ts` | Capability-aware dispatch, mount mappings and output-mounted seam |
| `rule-assignment.test.ts`, `rule-resolution.test.ts`, `bulk-enqueue.test.ts` | Ruleset chain, immediate enqueue, skip reasons, bulk runs |
| `settings.test.ts`, `calibration.test.ts`, `estimate-h265.test.ts` | seedDefaults/getAll/update, calibration blob protection, estimator formulas |
| `staging-orphan-cleanup.test.ts`, `trash.test.ts`, `watchdog.test.ts` | Boot cleanup ordering, retention purge, wall-clock watchdog |

## Real-toolchain guards

Suites that need real binaries (`transcode-flow-real`, `ffmpeg-capabilities-real`, the CPU-budget spike under `tests/spike/`) check for ffmpeg/ffprobe at startup: locally they skip with a clear reason; in CI a loud guard fails the run if the binaries are missing, so the gated coverage can never silently disappear. The fake adapters everywhere else are scripted, not heuristic — tests assert exact argument sequences (the frozen ffmpeg blocks are a regression guard).

## Playwright (local only)

Web e2e stays out of CI (A.10). Run it locally with both dev servers up and a fresh `CONFIG_DIR`:

```bash
pnpm --filter @repo/web exec playwright test    # needs: playwright install
```

Browsers can live anywhere via `PLAYWRIGHT_BROWSERS_PATH`.

## CI pipeline

Order: **typecheck → lint → vitest → turbo build**, then the image builds with size gates:

- `::warning` when an image exceeds its D.3 budget (~800 MB management / ~500 MB worker) — warning-level, because the vendored ffmpeg currently puts both images over budget (~1.14 GB / ~1.08 GB).
- **Hard fail above 2 GiB** for either image.
- The vendored-ffmpeg build gate (libvmaf filter present) fails the image build itself, before any size check.
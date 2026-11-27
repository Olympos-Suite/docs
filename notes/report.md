# Olympusuite Repository Report

## Suite Theme & Cross-App Relationships

**Naming theme:** All repos use single lowercase Greek mythology words: Zephyrus (west wind), Eros (love), Psyche (soul), Morpheus (dream forms). Metaphorical: Zephyrus carries data without being the hero; Morpheus changes file form without changing substance.

**Suite topology:** One repo per app (Sonarr/Radarr model), each with its own pnpm + Turborepo monorepo (`apps/web`, `apps/server`, `packages/*`). Shared code is replicated per-repo, not imported across apps.

**Ports:** Internal web `3000` + API `3001` per app; only web port published to host. Host mappings: Eros `9697:3000`, Psyche `9698:3000`, Morpheus TBD, Zephyrus `3030`.

**Integration model:** Applications (Eros, Psyche) add torrents directly to their torrent clients. Zephyrus adopts via `managed_groups` scan — it never adds/removes torrents never touches files. Group naming convention (`eros`, `psyche`) is the only contract. Morpheus manages compression workers via long-poll protocol.

**Shared stack baseline (all apps):** Node >=24, pnpm 12, Turborepo, TypeScript 5.7, ESLint 9 flat config, Prettier 3, Zod v4, Drizzle ORM + better-sqlite3, Fastify 5, Awilix DI, Tailwind v4 + shadcn/ui new-york, lucide-react, Pino, Vitest + Playwright. Docker: multi-stage, gosu user-drop, `/config` (DB+settings), `/data` (app data).

---

## Zephyrus (deep detail)

**Purpose:** Olympusuite's torrent download-phase policy service. Client-agnostic adapter layer that centrally applies smart queueing, prioritization, weekly bandwidth scheduling, and stalled-torrent management to a single torrent client connection. **Optional layer** — no suite app depends on it; it never adds/removes torrents, never touches files, holds zero domain knowledge (torrent + group + client state only).

**Tech stack:** TypeScript (strict), Node 22, Fastify 5, better-sqlite3 + Drizzle ORM + migrations (WAL mode, foreign keys), Zod, node-cron, pnpm single package (no monorepo). Test: Vitest (350 tests). Frontend: React + Vite + Tailwind, served statically by Fastify.

**Structure overview:**
- `src/core/types.ts` — canonical states, snapshots, capabilities, action kinds (single source imported by all layers)
- `src/core/policy/` — pure engine: `policy-engine.ts` composition (pauses before resumes; queue resumes before stalled retries) + schedule/queue/stalled/unmanaged modules
- `src/config/` — Zod schema + YAML loader with `env:NAME` resolution; auto-creates default config when file missing
- `src/adapters/torrent-client.ts` — client-agnostic `TorrentClient` type with type-level mutation ban (add/delete/rename/setCategory forbidden)
- `src/adapters/qbittorrent/` — qBit 5.x adapter: WebUI API v2, cookie auth, incremental sync via `rid`, stop/start/reannounce/limits, state mapping, backoff
- `src/adapters/mock/` — scriptable in-memory `TorrentClient` for integration tests
- `src/db/` — Drizzle schema, WAL/FK db open + migrations, `torrents` + `action_log` repositories
- `src/services/` — `orchestrator.ts` (poll loop, write-ahead, degraded, safe mode, boot adoption sweep), `config-service.ts`
- `src/http/` — routes → controllers → services → repositories (layering mandatory); `plugins/auth.ts` bearer token; `dto.ts` pinned API shapes
- `src/app.ts`, `src/index.ts` — Fastify assembly + boot/shutdown wiring
- `web/` — React dashboard (Vite + React 19 + Tailwind v4 + shadcn/new-york, dark-only), nested package not a workspace member
- `drizzle/` — generated SQLite migrations
- `Dockerfile`, `docker-entrypoint.sh`, `docker-compose.yml` — multi-stage, PUID/PGID drop, volumes `/data` + `/config`, healthcheck `GET /api/status`
- `config.example.yaml` — single config file mirroring spec §7
- `Zephyrus.md` — authoritative Turkish spec (569 lines)
- `AGENTS.md` — invariants, commands, stack, code conventions

**Features/modules inventory:**
- **Smart kuyruklama (Smart queuing):** `global.max_active_downloads` + per-group limits (`groups.<ad>.max_active_downloads`). Started set = `downloading` + `checking` + `queued` (managed) + `stalled`. Limit enforcement: when exceeded, lowest priority (then newest) torrent paused (`pausedByUs=true`). Slot boosaldığında priority sırasına göre resume.
- **Önceliklendirme (Prioritization):** Resume sıralaması: 1) grup ağırlığı (`groups.<ad>.weight`, yüksek önce), 2) torrent yaşı (FIFO, eski önce). Kullanıcı manuel önceliği (`pin`) via `POST/DELETE /api/torrents/:infoHash/pin` — pinned torrent'ler kuyruk tavanlarınca asla duraklatılmaz. Pin, `queueResumedAt` çapasıyla 2×pollluk grace penceresi boyunca slotunu tutar.
- **Haftalık program (Weekly schedule):** Gün+saat penceresi bazlı hız profilleri (`full` = limitsiz, `limited` = belirtilen dl/ul değerleri yönetilen torrent'lerin **toplam** bant genişliği tavanı, eşit bölünür). Gece yarısını aşan pencereler desteklenir (`22:00 → 06:00`). Hız birimleri: düz sayı = KiB/s (15000 = 15 MiB/s), `kb`/`kbps`/`kbit` = bit (1000 tabanı, ÷8), `KB`/`KiB`/`MB`/`MiB`/`GB`/`GiB` = bayt (1024 tabanı). Profile hızları save→load kaybızdır.
- **Stalled yönetimi:** Stalled tanımı: istemcinin `state === 'stalled'` sinyali (qBit `stalledDL`). `stalled.threshold_minutes` boyunca aralıksız stalled kalan torrent: duraklatılır (`pausedByUs=true`). Retry döngüsü: `interval_minutes × backoff_multiplier^(retry sayısı)`, `max_interval_minutes` (24h) ile sınırlandırılır. Anlamlılık eşiği orantılı: `min(progress_reset_bytes, kalanın yarısı)`, en az 1 bayt. `give_up_hours` (varsayılan 72h) ardından uyarı log + givenUp bayrağı; aktif indirme/kuyruga girmiş bekleyen/stalled+slot bekleyeni yokken son çare olarak devam edilir. Completion bias (bitmeye yakınlık): `stalled.completion_bias` blokları (tiers: %50-90, %90-99, ≥%99) — progresi aşan en yüksek basamak uygulanır, give_up_multiplier × pes süresi, max_retry_interval_minutes küçülür, givenUp torrent meşgulken bile retry (unpark).
- **Adoption sweep (başı starttaki süpürme):** Açılış başarılı değerlendirmede, Zephyrus'un daha önce duraklatmadıkları yönetilen başlatılmış-faz torrent'ler `queue` gerekçesiyle duraklatılır; ardından standart tavan + weight/FIFO ile ilk N başlatılır. qBit kuyruğu ile birlikte: qBit max_active_downloads açık kalabilir, Zephyrus decided how many torrent'ler başlatılır; qBit kuyruğu hangilerinin gerçekten aktif indireceğine karar verir.
- **Web arayüzü:** Durum sayfası (istanne bağlantısı + tipi + yetenekler, yönetilen torrent listesi, hız), eylem günlüğü, yapılandırma formu. Login: token girişi (tek alan). Teknoloji: React + Vite + Tailwind, Fastify tarafından statik servis edilir, koyu tema varsayılan.
- **Yönetim API'si (Fastify 5, `/api` önkü):** bearer token auth (`Authorization: Bearer <ZEPHYRUS_TOKEN>`):
  - `GET /api/status` — bağlantı durumu, yetenekler, torrent sayısı (grup/durum bazında), degraded info
  - `GET /api/torrents` — yönetilen torrent'ler: durum, pausedByUs, pauseReason, aktif limitler (paused torrentlerde null), retry bilgisi (retryCount, lastRetryAt, givenUp), pinned
  - `POST /api/torrents/:infoHash/pin` — kullanıcı manuel öncelik (pin), 204; bilinmeyen → 404
  - `DELETE /api/torrents/:infoHash/pin` — pin'i kaldır, 204; bilinmeyen → 404
  - `GET /api/config` — aktif yapılandırma (gizli alanlar maskeli `***`)
  - `PUT /api/config` — yapılandırma güncelle (Zod doğrulamalı; hot-reload; config.yaml'a atomik yaz; diskteki `env:NAME` referansı aynen korunur)
  - `GET /api/actions` — action_log, son eylemler

**Existing docs summarized:**
- `Zephyrus.md` — complete build specification (569 lines, Turkish), covers philosophy (§2, 6 invariants), scope (§3, §4 banned actions), architecture (§4 diagram, §5 adapter interface), policy engine (§6: smart queuing §6.1, prioritization §6.2, stalled §6.3, schedule §6.4), client-agnostic design, acceptance criteria (§13)
- `AGENTS.md` — invariants (§2–§3, 11 non-negotiable rules), stack (§11), code conventions, config/runtime facts, testing expectations, repo map referencing `codemap.md`
- `codemap.md` — project responsibility, system entry points (`src/index.ts`, `src/app.ts`), design (pure policy engine + adapter boundary + qBittorrent adapter + client=source-of-truth + auth + ownership via managed_groups + pausedByUs write-ahead), flow (orchestrator poll → reconcile → engine → write-ahead → execute → persist → action_log → schedule), integration (HTTP API, web dashboard, Eros/Psyche adoption via groups), testing (350 tests: engine 133, qBit adapter 55, orchestrator+API+setup 46, config/db 51)
- `config.example.yaml` — full configuration template with all sections (client, timezone, global, groups eros/psyche with max_active_downloads+weight, stalled with retry/backoff/progress_reset/give_up/completion_bias/slow, schedule with profiles night_limited + windows, server port 3030)
- `design-specs.md` (in eros) — references Zephyrus group conventions but focuses on UI patterns

**Config/env/ports/commands:**
- `config.yaml` single file (or `ZEPHYRUS_CONFIG` env override); env overrides use `env:NAME` prefix (e.g. `password: env:QBIT_PASSWORD`); validated with Zod at startup
- `ZEPHYRUS_TOKEN` env — bearer token for HTTP API; required in production; unset = auth disabled + startup warning
- `QBIT_PASSWORD` — referenced via `env:QBIT_PASSWORD` from environment
- Default port: **3030**; healthcheck: `GET /api/status` (must report "degraded" not crash when client unreachable)
- Docker: multi-stage, volumes `/data` (SQLite) + `/config` (config.yaml), healthcheck `GET /api/status` with token header
- Commands: `pnpm dev` (tsx watch src/index.ts, auto-creates ./config.yaml on first run), `pnpm build`/`start`, `pnpm test`/`test:watch` (350 Vitest), `pnpm typecheck` (tsc --noEmit), `pnpm db:generate`/`db:migrate` (drizzle-kit, migrations auto-apply on boot)

**Cross-app relationships:**
- **Managed groups:** `config.groups` keys (`eros`, `psyche`) are the only torrent groups Zephyrus manages. Other groups/groupless torrents are untouchable. If a torrent's group is removed from config, it becomes unmanaged and is resumed if paused by Zephyrus.
- **No domain logic:** Zephyrus knows only: torrent + group + client state. It does not know metadata, scenes, seed counting, removal timing.
- **Adapter pattern:** New clients (Transmission, Deluge etc.) require only a new adapter file; policy engine and tests are `client.type` independent. Interface `TorrentClient` bans add/delete/rename/setCategory at type level.
- **Eros/Psyche integration:** Eros and Psyche add torrents directly to their clients. Zephyrus adopts via group scan — it discovers managed torrents and applies policy. The only contract: group naming convention.
- **Optional layer:** Zephyrus can be uninstalled; torrent'ler istemci varsayılanlarıyla indirilir, seed edilir, organize edilir. Hiçbir kritik akış bozulmaz.

---

## Eros (brief)

**Purpose:** Adult scene collection manager — automated torrent discovery, fingerprint-based metadata matching (OSHash/pHash against TPDB/StashDB), hands-off library organization. Designed around "trust the bytes, not the title."

**Tech stack:** Next.js 16 + React 19 (App Router), Fastify 5, Drizzle ORM + SQLite, Zod, node-corn, pnpm monorepo (`apps/web`, `apps/server`, `packages/database`, `packages/shared-types`). Node >=24, pnpm 12.7.0.

**One-line feature list:** Subscriptions (performers/studios), discovery (manual search), multi-indexer search (Prowlarr/Jackett/Torznab), download clients (qBittorrent/Transmission), metadata providers (TPDB/StashDB), file organization (folder templates, seed retention, NFO generation), API keys, modern dark UI, cron-scheduled jobs, download speed schedules, backups.

**Existing docs:** `README.md` (quickstart, integrations, development), `design-specs.md` (555+ lines, UI specs: badge vocabulary, scene stats, toolbar revamp, subscription settings mega-card, hover preview, extracted-poster badge), `olymposuite.md`, `CONTRIBUTING.md`, `todos.md`, `flow.md`.

**Ports:** Web `9697` (host), API internal `3001`. Container ports: web `3000`, API `3001`. Indexers: Prowlarr `9696`, qBittorrent `8180`, Transmission. API proxied through web UI at `9697`.

**Cross-app:** Part of Olympusuite suite; integrates with qBittorrent/Transmission via common client contract; uses TPDB/StashDB for metadata; subsurface shares suite stack conventions; no direct calls to Zephyrus — manages its own torrents independently.

---

## Psyche (brief)

**Purpose:** TV-series & movie library automation (Sonarr/Radarr slot), metadata-first approach — every library entity is TMDB-anchored and exists before any download. Inverts the classic *arr model (download-first).

**Tech stack:** Next.js 16 + React 19 (App Router), Fastify 5, Drizzle ORM + better-sqlite3, Zod v4, Awilix DI, node-cron, Pino, Vitest + Playwright. Node >=24, pnpm 12.7.0. Shared packages: `@repo/database`, `@repo/shared-types`, `@repo/typescript-config`.

**One-line feature list:** TMDB metadata first pipeline, series/movie subscriptions, quality profiles with seeded defaults, discovery (trending/popular/upcoming via TMDB), person filmography browsing, quality-gated release matching, file organization (TV/movie layouts + NFO/artwork from cached metadata), anime detection heuristic, stalled-download handling, blacklist/auto-pause + exponential resume.

**Existing docs:** `psyche.md` (711+ lines, Parts A-G): Part A — suite standard (topology, ports, monorepo, stack, architecture, conventions, Docker), Part B — competitive analysis vs Sonarr/Radarr, Part C — specification (identity, metadata-first pipeline, domain model, subscriptions, adapter architecture, TMDB-specific builds, constraints), Part D — execution plan (bootstrap checklist, 7 build phases, endorsed patterns). Also `package.json`, `turbo.json`, `eslint.config.mjs`.

**Ports:** Web `9698:3000` (host), API internal `3001`. Suite standard: internal web 3000 + API 3001 per app in separate containers.

**Cross-app:** Shares suite standard with Eros (same stack, same Docker shape, same conventions). Metadata-first model inverts *arr weaknesses identified in B.1–B.3. Shares `@repo/*` packages pattern but each repo replicates its own. No direct calls to Zephyrus — manages its own download pipeline independently.

---

## Morpheus (brief)

**Purpose:** Media-archive compression & optimization — re-encode files so the archive stays storage-optimal (the slot the *arr ecosystem fills with Tdarr/Unmanic/FileFlows). One-way h264→h265 only.

**Tech stack:** Same suite standard: Next.js 16 + React 19, Fastify 5, Drizzle ORM + better-sqlite3, Zod v4, Awilix DI, node-cron, Pino, Vitest + Playwright. Node >=24, pnpm 12.7.0. Two images: management (web+API + minimal ffmpeg + embedded worker) and worker (headless, no published ports).

**One-line feature list:** Transcode engine (h264→h265 via ffmpeg), verification (full decode + duration + stream match + savings threshold ≥10%, configurable VMAF gate optional), worker protocol (long-poll lease+heartbeat), mount mode (SMB/NFS in-place processing), priority engine (highest expected savings first), CPU budget enforcement (cgroup + affinity + ffmpeg thread caps), staged atomic rename, trash retention (7 days default), estimator + calibration loop, API-key management.

**Existing docs:** `morpheus.md` (823+ lines, Parts A-D): Part A — suite standard (topology, ports, monorepo, stack, architecture, deviations: headless worker image + NVENC runtime pull + vendored ffmpeg + duration-scaled verify budget + serialized verification + boot-time orphan cleanup + configurable verify decode + vendored worker ffmpeg), Part B — competitive analysis (Tdarr/Unmanic/FileFlows anti-example), Part C — specification (to be authored), Part D — execution plan (Phases 0–5, build reality notes, image strategy ≤800 MB management / ≤500 MB worker, CPU budget enforcement, build phases). Also `transcode-domain-report.md`, `max-resolution-cap-report.md`, `memory-leak-investigation.md`.

**Ports:** Management web `3000` + API `3001` (internal); worker image has no published ports. Compose example: 1 management + 2 dedicated workers with distinct `--cpus` quotas.

**Cross-app:** Adopts Part A suite standard conventions (same stack, same Docker shape, same auth/envelope pattern). Two-image architecture (management + worker) is a deliberate deviation recorded in A.12. Shares Zod schemas + Drizzle pattern with other suite apps. No direct calls to other apps — workers claim jobs from morpheus server via API key.

---

## omoslim.json (suite agent config)

Root configuration for OpenEncode agent orchestration. Defines presets for coding plan (`my-hybrid-coding-plan`, `my-power-zai-preset`, `full-glm`), each with orchestrator/oracle/librarian/explorer/designer/fixer models, skills, and MCP access. Main model: `zai-coding-plan/glm-5.3` (high variant). Used by the session orchestrator to manage agent dispatches, MCPs (context7, gh_grep, playwright), and skills across the four repos.
---
title: "API Reference"
description: "Eros's REST surface: session and API-key auth, the setup gate, the response envelope and error codes, and all 100 endpoints grouped by domain."
section: "Developer Guide"
order: 40
---

The Fastify 5 API listens on port `3001` container-internally; browsers reach it through the web app's single `/api/*` catch-all proxy (host port `9697` in the shipped compose file). There are **99 endpoints across 19 route files** plus an inline `GET /api/health`. Request/response contracts are Zod 4 schemas in `@repo/shared-types`; interactive OpenAPI docs are served at `/api/docs` (JSON at `/api/docs/json`), public and exempt from both auth gates.

## Authentication

Two `onRequest` gates run before every route handler, in order:

1. **Setup gate** — until the first admin exists, every `/api/*` route except `/api/auth/setup`, `/api/setup/status`, `/api/health`, and the `/api/docs` prefix answers `503` with `code: SETUP_REQUIRED`. The check is memoized and re-armed when setup completes.
2. **Auth gate** — everything else needs a session or an API key, else `401 UNAUTHORIZED`. Public exact-match list: `/api/auth/login`, `/api/auth/verify`, `/api/auth/setup`, `/api/setup/status`, `/api/health`; `/api/docs` is a prefix skip.

Two credential models, resolved in order:

1. **Session** — the `sessionId` cookie from `POST /api/auth/login` (bcryptjs verify). httpOnly, SameSite=Lax, `secure: 'auto'`, 24 h rolling. Sessions live in `@fastify/session`'s in-process **MemoryStore** (the DB `sessions` table was dropped), so **restarting the server signs all users out**. The signing secret persists at `/config/session.secret` — that keeps cookie signing stable across restarts; it does not preserve session state. **Session wins over key auth.**
2. **API key** — for third-party REST access. Keys look like `eros_<32 hex chars>`; send the plaintext in `X-Api-Key: <key>` or `Authorization: Bearer <key>` (Authorization wins when both are present). Only the SHA-256 hex hash is stored; the plaintext is returned exactly once at creation. Revoked keys authenticate as unknown. Key-authed requests stay stateless (`request.user` + `request.apiKey`, no session created). Key management is **admin-only** (403 for non-admins).

**CSRF**: an origin-check hook rejects POST/PUT/PATCH/DELETE from disallowed `Origin` headers with `403 CSRF_CHECK_FAILED`; API-key requests are exempt (header auth cannot be forged cross-site without a rejected CORS preflight). There is deliberately no double-submit token — the Next.js proxy is same-origin.

**Rate limiting**: a global bucket of **1000 requests/minute**, keyed per IP — except API-key requests, which get a per-key bucket (`apikey:<sha256-16>`) so one client cannot exhaust another's budget. Auth-sensitive routes add tighter limits: login **20/15 min**, setup **5/15 min**, change-password **5/15 min**. Exceeded → `429 RATE_LIMITED`.

```bash
BASE="http://localhost:9697"
KEY="eros_your-api-key"
curl -H "X-Api-Key: $KEY" "$BASE/api/subscriptions"
```

## Response envelope

JSON endpoints emit the suite envelope defined in `@repo/shared-types` (`api-envelope.ts`):

```json
{ "success": true, "data": { } }
```

```json
{ "success": false, "error": "human-readable reason", "code": "NOT_FOUND", "details": {} }
```

Success bodies are loose: paginated lists add `total`/`page`/`limit`/`totalPages`, and some mutations add top-level `user` or `message`. `code` is always present on failure; `details` carries per-field Zod issues on validation errors. The central error handler maps every failure class (route-level Zod, controller `ZodError`, `AppError`, Fastify-native, unknown → generic 500, internals hidden).

| Code | HTTP | Meaning |
|------|------|---------|
| `VALIDATION_ERROR` | 400 | Zod/schema validation failed (either layer). |
| `UNAUTHORIZED` | 401 | No/invalid session or API key. |
| `FORBIDDEN` | 403 | Authenticated but not allowed (e.g. non-admin key management). |
| `NOT_FOUND` | 404 | Unknown id/resource; also unmatched URLs. |
| `CONFLICT` | 409 | Conflict errors from services. |
| `RATE_LIMITED` | 429 | Rate budget exceeded. |
| `CSRF_CHECK_FAILED` | 403 | Disallowed origin on a mutation, or CORS rejection. |
| `SETUP_REQUIRED` | 503 | No admin account exists yet (setup gate). |
| `INTERNAL_ERROR` | 500 | Unexpected failure; also the web proxy's 502/504 gateway errors. |
| `REQUEST_ERROR` | 4xx | Fallback for Fastify-native 4xx without a specific mapping (405, 408, 413, 415, …). |

`AppError.code` is open, so call sites may attach richer codes — e.g. stopping an essential job returns `400 JOB_NOT_DISABLEABLE`.

**Exceptions to the envelope**: auth endpoints use their own shapes (login `{ success, user }`, verify `{ authenticated, user? }`, setup status `{ isSetupComplete }`); `GET /api/health` returns plain `{ status: "ok", timestamp }`; binary routes (local images, preview frames, posters, backup download) stream files with no JSON body.

## Auth and setup

| Method | Path | Purpose |
|--------|------|---------|
| POST | `/api/auth/setup` | One-time admin creation (public, 201; 400 when an admin exists). |
| GET | `/api/setup/status` | `{ isSetupComplete }` (public). |
| POST | `/api/auth/login` | Session login (public). |
| POST | `/api/auth/logout` | Destroy the current session. |
| GET | `/api/auth/verify` | `{ authenticated, user? }` for the current cookie (public). |
| POST | `/api/auth/change-password` | Change the signed-in user's password. |

## API keys

| Method | Path | Purpose |
|--------|------|---------|
| GET | `/api/api-keys` | List keys (id/name/prefix/isActive/lastUsedAt — never hash or plaintext). Admin-only. |
| POST | `/api/api-keys` | Create a key (201); plaintext returned exactly once. Admin-only. |
| DELETE | `/api/api-keys/:id` | Soft-revoke a key, scoped to its owner. Admin-only. |

## Scenes

| Method | Path | Purpose |
|--------|------|---------|
| GET | `/api/scenes` | Library listing — search, tags, subscribed/download/quality filters, sort (limit clamped 1–500). |
| GET | `/api/scenes/:id` | Scene detail with performer/studio relations and download status. |
| PUT | `/api/scenes/:id` | Update scene fields. |
| DELETE | `/api/scenes/:id` | **Always soft delete** — tombstone `status='deleted'`, files + torrent removed, junctions kept. |
| POST | `/api/scenes/:id/restore` | Restore a tombstone to `discovered` (frees the infoHash for re-download). |
| POST | `/api/scenes/:id/enrich` | Re-run hash-only enrichment for one scene. |
| GET | `/api/scenes/:id/file-info` | Live local-file facts (`available: false` when missing). |
| GET | `/api/scenes/:id/previews` | Hover-preview status only (no ffmpeg work). |
| POST | `/api/scenes/:id/previews` | Enqueue async preview generation; returns immediately. |
| GET | `/api/scenes/:id/previews/:frame` | Binary JPEG frame, immutable cache. |
| GET | `/api/scenes/:id/poster` | Binary JPEG poster, 1-day cache. |

## Performers and studios

Mirror-image catalogs; both support `deleteScenes` on delete and bulk enrichment.

| Method | Path | Purpose |
|--------|------|---------|
| GET | `/api/performers` | List with scene-count rollups; search/tags/subscribed filters. |
| GET | `/api/performers/:id` | Performer detail with related scenes. |
| POST | `/api/performers` | Create (201) via external-id find-or-create; fires background enrichment. |
| POST | `/api/performers/find-or-create` | Subscribe-flow reuse/merge (always 200). |
| PUT | `/api/performers/:id` | Update fields/aliases/tags. |
| DELETE | `/api/performers/:id` | Delete entity; `?deleteScenes=` controls scene teardown (dependency rule). |
| DELETE | `/api/performers/:id/blacklist` | Clear blacklist entries scoped to this performer. |
| POST | `/api/performers/:id/enrich-scenes` | Bulk re-enrich this performer's scenes. |
| GET | `/api/studios` | List with scene-count rollups. |
| GET | `/api/studios/:id` | Studio detail with related scenes. |
| POST | `/api/studios` | Create (201) via external-id find-or-create. |
| POST | `/api/studios/find-or-create` | Subscribe-flow reuse/merge (always 200). |
| PUT | `/api/studios/:id` | Update fields. |
| DELETE | `/api/studios/:id` | Delete entity; `?deleteScenes=` controls scene teardown. |
| DELETE | `/api/studios/:id/blacklist` | Clear blacklist entries scoped to this studio. |
| POST | `/api/studios/:id/enrich-scenes` | Bulk re-enrich this studio's scenes. |

## Subscriptions and quality profiles

| Method | Path | Purpose |
|--------|------|---------|
| GET | `/api/subscriptions` | List with download stats (active/downloaded/pending). |
| POST | `/api/subscriptions` | Subscribe a performer or studio (never a scene). |
| GET | `/api/subscriptions/all-scenes` | All subscribed scenes; legacy array or paginated mode. |
| GET | `/api/subscriptions/tag-facets` | Tag facets; `type` (`scene`/`performer`) required. |
| GET | `/api/subscriptions/:id` | One subscription (ownership-guarded). |
| PUT | `/api/subscriptions/:id` | Update filters, profile, megapack/compilation toggles. |
| DELETE | `/api/subscriptions/:id` | Delete; `?deleteScenes=` selects hard cleanup vs keep. |
| POST | `/api/subscriptions/:id/pause` | Pause automation. |
| POST | `/api/subscriptions/:id/resume` | Resume automation. |
| GET | `/api/subscriptions/:id/scenes` | Scenes linked to this subscription. |
| GET | `/api/subscriptions/:id/blacklist` | This subscription's blacklist entries. |
| GET | `/api/quality-profiles` | List the user's profiles. |
| GET | `/api/quality-profiles/:id` | One profile. |
| POST | `/api/quality-profiles` | Create (user-scoped; default flag handled). |
| PUT | `/api/quality-profiles/:id` | Update preferences. |
| DELETE | `/api/quality-profiles/:id` | Delete a profile. |

## Discovery and search

| Method | Path | Purpose |
|--------|------|---------|
| POST | `/api/discovery/search` | Manual indexer search; results annotated with per-result `matchReasons`. **180 s proxy timeout.** |
| POST | `/api/discovery/add-download` | Grab a result — creates the scene at download start. |
| POST | `/api/discovery/auto-relate` | Link a scene to a performer/studio. |
| GET | `/api/discovery/performers` | Provider search (TPDB/StashDB; `query` required, `provider` defaults `all`). |
| GET | `/api/discovery/studios` | Provider studio search. |

## Downloads and blacklist

| Method | Path | Purpose |
|--------|------|---------|
| GET | `/api/downloads` | Queue listing; `organized` rows hidden by default, `status` filter. |
| POST | `/api/downloads/bulk` | Bulk pause/resume/remove/remove_blacklist/retry (≤100 ids, per-id results). |
| GET | `/api/downloads/stalled` | Stalled downloads, longest-stalled first. |
| POST | `/api/downloads/stalled/remove` | Remove stalled torrents **with files** + blacklist. |
| GET | `/api/torrent-blacklist` | List entries; `subscriptionId` required. |
| GET | `/api/torrent-blacklist/check` | `{ isBlacklisted }` for an `infoHash` (required). |
| DELETE | `/api/torrent-blacklist/:id` | Remove an entry — the hash becomes downloadable again. |

## Library, jobs, and logs

| Method | Path | Purpose |
|--------|------|---------|
| POST | `/api/library/scan` | Scan storage roots and import unreferenced files as scenes. |
| POST | `/api/library/audit` | Orphan-file report (duplicates vs unique). |
| POST | `/api/library/audit/delete` | Delete selected orphan paths. |
| GET | `/api/jobs` | All 11 jobs — schedule, status, live progress, last/next run. |
| GET | `/api/jobs/:name` | One job's detail. |
| POST | `/api/jobs/:name/trigger` | Run now, detached (**202**); overlap-guarded. |
| POST | `/api/jobs/:name/start` | Re-enable a disabled job. |
| POST | `/api/jobs/:name/stop` | Disable a job (essential jobs → `400 JOB_NOT_DISABLEABLE`). |
| PUT | `/api/jobs/:name/schedule` | Persist a 5-field cron override and reschedule live. |
| GET | `/api/jobs/:name/logs` | Run history (limit default 20). |
| GET | `/api/logs` | App logs — level/category/source/date filters, FTS5 search, limit default 50 (max 200). |
| GET | `/api/logs/sources` | Distinct sources for hierarchical dropdowns. |
| GET | `/api/logs/:jobRunId/steps` | Step-by-step log of one job run. |

## Settings, connections, dashboard

| Method | Path | Purpose |
|--------|------|---------|
| GET | `/api/settings` | All settings; sensitive values masked (`****`). |
| PUT | `/api/settings` | Update via `{key,value}[]` or flat camelCase object; triggers runtime side effects. |
| GET | `/api/service-connections` | List external services (credentials masked). |
| GET | `/api/service-connections/:id` | One connection (masked). |
| POST | `/api/service-connections` | Add a connection; refreshes adapters. |
| PUT | `/api/service-connections/:id` | Update; masked placeholders keep stored secrets. |
| DELETE | `/api/service-connections/:id` | Remove a connection. |
| POST | `/api/service-connections/test` | Health-check a stored (`{id}`) or ad-hoc connection. |
| GET | `/api/dashboard/stats` | Aggregate library/download statistics. |
| GET | `/api/dashboard/storage` | Volume-grouped storage overview. |
| GET | `/api/dashboard/recent-downloads` | Recent queue rows (limit default 10). |
| GET | `/api/dashboard/recent-scenes` | Recent scenes (limit default 5). |
| GET | `/api/dashboard/recent-activity` | Recent activity feed (limit default 20). |
| GET | `/api/disk/info` | Per-path free-space snapshots and thresholds. |
| GET | `/api/local-images/performers/:id` | Binary performer image (store-images-locally feature). |
| GET | `/api/local-images/studios/:id/:kind` | Binary studio `logo`/`banner`. |
| GET | `/api/local-images/scenes/:id/:file` | Binary scene `poster.jpg`/`fanart.jpg`. |

## Backups and health

| Method | Path | Purpose |
|--------|------|---------|
| GET | `/api/backups` | List snapshots, newest first. |
| POST | `/api/backups` | Create an online SQLite snapshot (201). |
| GET | `/api/backups/:id/download` | Stream the snapshot file — **no envelope**. |
| POST | `/api/backups/:id/restore` | Replace the live DB; returns `{ success, restartRequired }`, process exits for restart. |
| DELETE | `/api/backups/:id` | Delete a snapshot. |
| GET | `/api/health` | Public health check — `{ status: "ok", timestamp }`. |

> [!NOTE]
> `backup.ts` is the one route file that bypasses controllers: download/restore/delete call `backupService` inline behind `isValidBackupId` guards (path-traversal-safe ids). Binary routes intentionally declare no response schema.

## The web proxy and timeouts

The frontend does not use Next.js rewrites. A single catch-all route handler (`apps/web/src/app/api/[[...path]]/route.ts`) forwards every `/api/*` request to `API_URL` (default `http://localhost:3001`), relaying cookies via `getSetCookie()` and streaming bodies both ways. Its per-path timeout map is the single source of truth for upstream deadlines:

| Path | Timeout |
|------|---------|
| `discovery/search` | 180 s (Prowlarr multi-indexer fan-out) |
| everything else | 30 s |

A timeout answers `504` and an unreachable backend `502`, both in the error envelope with `code: INTERNAL_ERROR`.

For the behavior behind these routes see [Discovery](./discovery), [Subscriptions](./subscriptions), [Download management](./download-management), and [Deletion semantics](./deletion-semantics); the schema underneath is documented in [Database](./database).
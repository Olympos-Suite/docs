---
title: "API Reference"
description: "Psyche's HTTP API: session and API-key auth, the response envelope and error codes, and every route grouped by domain."
section: "Developer Guide"
order: 40
---

The Fastify 5 API listens on port `3001` **container-internally**; browsers reach it through the web app's `/api` proxy (host port `9698`). All examples below use the proxied origin. Request/response schemas are Zod contracts in `@repo/shared-types`; routes are typed with `fastify-type-provider-zod`. Interactive OpenAPI docs are served at `/api/docs` (JSON at `/api/docs/json`), public like the health route.

## Authentication

Two credential models, checked in order by an `onRequest` gate (before body parsing — anonymous callers get 401, never a schema-leaking 400):

1. **Session** — `psyche.session` cookie from `POST /api/auth/login` (bcrypt verify). httpOnly, SameSite=Lax, secure auto, 24 h, SQLite-backed. **Session wins over key auth.**
2. **API key** — the **plaintext key** in `X-Api-Key: <key>` or `Authorization: Bearer <key>`. Keys look like `psy_<43 chars>`; only the SHA-256 hash is stored, and the plaintext is shown exactly once at creation. Revoked keys authenticate as unknown.

Public routes (everything else 401s): `GET /api/health`, `POST /api/auth/setup`, `POST /api/auth/login`, `GET /api/auth/session`, and the `/api/docs` prefix. `GET /api/auth/session` answers `SETUP_REQUIRED` while no admin exists.

**CSRF**: session-authenticated mutations (POST/PUT/DELETE) must echo the double-submit token delivered in the `x-csrf-token` response header on safe requests. API-key requests are exempt. **Rate limiting**: two separate buckets of 300 requests/minute — one per API key value, one per IP for session/anonymous traffic; exhausting one does not block the other. Exceeded → `RATE_LIMITED`.

```bash
BASE="http://localhost:9698"
KEY="psy_your-api-key"
curl -H "X-Api-Key: $KEY" "$BASE/api/subscriptions"
```

## Response envelope

Every branch emits the suite envelope:

```json
{ "success": true, "data": { } }
```

```json
{ "success": false, "error": "human-readable reason", "code": "NOT_FOUND", "details": {} }
```

`code` is **always** present on failure; `details` is optional. Mutation endpoints that return nothing use `{ "success": true, "data": null }`. Two exceptions to the JSON envelope: backup download streams binary SQLite, and connection-test failures ride the *success* envelope as `{ ok: false, message }` results.

| Code | HTTP | Meaning |
|------|------|---------|
| `VALIDATION_ERROR` | 400 | Zod/schema validation failed. |
| `UNAUTHORIZED` | 401 | No/invalid credentials. |
| `FORBIDDEN` | 403 | Authenticated but not allowed. |
| `NOT_FOUND` | 404 | Unknown id/resource. |
| `CONFLICT` | 409 | Duplicate subscription/grab, name collision, running-job trigger, essential-job stop. |
| `RATE_LIMITED` | 429 | Rate budget exceeded. |
| `CSRF_CHECK_FAILED` | 403 | Missing/invalid CSRF token on a session mutation. |
| `SETUP_REQUIRED` | 401 | No admin account exists yet. |
| `INTERNAL_ERROR` | 500 | Unexpected server failure. |
| `REQUEST_ERROR` | 400* | Upstream/request failure; *overrides to 502 for indexer/client/TMDB failures, 504 from the web proxy on timeout. |

## Auth and API keys

| Method | Path | Purpose |
|--------|------|---------|
| POST | `/api/auth/setup` | One-time admin creation (public). |
| POST | `/api/auth/login` | Session login (public). |
| POST | `/api/auth/logout` | End the current session. |
| POST | `/api/auth/password` | Change the signed-in admin's password; session stays valid. |
| GET | `/api/auth/session` | Current session user; `SETUP_REQUIRED` when no admin (public). |
| GET | `/api/api-keys` | List keys (summaries with prefix — never plaintext). |
| POST | `/api/api-keys` | Create a key; plaintext returned exactly once. |
| DELETE | `/api/api-keys/:id` | Revoke a key (soft; 404 when missing/already revoked). |

## Settings and service connections

| Method | Path | Purpose |
|--------|------|---------|
| GET | `/api/settings` | All defined settings; sensitive values masked `********`. |
| PUT | `/api/settings` | Update settings, validated against the definitions registry. |
| GET | `/api/service-connections` | List connections (secrets masked). |
| POST | `/api/service-connections` | Add a connection; at most one `metadata_provider`; priority 1–99. |
| GET | `/api/service-connections/:id` | One connection (masked). |
| PUT | `/api/service-connections/:id` | Partial update; omitted/masked secrets keep stored values. |
| DELETE | `/api/service-connections/:id` | Remove; queue history survives (client ref → null). |
| POST | `/api/service-connections/test` | Probe stored (`{id}`) or ad-hoc connection; failure is a result. |

## Metadata and library

| Method | Path | Purpose |
|--------|------|---------|
| GET | `/api/metadata/search` | TMDB search — `q`, `type` (all/tv/movie/person), `page`. |
| GET | `/api/metadata/series/:tmdbId` | Series detail + seasons; optional `language`. |
| GET | `/api/metadata/movie/:tmdbId` | Movie detail. |
| GET | `/api/metadata/person/:tmdbId` | Person detail + combined-credits filmography. |
| GET | `/api/metadata/discover` | Surfaces — `surface`, `media`, `window`, `page`. |
| GET | `/api/metadata/artwork` | Download-once artwork proxy — `path`, `type`. |
| POST | `/api/library/series` | Add a series (persists seasons + all episodes; may take seconds). |
| POST | `/api/library/movie` | Add a movie. |
| GET | `/api/library` | Library listing — persisted series + movie summaries. |

## Subscriptions and quality profiles

| Method | Path | Purpose |
|--------|------|---------|
| POST | `/api/subscriptions` | Subscribe series/movie; entity persisted from TMDB first (201). |
| GET | `/api/subscriptions` | List with target summaries, profile, wanted counts. |
| PUT | `/api/subscriptions/:id` | Partial update; `null` clears profile/grab-policy override. |
| DELETE | `/api/subscriptions/:id` | Delete; release requests and queue rows cascade. |
| GET | `/api/wanted` | Wanted view — open episodes per series, packs, movies. |
| GET | `/api/calendar` | Episodes in the resolved window (`from`/`to`; default 14 d, max 62 d). |
| GET | `/api/quality-profiles` | List profiles (default carries `isDefault`). |
| GET | `/api/quality-profiles/:id` | One profile. |
| POST | `/api/quality-profiles` | Create; duplicate name → 409; `isDefault` clears the old default. |
| PUT | `/api/quality-profiles/:id` | Partial update; `preferences` replaces the whole list. |
| DELETE | `/api/quality-profiles/:id` | Delete; referencing subscriptions SET NULL and re-gate. |

## Search, queue, and blacklist

| Method | Path | Purpose |
|--------|------|---------|
| POST | `/api/search` | Manual release search — target + optional `subscriptionId` (resolves the scoring profile; unknown id → 404). |
| GET | `/api/queue` | Queue rows newest-first; optional `?status=` filter. |
| POST | `/api/queue/grab` | Grab a scored release (search result echoed verbatim + flat linkage); blacklist/duplicate guards first (201). |
| POST | `/api/queue/:id/pause` | Pause row + client torrent (best-effort). |
| POST | `/api/queue/:id/resume` | Resume row + client torrent (best-effort). |
| POST | `/api/queue/:id/retry` | Retry from failed/paused only; bumps retry count, clears backoff. |
| DELETE | `/api/queue/:id` | Delete row; client removal best-effort, never blocks. |
| GET | `/api/blacklist` | List banned hashes (normalized uppercase 40-hex). |
| DELETE | `/api/blacklist/:id` | Remove an entry — the hash becomes grabbable again. |

## Jobs, logs, and disk

| Method | Path | Purpose |
|--------|------|---------|
| GET | `/api/jobs` | All jobs — effective schedule, flags, live progress, last run. |
| GET | `/api/jobs/:name` | One job's detail. |
| POST | `/api/jobs/:name/trigger` | Run now; returns the running job immediately (running → 409). |
| POST | `/api/jobs/:name/start` | Remove from `jobs.disabled`, re-arm schedule. |
| POST | `/api/jobs/:name/stop` | Persist to `jobs.disabled`, unschedule (essential → 409). |
| PUT | `/api/jobs/:name/schedule` | Cron override; saving the default clears it; invalid cron → 400. |
| GET | `/api/jobs/:name/logs` | Run history, newest first (default 20, cap 100). |
| GET | `/api/logs` | App logs newest-first; `level` = minimum severity, `search` substring. |
| DELETE | `/api/logs` | Clear the log store; returns deleted count. |
| GET | `/api/disk/info` | Per-path filesystem snapshots for active storage paths. |

## Backups, audit, and health

| Method | Path | Purpose |
|--------|------|---------|
| GET | `/api/backups` | List snapshots (newest first). |
| POST | `/api/backups` | Create an online snapshot (settings included by definition). |
| GET | `/api/backups/:id/download` | Binary SQLite stream — **no envelope**. |
| POST | `/api/backups/:id/restore` | Replace the live DB; schedules a process restart. |
| DELETE | `/api/backups/:id` | Delete a snapshot. |
| POST | `/api/library/audit` | Scan storage roots for orphan video files (duplicates vs unique). |
| POST | `/api/library/audit/delete` | Delete selected orphans — active roots only, never linked files. |
| GET | `/api/health` | Public health check — `{ status: "ok", uptime }`. |

For the behavior behind these routes, see the User Guide pages: [Subscriptions](./subscriptions), [Download management](./download-management), [File organization](./file-organization), and [Configuration](./configuration).
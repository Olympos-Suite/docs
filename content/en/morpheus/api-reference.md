---
title: "API Reference"
description: "Auth model, the response envelope and error taxonomy, and every management and worker-protocol endpoint."
section: "Developer Guide"
order: 50
---

The Fastify API listens on port 3001 (container-internal by default); the web app proxies `/api/*` to it. Every route validates with Zod schemas from `@repo/shared-types`, and OpenAPI docs are generated from the same schemas at `/api/docs`. Responses use the suite envelope on every JSON route; the two binary transfer routes are deliberately un-enveloped.

## Authentication

Two credential paths, checked in order by the auth gate:

1. **Session** — `@fastify/session` + `@fastify/cookie` with a SQLite session store: `sessionId` cookie, httpOnly, `sameSite: 'lax'`, `secure: 'auto'`, **24 h sliding** expiry. Sessions survive restarts. **The session always wins over key auth** — a request with a session principal never reaches the key path, so cookie-carrying browsers stay CSRF-enforced.
2. **API key** — `Authorization: Bearer <key>` (case-insensitive scheme) or `X-Api-Key`. Keys are sha256-hashed rows with a display prefix; plaintext is shown exactly once on create. Invalid/revoked keys are indistinguishable from no credentials (401). Key traffic is **CSRF-exempt** and exempt from the per-IP limiter; its governing budget is **600 requests/min per key** (429 `RATE_LIMITED` when exhausted).

Rate limits: global per-IP 300/min; credential endpoints (setup/login) 10/min unconditionally — even valid keys cannot bypass the brute-force limit. Session mutations use double-submit CSRF: secret in an httpOnly `_csrf` cookie, token from `GET /api/auth/csrf`, echoed via `x-csrf-token`.

**PUBLIC_ROUTES** (exact-path allowlist): `/api/health`, `/api/setup/status`, `/api/auth/setup`, `/api/auth/login`, `/api/auth/csrf`, `/api/docs`, `/api/docs/json`, plus the `/api/docs/` asset prefix. Everything else 401s without credentials; unmatched paths fall through to the 404 handler.

First run: `POST /api/auth/setup` creates the admin account (one-shot). `POST /api/auth/change-password` (current password + new ≥ 8 chars) revokes every **other** session of the user; the current one survives.

## Envelope and error codes

```json
{ "success": true, "data": { } }
```

```json
{ "success": false, "error": "human-readable message", "code": "CONFLICT", "details": { } }
```

`code` is always present, emitted by the centralized error handler:

| Code | Typical status | Meaning |
|------|----------------|---------|
| `VALIDATION_ERROR` | 400 | Zod schema failure (issues in `details`) |
| `UNAUTHORIZED` | 401 | No/invalid credentials |
| `FORBIDDEN` | 403 | Authenticated but not allowed |
| `NOT_FOUND` | 404 | Unknown id or unmatched route |
| `CONFLICT` | 409 | One-active-job race, lost lease, active scan/bulk run, disabled rule |
| `RATE_LIMITED` | 429 | Per-key or per-IP budget exhausted |
| `CSRF_CHECK_FAILED` | 403 | Session mutation without a valid CSRF token |
| `SETUP_REQUIRED` | 403 | No admin account exists yet |
| `INTERNAL_ERROR` | 500 | Unhandled server failure |
| `REQUEST_ERROR` | 4xx | Unmapped client errors (e.g. interrupted upload, 416 range) |

## Management routes

Auth is **session or API key** unless noted.

| Method | Path | Notes |
|--------|------|-------|
| GET | `/api/setup/status` | Public; first-run wizard state |
| POST | `/api/auth/setup` | Public, one-shot; create admin |
| POST | `/api/auth/login` | Public; CSRF-protected |
| GET | `/api/auth/csrf` | Public; issue CSRF token |
| POST | `/api/auth/logout` | Revoke the current session |
| POST | `/api/auth/change-password` | Revokes all other sessions |
| GET | `/api/auth/me` | Current user |
| GET | `/api/settings` | All settings (calibration included, read-only) |
| PUT | `/api/settings` | Partial update; unknown keys stripped; returns merged values |
| GET | `/api/libraries` | List libraries |
| POST | `/api/libraries` | Add an archive root |
| GET / PUT / DELETE | `/api/libraries/:id` | Read / edit / remove (media files untouched) |
| POST | `/api/libraries/:id/scan` | Enqueue a scan; 409 while one is active |
| POST | `/api/libraries/:id/rule` | Assign library-default ruleset; non-null also starts one bulk-enqueue run |
| GET | `/api/media-files` | Paginated, savings-ranked probe cache for one library |
| POST | `/api/media-files/:id/transcode` | Manual enqueue; hevc-only target (400 otherwise); 409 not probed / not h264 / already active |
| POST | `/api/media-files/rule` | Bulk-assign one ruleset to 1–500 files; aggregated counters |
| POST | `/api/media-files/:id/rule` | Per-file assignment; immediate enqueue when eligible, else skipReason |
| GET | `/api/jobs` | List jobs; optional `libraryId` filter, limit |
| GET | `/api/jobs/:id` | Job detail + history |
| POST | `/api/jobs/:id/cancel` | Queued or worker-held only; server-owned verification → 409 |
| POST | `/api/jobs/:id/retry` | Failed transcodes only; payload untouched |
| DELETE | `/api/jobs/:id` | Terminal jobs only; deletes history rows too |
| GET / POST | `/api/rules` | List / create rulesets |
| PATCH / DELETE | `/api/rules/:id` | Update / delete a ruleset |
| GET | `/api/workers` | Registered workers with capabilities |
| PATCH | `/api/workers/:id` | Rename (locks name) / set `fileAccessOverride` |
| GET / POST | `/api/api-keys` | List (revoked included) / create — plaintext returned exactly once |
| DELETE | `/api/api-keys/:id` | Revoke; re-revoking is a no-op |
| GET | `/api/stats/queue` | Queue counts per status |
| GET | `/api/stats/libraries/:id/history` | Daily realized-savings history |
| GET | `/api/stats/calibration` | Calibration blob, read-only |
| GET | `/api/stats/accuracy` | Estimate-accuracy rows |
| GET | `/api/health` | Public; ffprobe availability |

## Worker protocol routes

API-key auth (worker key or admin session). Job-scoped calls carry `X-Worker-Id` (or `workerId` query); strict claim-holder match when present. Full semantics: [Worker protocol](./worker-protocol).

| Method | Path | Success | Notes |
|--------|------|---------|-------|
| POST | `/api/worker/register` | 200 | Upsert by name; returns lease budget + staging floor |
| POST | `/api/worker/claim` | 200 / 204 | Long-poll 25 s; 204 = no job at the deadline |
| POST | `/api/worker/jobs/:jobId/heartbeat` | 200 | Extends lease; 409 on lost lease / server ownership |
| POST | `/api/worker/jobs/:jobId/progress` | 204 | Throttled stage/percent; server-owned → no-write |
| POST | `/api/worker/jobs/:jobId/fail` | 204 | Retryable → requeue under the attempts cap |
| GET | `/api/worker/jobs/:jobId/input` | 200 / 206 | Binary, Range-resumable; 416 enveloped |
| PUT | `/api/worker/jobs/:jobId/output` | 204 | Raw octet-stream upload → staging → verification; 1 TiB bodyLimit, 2 s lease watchdog |
| POST | `/api/worker/jobs/:jobId/output-mounted` | 204 | Mount-mode completion marker; same accept seam |

## OpenAPI

Swagger UI is served at `/api/docs` (JSON at `/api/docs/json`), generated from the same Zod route schemas — the docs cannot drift from validation. The web client mirrors the error codes from `@repo/shared-types/codes` (zod-free, safe for the client bundle) and unwraps the envelope structurally.
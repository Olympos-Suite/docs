---
title: "API Reference"
description: "Every Zephyrus HTTP endpoint: auth model, request/response shapes, status codes, and curl examples."
section: "Developer Guide"
order: 4
---

Zephyrus exposes a Fastify 5 API under `/api` (default port 3030) plus the static dashboard at `/`. Response shapes are **pinned DTOs** in `src/http/dto.ts` — the web dashboard is built against them, so fields must not be renamed. Routes live in `src/http/routes/api-routes.ts`; the layering rule (routes → controllers → services → repositories) is mandatory.

## Authentication

Every `/api` route is guarded by a `preHandler` hook (`src/http/plugins/auth.ts`). A request is authorized when its `Authorization: Bearer <token>` header matches, in order:

1. the **`ZEPHYRUS_TOKEN`** environment value (static machine token, when set — used by the Docker healthcheck), compared constant-time; or
2. an active (non-expired) **session token** from the `sessions` table, issued by login or the first-run wizard (30-day expiry; only the sha256 hash is stored).

Exactly three routes are **pre-auth** by design:

- `GET /api/setup/status` — pinned no-auth (the dashboard needs it before login)
- `POST /api/setup/user` — self-guarded: returns 409 once any user exists
- `POST /api/auth/login` — the authentication endpoint itself

Auth is disabled entirely **only while no users exist AND `ZEPHYRUS_TOKEN` is unset** (the first-run bootstrap window). When `ZEPHYRUS_TOKEN` is unset, startup logs a warning: the static machine token is unavailable and username/password sessions apply. Non-`/api` paths (static dashboard assets) are exempt so the login screen is reachable. Any other unauthorized request gets `401 {"error":"unauthorized"}`.

All examples below assume a static token; substitute a session token interchangeably.

```bash
TOKEN="your-zephyrus-token"
BASE="http://localhost:9695"
```

## Endpoint overview

| # | Method | Path | Auth | Success |
|---|--------|------|------|---------|
| 1 | GET | `/api/status` | bearer | 200 |
| 2 | GET | `/api/torrents` | bearer | 200 |
| 3 | POST | `/api/torrents/:infoHash/pin` | bearer | 204 |
| 4 | DELETE | `/api/torrents/:infoHash/pin` | bearer | 204 |
| 5 | GET | `/api/config` | bearer | 200 |
| 6 | PUT | `/api/config` | bearer | 200 |
| 7 | GET | `/api/actions` | bearer | 200 |
| 8 | GET | `/api/setup/status` | none | 200 |
| 9 | POST | `/api/setup/user` | none (one-shot) | 201 |
| 10 | POST | `/api/setup/client` | bearer | 200 |
| 11 | POST | `/api/auth/login` | none | 200 |
| 12 | POST | `/api/auth/logout` | bearer | 204 |

---

## 1. GET /api/status

Healthcheck + overview. **Never errors on client failure** — it reports `"degraded"` while the client is unreachable (Docker healthcheck contract). Counts cover *all* client torrents; `managed` is the subset in `config.groups`.

Response `200` — `StatusResponse`:

```json
{
  "status": "ok",
  "client": {
    "type": "qbittorrent",
    "url": "http://qbittorrent:8080",
    "connected": true,
    "capabilities": { "reannounce": true, "downloadLimit": true, "uploadLimit": true }
  },
  "torrents": {
    "total": 12, "managed": 8,
    "byState": { "downloading": 4, "seeding": 5, "paused": 3 },
    "byGroup": { "eros": 6, "psyche": 2, "(groupless)": 4 },
    "pausedByUs": 2
  },
  "safeMode": false,
  "safeModeTorrents": [],
  "uptimeSeconds": 3600,
  "version": "0.1.0"
}
```

`safeMode` latches when a managed torrent is found paused without a record of Zephyrus having paused it (user/app pause or DB loss). `safeModeTorrents` lists managed torrents currently paused by someone other than Zephyrus (`infoHash`, `name`, `group`, `addedAt`); empty = none. `status` is `'ok' | 'degraded'`.

```bash
curl -H "Authorization: Bearer $TOKEN" "$BASE/api/status"
```

## 2. GET /api/torrents

**Managed torrents only** — groupless and unlisted-group torrents are never listed (ownership rule). Data comes from the last client snapshot plus live policy state.

Response `200` — `TorrentsResponse`: `{ "torrents": TorrentDto[] }` where each `TorrentDto` is:

| Field | Type | Notes |
|-------|------|-------|
| `infoHash`, `name`, `group` | string / string / string\|null | From the client snapshot |
| `state` | `TorrentState` | Canonical state |
| `pausedByUs` | boolean | Zephyrus owns the pause |
| `pauseReason` | `'queue'\|'stalled'\|'slow'\|'schedule'\|null` | Single value; priority schedule > stalled > slow > queue |
| `addedAt`, `downloadSpeed`, `size`, `progress` | number | Epoch ms, bytes/s, bytes, 0..1 |
| `activeLimits` | `{download, upload}\|null` | Per-torrent share of the active limited profile; `null` when unlimited/outside a window **or the torrent is paused** |
| `retryCount` | number | Consecutive stalled retries without meaningful progress |
| `lastRetryAt` | number\|null | Epoch ms of last stalled retry |
| `givenUp` | boolean | Conditional give-up latch (retried only while queue idle) |
| `pinned` | boolean | User manual priority pin |

```bash
curl -H "Authorization: Bearer $TOKEN" "$BASE/api/torrents"
```

## 3. POST /api/torrents/:infoHash/pin

Set the user manual priority pin. The torrent becomes exempt from queue ceilings, slow/stalled tracking, and the adoption sweep (schedule windows still apply); any existing `queue`/`stalled`/`slow` pause is released promptly (a forced tick runs when snapshots exist). The pin persists in the DB and survives restarts.

- Path param: `infoHash` — must exist in the last client snapshot **and** belong to a managed group.
- No request body.
- `204` — no body.
- `404` — `{"error":"no managed torrent \"<hash>\""}` for unknown or unmanaged hashes.

```bash
curl -X POST -H "Authorization: Bearer $TOKEN" \
  "$BASE/api/torrents/abc123def456/pin"
```

## 4. DELETE /api/torrents/:infoHash/pin

Remove the pin; the torrent returns to ordinary management on the next evaluation (no forced tick). Same params and status codes as POST: `204` on success, `404` for unknown/unmanaged hashes.

```bash
curl -X DELETE -H "Authorization: Bearer $TOKEN" \
  "$BASE/api/torrents/abc123def456/pin"
```

## 5. GET /api/config

The active (parsed, validated) configuration. **Secrets are masked**: `client.password` is always `"***"` (`maskConfig` in `src/services/config-service.ts`). Speed values appear normalized to bytes/s numbers (plain-number inputs are KiB/s; see [Configuration](./configuration)).

Response `200` — `ConfigResponse`: `{ "config": ZephyrusConfig }` with the full shape: `client` (type, url, username, password, poll_interval_seconds), `timezone`, `global.max_active_downloads`, `groups.<name>` (max_active_downloads?, weight), `stalled` (threshold_minutes, retry{interval_minutes, backoff_multiplier, max_interval_minutes, progress_reset_bytes, give_up_hours}, slow?, completion_bias?), `schedule` (profiles, windows), `server` (port, log_level).

```bash
curl -H "Authorization: Bearer $TOKEN" "$BASE/api/config"
```

## 6. PUT /api/config

Update the configuration: **Zod validation → hot-reload → atomic persist** to the same `config.yaml` the process booted from.

Request body — pinned wire format is `{ "config": { ...full config... } }`; a bare config object is tolerated. Semantics:

- `client.password: "***"` means **keep the current secret** — the mask is swapped for the real password before validation (masking is a transport convention, not a config value).
- Submitted `env:NAME` strings pass through the same placeholder resolution as the file loader; a missing referenced env var is a 400. A literal `env:...` never reaches the torrent client.
- Validation failures return every Zod issue as a `"path: message"` line.
- On success the orchestrator hot-applies the config first (adapter recreated if connection fields changed, poll timer re-armed, schedule limits invalidated), then persists via `saveConfig` (tmp file + rename). **An `env:NAME` password reference on disk stays a reference** — the resolved secret is never written back into the YAML. Profile speeds are serialized in canonical unit-string form (`"15000 KiB/s"` / `"1875000 B/s"`) so save→load is lossless.
- If the file write fails, the hot-reload has already applied; the response is 400 with an issue saying so.

Responses:

- `200` — `ConfigResponse` with the new config, password masked.
- `400` — `ConfigErrorResponse`: `{ "error": "invalid configuration", "issues": ["client.url: ...", ...] }`.

```bash
curl -X PUT -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  "$BASE/api/config" -d '{
    "config": {
      "client": { "type": "qbittorrent", "url": "http://qbittorrent:8080",
                  "username": "admin", "password": "***", "poll_interval_seconds": 5 },
      "timezone": "Europe/Istanbul",
      "global": { "max_active_downloads": 6 },
      "groups": { "eros": { "max_active_downloads": 4, "weight": 10 } },
      "stalled": { "threshold_minutes": 30 },
      "schedule": { "profiles": { "full": { "download": 0, "upload": 0 } }, "windows": [] },
      "server": { "port": 3030, "log_level": "info" }
    }
  }'
```

(The example omits defaulted fields for brevity; the schema applies defaults for `stalled.retry`, `server`, etc. Send the full config as returned by GET /api/config with your edits.)

## 7. GET /api/actions

The audit trail (`action_log`), newest first (`created_at` DESC, `id` DESC tiebreaker).

- Query param `limit` (optional): clamped to **1..1000**, default **100**; missing/empty/non-numeric values fall back to the default.
- Response `200` — `ActionsResponse`: `{ "actions": ActionDto[] }` with `id` (number), `infoHash` (string|null — null for system notes and limit summaries), `action` (`'pause'|'resume'|'reannounce'|'limit'|'unmanage'|'note'`), `reason` (human-readable), `createdAt` (epoch ms).
- Limit actions write one summary row per action (`"(N torrents)"` suffix), not per-hash rows. Rows older than 90 days are pruned at startup.

```bash
curl -H "Authorization: Bearer $TOKEN" "$BASE/api/actions?limit=50"
```

## 8. GET /api/setup/status

First-run wizard state. **Pre-auth** (pinned no-auth).

Response `200` — `SetupStatusResponse`:

```json
{ "needsSetup": true, "clientConfigured": false }
```

`needsSetup` = no users exist yet; `clientConfigured` = the wizard has persisted a verified client connection (`settings` key `client_configured`).

```bash
curl "$BASE/api/setup/status"
```

## 9. POST /api/setup/user

Create the **first admin user** (one-shot). Pre-auth, but self-guarded: once any user exists it always returns 409 — the 409 check takes precedence over validation. A UNIQUE-constraint race (two concurrent setup requests) also resolves to 409.

Request body: `{ "username": string, "password": string }` — username 3–64 chars of `[a-zA-Z0-9_.-]`, password at least 8 chars. Passwords are stored scrypt-hashed (`scrypt$<saltHex>$<hashHex>`).

Responses:

- `201` — `SessionResponse` (auto-login): `{ "token": "<base64url>", "expiresAt": <epoch ms> }` (30-day session).
- `400` — `ValidationErrorResponse`: `{ "error": "invalid user", "issues": ["username: ...", ...] }`.
- `409` — `{ "error": "setup already completed" }`.

```bash
curl -X POST -H "Content-Type: application/json" "$BASE/api/setup/user" \
  -d '{"username":"admin","password":"a-strong-password"}'
```

## 10. POST /api/setup/client

Configure the torrent client **with a live connection test**. Requires auth (bearer). The wizard's connection check uses the real qBittorrent adapter (Web API >= 2.11.0 + credentials); nothing is saved or applied unless the test succeeds.

Request body: `{ "url": string, "username": string, "password": string, "pollIntervalSeconds"?: integer 1..3600 }`. The client type is `qbittorrent`; an omitted poll interval keeps the current one.

On success: config persisted via `saveConfig`, hot-applied to the orchestrator, `client_configured` set to `'true'`.

Responses:

- `200` — `ConfigResponse` (merged config, password masked).
- `400` — `{ "error": "invalid client configuration", "issues": [...] }` (Zod validation).
- `422` — `{ "error": "<adapter message verbatim>" }` (connection test failed: unreachable, bad credentials, Web API too old).

```bash
curl -X POST -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  "$BASE/api/setup/client" \
  -d '{"url":"http://qbittorrent:8080","username":"admin","password":"qbit-password"}'
```

## 11. POST /api/auth/login

Username/password login. Pre-auth. Failures are **uniformly** `401 {"error":"invalid credentials"}` — never leaking whether the username or the password was wrong (a malformed body gets the same response).

Request body: `{ "username": string, "password": string }`.

Responses:

- `200` — `SessionResponse`: `{ "token": "<base64url>", "expiresAt": <epoch ms> }`. The raw token is never stored — only its sha256 hex. Expired sessions are pruned on each successful login.
- `401` — `{ "error": "invalid credentials" }`.

```bash
curl -X POST -H "Content-Type: application/json" "$BASE/api/auth/login" \
  -d '{"username":"admin","password":"a-strong-password"}'
```

## 12. POST /api/auth/logout

Revoke the presented session. **Always `204`**, no body: a static-token caller (or a malformed/missing header) is a no-op, since there is no session to revoke. Requires auth like any non-pre-auth route.

```bash
curl -X POST -H "Authorization: Bearer $TOKEN" "$BASE/api/auth/logout"
```

---

## Notes for API contributors

- The seven core endpoints (1–7) match spec §9; endpoints 8–12 are the first-run wizard + session auth extension documented in `AGENTS.md` (the spec's static-token-only wording is superseded; `ZEPHYRUS_TOKEN` remains valid as a secondary machine token).
- DTO types are pinned in `src/http/dto.ts`; controllers return `{ status, body }` results and routes translate them — keep that pattern when adding endpoints.
- Error bodies are always JSON objects with an `error` string; validation errors add an `issues` array of `"field: message"` lines.
- The dashboard polls these endpoints every 5 s; avoid breaking field names or status-code contracts. See [Dashboard](./dashboard) for the consumer side.
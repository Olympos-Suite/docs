---
title: "Troubleshooting"
description: "Degraded mode, safe mode, the auth-disabled warning, and fixes for common configuration and connection problems."
section: "User Guide"
order: 9
---

# Troubleshooting

Zephyrus is built to fail soft: a broken client connection degrades instead of crashing, and lost state fails safe instead of acting wrongly. This page explains those modes and the problems operators actually hit.

First stop for any issue — the status endpoint and the action log:

```bash
curl -H "Authorization: Bearer $ZEPHYRUS_TOKEN" http://localhost:9695/api/status
curl -H "Authorization: Bearer $ZEPHYRUS_TOKEN" "http://localhost:9695/api/actions?limit=50"
```

Every policy action is logged with a human-readable reason; the [dashboard](./dashboard)'s Action Log screen shows the same trail.

## Degraded mode (client unreachable)

When the torrent client cannot be reached or a poll fails, Zephyrus:

- logs a warning once (`client unreachable — entering degraded mode`) and keeps the **last known state**;
- retries with exponential backoff (1 s × 2^(attempt−1), capped at 5 minutes and never slower than the poll interval);
- reports `"status": "degraded"` and `client.connected: false` from `GET /api/status` — **the process does not crash**, the dashboard keeps working, and the Docker healthcheck keeps passing;
- recovers automatically when the client answers again (`client reachable again — recovered from degraded mode`), reconciling against a full snapshot.

While degraded, no policy actions are executed and the boot adoption sweep waits for the first successful evaluation.

A special case: **`ConnectionUnsupportedError`** (wrong credentials, unsupported client version, broken login) is logged at **error** level as `client connection unsupported`. Retries continue but cannot fix it — operator action is required. Check the message; it names the exact problem.

## Safe mode (unknown paused torrents)

Safe mode latches when a managed torrent is found paused in the client with no record that Zephyrus paused it; Zephyrus then refuses to resume that torrent — inaction over a possibly wrong action.

Zephyrus only ever resumes torrents it paused itself. If it finds a **managed** torrent paused in the client with no record of having paused it — after a database loss, or when the DB was deleted while torrents were paused — it:

- adopts the torrent as **not ours** and never touches it;
- latches `safeMode: true` for the process lifetime and logs a warning per torrent;
- lists the affected torrents in `GET /api/status` (`safeModeTorrents`) and in a dashboard banner.

This is the fail-safe direction: inaction instead of a possibly wrong resume. The system keeps running and manages everything else normally. To release a safe-mode torrent, resume it manually in the client (or let the owning app handle it); after a restart with an intact database, normal management resumes. Note that deleting the database also loses [pins](./prioritization) — those torrents return to normal management.

## Auth-disabled warning

If `ZEPHYRUS_TOKEN` is unset, startup logs:

> `ZEPHYRUS_TOKEN not set — static machine token unavailable; username/password sessions apply (auth fully open only during first-run setup)`

What this means in practice:

- The static machine token is unavailable; dashboard users sign in with username/password (30-day sessions).
- The API is fully open **only while no user account exists** — the first-run bootstrap window. Once the setup wizard creates the admin account, authentication is enforced regardless of the env token.
- In production, set `ZEPHYRUS_TOKEN` anyway: the Docker healthcheck uses it, and it is the simplest credential for scripts. The shipped compose file refuses to start without it.

## Common issues

### Locked out of the dashboard (forgot the admin password)

There is no password-reset endpoint in v1. Recovery options, in order of preference:

> [!WARNING]
> Option 2 deletes Zephyrus's database (`zephyrus.db`). Choose it only if you accept **all** of these consequences:
> - The **entire action log** is lost — all recorded history, where normally only rows older than 90 days are pruned at startup.
> - **All user [pins](./prioritization)** are lost; pinned torrents return to normal management.
> - Any **managed torrent currently paused** enters [safe mode](#safe-mode-unknown-paused-torrents) on the next boot and stays paused until you resume it manually in the client.
> - All dashboard accounts and login sessions are deleted — every browser is signed out and the setup wizard reopens (that is how this option resets the password).

1. **Sign in with the API token** — if `ZEPHYRUS_TOKEN` is set, use the login screen's "Use API token instead" mode. It works regardless of user accounts.
2. **Re-run first-run setup** — deleting the SQLite database (`zephyrus.db`) makes Zephyrus report `needsSetup` again (setup status is derived from the user count), reopening the wizard to create a fresh admin account. This is destructive: accept every consequence in the warning above before doing it.

A stale browser session simply bounces back to the login screen on the first `401`; expired sessions are pruned server-side on each successful login.

### Wrong qBittorrent credentials

**Symptom:** degraded mode, error log `client connection unsupported: qBittorrent login failed: invalid credentials`.
**Fix:** correct `client.username` / `client.password` in `config.yaml`. With `password: env:QBIT_PASSWORD`, verify the variable is actually set in Zephyrus's environment (a missing variable fails startup with `Missing environment variables referenced in config: QBIT_PASSWORD` — it cannot silently produce a wrong password). The setup wizard's connection test reports credential failures before saving anything.

### WebUI disabled or unreachable

**Symptom:** degraded mode, warning `client unreachable` with a connection error.
**Fix:** enable the WebUI in qBittorrent (Tools → Options → Web UI); verify `client.url` (scheme, host, port) is reachable *from the Zephyrus container/host* — on Docker networks use the service name (`http://qbittorrent:8080`), not `localhost`. Check firewalls and that the WebUI port is the one you think it is.

### qBittorrent version too old

**Symptom:** `qBittorrent 5.x (Web API >= 2.11.0) required, found 2.x.y — upgrade the client`.
**Fix:** upgrade to qBittorrent 5.x. The adapter uses v5-only endpoints (`torrents/stop`/`start`) and state names (`stoppedDL`); 4.x cannot work. Unrecognized client states degrade to `unknown` and are ignored by policy rather than crashing.

### Port conflicts

**Symptom:** startup fails with a listen error (`EADDRINUSE`), or the dashboard is unreachable.
**Fix:** `server.port` (default `3030`) must be free inside the container/host; the compose mapping `"9695:3030"` must not collide with another host service. Change `server.port` and the mapping together. Remember other suite apps use different ports (Eros `9697`, Psyche `9698`), so a conflict usually means a second Zephyrus instance or an unrelated service.

### Configuration validation errors

**Symptom:** startup fails with `Invalid configuration in "config.yaml":` followed by one `path: message` line per problem; or `PUT /api/config` returns `400` with an `issues` array. Nothing is applied on failure.
**Fix:** read the listed paths — every issue is reported at once. Frequent ones:

| Issue | Cause |
|-------|-------|
| `stalled.retry.max_interval_minutes … must be >= … interval_minutes` | Backoff ceiling below the base interval. |
| `Profile name "paused" is reserved` | You defined a speed profile named `paused`; it is the pause-window keyword. |
| `Window references unknown profile "…"` | Typo in a window's `profile`, or the profile was renamed. |
| `At least one managed group must be defined under "groups"` | Empty `groups` block. |
| `Invalid speed: …` | A rate string without a `b`/`B` unit (e.g. `"25 K"`), or a negative number. See [speed values](./configuration#speed-values). |
| `Invalid IANA time zone` | `timezone` is not a valid zone name. |
| `completion_bias tiers must be strictly ascending` | Duplicate or out-of-order `min_progress` values. |
| `Must be a strict 24-hour "HH:MM" time string` | `from`/`to` like `"8:00"` or `"24:00"`. |

Unknown keys are stripped silently (including the legacy `stalled.speed_floor_bytes` and `stalled.slow.threshold_minutes`), so old config files load without error.

### Torrents are not being managed

**Symptom:** torrents download but Zephyrus never touches them; they don't appear in the dashboard's Torrents screen.
**Fix:** management is exact group matching. The torrent's qBittorrent **category** must equal a key of `config.groups` (case-sensitive). Groupless torrents and unlisted categories are untouchable by design — see [Integration](./integration). Also check you're looking at the right Zephyrus instance: one instance watches one client.

### A paused torrent is not resuming

Work through the reasons in order:

1. **Was the pause yours or an app's?** Zephyrus never resumes those — check `pausedByUs` in `GET /api/torrents`.
2. **Multiple pause reasons.** A torrent paused by both queue and schedule only resumes when *all* reasons clear; `pauseReason` shows the highest-priority one (`schedule` > `stalled` > `slow` > `queue`).
3. **Queue cooldown.** Just-paused queue waiters wait out `max(2× poll interval, 60 s)` before they become resume-eligible — this is deliberate anti-flapping hysteresis.
4. **Caps are full.** Resumes need a free global *and* group slot; pinned torrents consume slots too.
5. **Stalled retry eligibility.** Retries need `stalled` as the only reason, an elapsed backoff interval, and a leftover slot — at most one retry per evaluation. A `givenUp` torrent only retries while the system is idle (or with a matching completion-bias tier).

### Everything paused right after startup

That is the [boot adoption sweep](./smart-queuing#boot-adoption-sweep) — see the "What to expect at first startup" note there. Zephyrus stops managed started-phase torrents it didn't pause, then resumes the top set by weight/FIFO after the resume cooldown (at least 60 s). Seeding torrents and user/app pauses are never touched. Give it a minute before investigating.

### Speed limits are not applied

**Symptom:** a limited schedule window is active but torrents run uncapped; the action log shows `speed limits skipped: adapter lacks capability`.
**Fix:** check the capability chips on the Overview screen (`downloadLimit` / `uploadLimit`). The qBittorrent adapter supports both; a future adapter without the capability disables the feature with a note instead of failing. Also remember limits are per-torrent *shares* of the aggregate cap — with one active torrent, its share equals the full total.

### Config save fails with 400

`PUT /api/config` (and the dashboard save) reports `issues` per field path. A password of `***` means "keep the current secret" — anything else is treated as a new literal password or `env:NAME` reference. If the file write fails after a successful hot-reload, the response says so explicitly; the running config is already updated, but fix the disk problem (permissions on `/config`) and save again.

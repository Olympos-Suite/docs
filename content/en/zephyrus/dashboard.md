---
title: "Dashboard"
description: "First-run setup, login, and the Overview, Torrents, Action Log, and Configuration screens."
section: "User Guide"
order: 7
---

# Dashboard

Zephyrus ships a web dashboard served by the same Fastify process as the API — open `http://<host>:9695` and everything is there. It is a React + Vite single-page app (Tailwind v4 + shadcn/ui), **dark-only** by design, built for readability rather than spectacle. The compiled assets (`web/dist`) are served statically by Fastify; hash-based routing means no server-side route configuration is needed. Data screens poll every 5 seconds and pause polling while the browser tab is hidden.

## First-run setup

On a fresh install (no admin account in the database), the dashboard opens a two-step **setup wizard** instead of the login form:

1. **Create admin account** — username (3–64 characters; letters, digits, dot, underscore, hyphen) and password (at least 8 characters, with confirmation). Creating the account signs you in immediately. The wizard closes permanently once a user exists — later attempts return "setup already completed".
2. **Connect torrent client** — enter the qBittorrent WebUI URL, username, password, and optionally the poll interval. Zephyrus **tests the connection with the real adapter before saving anything**: it verifies Web API ≥ 2.11.0 and the credentials. On failure nothing is saved and the adapter's error message is shown verbatim; on success the client block is written to `config.yaml` and hot-applied.

If you skipped step 2, the Overview screen shows a "No torrent client connected yet" banner with a **Connect client** dialog that runs the same verified flow.

Connecting the client is only half of the contract: Zephyrus then manages only torrents whose category exactly matches a configured group key — see the [group contract](#torrents) below.

## Login

The login screen supports two modes:

- **Username and password** (default) — the admin account created during setup. Passwords are stored scrypt-hashed; sign-in issues a session bearer token valid for **30 days** (only its hash is stored server-side), kept in your browser only.
- **API token** — switch via "Use API token instead" to a single-field form: paste the static `ZEPHYRUS_TOKEN` and sign in. This is the secondary machine-token path, useful for scripts — and it works even on a user-less install, before the wizard has run.

Both token kinds work against every API route (`Authorization: Bearer <token>`). Logout revokes the server-side session and clears the browser token. See [Troubleshooting](./troubleshooting) for what happens when `ZEPHYRUS_TOKEN` is unset.

## Overview

The status page, refreshing every 5 s:

- **Banners** — a degraded-mode banner when the client is unreachable, a safe-mode banner listing managed torrents paused by someone other than Zephyrus (see [Troubleshooting](./troubleshooting)), and the client-connect prompt when no client is configured yet.
- **Stat cards** — total torrents in the client, managed torrents, and torrents currently paused by Zephyrus.
- **Client connection card** — client type, URL, connection state, capability chips (reannounce, download limit, upload limit), uptime, and Zephyrus version.
- **Counts** — managed torrents broken down by canonical state and by group.

## Torrents

The managed-torrent list (only torrents in configured groups appear):

> [!IMPORTANT]
> Zephyrus manages **only** torrents whose qBittorrent category **exactly matches** a key of `config.groups` — the match is **case-sensitive** (`Eros` does not match `eros`). Torrents in any other category, and torrents with no category at all, are **untouchable by design**: never paused, resumed, or limited. They do not appear on this screen. See [Integration](./integration) for the full contract.

- **Columns** — pin toggle, name (with copyable info hash), group, state, download speed, progress bar + percentage, size, and added time. All sortable.
- **State badges** show the canonical state plus Zephyrus markers: whether the pause is ours and its reason (`queue` / `stalled` / `slow` / `schedule`), and a retry badge with the stalled retry count, give-up status, and any matching completion-bias tier.
- **Filters** — free-text search plus group and state filters, with a visible/total counter.
- **Pinning** — the pin toggle on each row calls `POST` / `DELETE /api/torrents/:infoHash/pin`; the row refreshes from server truth right away. See [Prioritization](./prioritization).

## Action Log

The audit trail (`action_log`), newest first:

- Every policy action is logged with a human-readable reason: `pause`, `resume`, `reannounce`, `limit`, `unmanage`, `note`.
- Limit syncs appear as **single summary rows** (no torrent hash) ending in "(N torrents)" — per-torrent limit rows would flood the log without adding signal.
- Filter chips per action kind and free-text search; rows repeating the same action on the same torrent (3+ times) are flagged so churn is visible at a glance.
- The log loads in windows of 500 rows with a load-more control. Rows older than 90 days are pruned at startup.

This is the first place to look when a torrent behaves unexpectedly — the reason string tells you exactly which policy acted and why. For what the retry counts and completion-bias tiers on torrent rows mean, see [Stalled management](./stalled-management) — the [retry cycle](./stalled-management#retry-cycle-with-growing-backoff) and [completion bias](./stalled-management#completion-bias-optional).

## Configuration

A tabbed form editor for the whole `config.yaml`:

- **Tabs** — Client, Global & Groups, Schedule (profiles + windows), and Stalled (threshold, retry, slow, completion bias).
- **Validation** — client-side pre-flight checks (URL shape, unique group/profile names, rate strings, window references, tier ordering) plus the authoritative server-side Zod validation on save. Errors are listed per field path.
- **Saving** — a confirmation dialog, then `PUT /api/config`: the config is validated, **hot-reloaded** (no restart), and persisted atomically to `config.yaml`. The client password is shown masked (`***`); leaving it masked keeps the current secret, and an `env:NAME` reference on disk stays a reference. See [Configuration](./configuration) for the full semantics.
- Unsaved changes are tracked; discarding asks for confirmation, and fresh server data is adopted only when you have no local edits to lose.

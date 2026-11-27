---
title: "Configuration"
description: "Complete config.yaml reference: client, groups, stalled policy, schedule, server, env resolution, hot-reload, and speed units."
section: "User Guide"
order: 2
---

# Configuration

Zephyrus is configured through a single YAML file, validated with Zod at startup. Invalid configuration fails boot with a clear error listing **every** problem (one `path: message` line per issue), never a raw stack of JSON.

- **Path:** `ZEPHYRUS_CONFIG` environment variable, or `./config.yaml` by default. The Docker image sets it to `/config/config.yaml`.
- **First boot:** if the file is missing, Zephyrus writes a self-contained default configuration and continues (with a warning). An empty mounted `/config` volume therefore boots instead of crashing.
- **Secrets:** use the `env:NAME` placeholder syntax instead of inline passwords (see [env: resolution](#envname-resolution)).
- **Editing:** edit the file and restart, or use the dashboard's Configuration screen / `PUT /api/config`, which validates, hot-reloads, and persists atomically (see [Hot-reload](#hot-reload-put-apiconfig)).

## Full example

This mirrors the repository's `config.example.yaml`:

```yaml
client:
  type: qbittorrent            # v1 ships exactly this adapter
  url: http://qbittorrent:8080
  username: admin
  password: env:QBIT_PASSWORD  # env: prefix = read from environment variable
  poll_interval_seconds: 5

timezone: Europe/Istanbul

global:
  max_active_downloads: 6

groups:                        # keys = managed groups; everything else is untouchable
  eros:
    max_active_downloads: 4
    weight: 10
  psyche:
    max_active_downloads: 3
    weight: 5

stalled:
  threshold_minutes: 30        # single continuous wait shared by stalled pause and slow yield
  retry:
    interval_minutes: 15       # base wait before a stalled retry
    backoff_multiplier: 2      # wait = interval × multiplier^(consecutive no-progress retries)
    max_interval_minutes: 1440 # backoff ceiling (24 h)
    progress_reset_bytes: 10485760  # meaningful-progress threshold (10 MiB; proportional, see below)
    give_up_hours: 72
  slow:                        # optional slot-yielding for slow-but-downloading torrents
    speed_floor_bytes: 5242880 # below this speed (5 MiB/s) = "slow"
  completion_bias:             # optional: extra patience near completion
    tiers:                     # strictly ascending min_progress; highest matching tier applies
      - min_progress: 0.5
        give_up_multiplier: 2
        max_retry_interval_minutes: 360
      - min_progress: 0.9
        give_up_multiplier: 5
        max_retry_interval_minutes: 120
      - min_progress: 0.99
        give_up_multiplier: 10
        max_retry_interval_minutes: 60

schedule:
  profiles:
    full:
      download: 0              # 0 = unlimited
      upload: 0
    night_limited:
      download: "25 MB/s"      # TOTAL bandwidth across active managed torrents,
      upload: "5 MB/s"         # split equally per active torrent
  windows:
    - days: [mon, tue, wed, thu, fri]
      from: "08:00"
      to: "01:00"              # crosses midnight — supported by design
      profile: night_limited
    - days: [mon, tue, wed, thu, fri]
      from: "01:00"
      to: "08:00"
      profile: full
    - days: [sat, sun]
      from: "00:00"
      to: "23:59"
      profile: full

server:
  port: 3030
  log_level: info
```

Every field except `client.type` is client-agnostic; a future adapter only extends the `client` block.

## `client`

| Field | Type / constraint | Default | Description |
|-------|-------------------|---------|-------------|
| `type` | literal `qbittorrent` | — (required) | The only adapter shipped in v1. |
| `url` | valid URL | — (required) | WebUI base URL, e.g. `http://qbittorrent:8080`. There are no separate host/port fields. |
| `username` | non-empty string | — (required) | WebUI username. |
| `password` | non-empty string | — (required) | WebUI password. Prefer `env:QBIT_PASSWORD`. |
| `poll_interval_seconds` | positive integer | `5` | How often Zephyrus polls the client (`sync/maindata` incremental sync). Also derives the resume grace window (2× poll) and caps reconnect backoff. |

The adapter requires qBittorrent 5.x with Web API ≥ 2.11.0. Changing any of `type`, `url`, `username`, or `password` via hot-reload recreates the adapter and reconnects.

## `timezone`

IANA time zone name (validated via `Intl.DateTimeFormat`), default `Europe/Istanbul`. All schedule windows are evaluated in this zone. The container's `TZ` variable does not affect schedule evaluation.

## `global`

| Field | Type / constraint | Description |
|-------|-------------------|-------------|
| `max_active_downloads` | integer ≥ 1, required | Global ceiling on the **started set** of managed torrents (downloading + checking + queued + stalled). See [Smart queuing → The started set](./smart-queuing#the-started-set). |

## `groups`

The keys of this record **are** the managed groups — there is no separate `managed_groups` list. At least one group must be defined. Torrents in any other group, or with no group, are never touched.

| Field (per group) | Type / constraint | Default | Description |
|-------------------|-------------------|---------|-------------|
| `max_active_downloads` | integer ≥ 1, optional | none | Per-group ceiling on started torrents. Omit for no group ceiling beyond the global one. |
| `weight` | integer | `0` | Resume priority: higher weight resumes first. Also the inverse pause order (lowest weight paused first). See [Prioritization](./prioritization). |

Removing a group from the config releases its torrents: Zephyrus resumes any it had paused, clears any per-torrent limits it applied, and logs an `unmanage` action.

## `stalled`

The whole block is optional and defaults sensibly; see [Stalled management](./stalled-management) for the behavior these keys drive.

| Field | Type / constraint | Default | Description |
|-------|-------------------|---------|-------------|
| `threshold_minutes` | positive integer | `30` | Continuous stalled time before Zephyrus pauses a torrent. **Also** the shared wait for the optional slow detector — `slow` has no threshold of its own. |

### `stalled.retry`

| Field | Type / constraint | Default | Description |
|-------|-------------------|---------|-------------|
| `interval_minutes` | positive integer | `15` | Base wait before the first retry, measured from the threshold pause. |
| `backoff_multiplier` | integer ≥ 1 | `2` | Wait = `interval_minutes × multiplier^retryCount`. Set `1` for a fixed interval (the documented opt-out of backoff growth). |
| `max_interval_minutes` | positive integer, must be ≥ `interval_minutes` | `1440` (24 h) | Backoff ceiling. A cap below the base interval is rejected at validation. |
| `progress_reset_bytes` | integer ≥ 1 | `10485760` (10 MiB) | Meaningful-progress threshold that resets the backoff exponent. The effective threshold is proportional: `min(progress_reset_bytes, half of what remained at the last retry)`, floored at 1 byte. `0` is rejected — use `backoff_multiplier: 1` instead. |
| `give_up_hours` | positive integer | `72` | After this long without completing (measured from the first threshold pause), the torrent is flagged `givenUp`: a warning is logged and it is retried only as a last resort. |

### `stalled.slow` (optional)

| Field | Type / constraint | Default | Description |
|-------|-------------------|---------|-------------|
| `speed_floor_bytes` | integer ≥ 0 | `5242880` (5 MiB/s) | A `downloading` torrent continuously below this speed for `threshold_minutes` yields its slot — but only while other torrents are waiting for a slot. Absent block = slow detection disabled. |

### `stalled.completion_bias` (optional)

A `tiers` array (at least one tier). Tiers must be **strictly ascending** by `min_progress`; the highest tier whose `min_progress` ≤ the torrent's current progress applies. Absent block = no bias.

| Field (per tier) | Type / constraint | Description |
|------------------|-------------------|-------------|
| `min_progress` | number in `[0, 1)` | Progress threshold. `1` is rejected (already complete). |
| `give_up_multiplier` | finite number ≥ 1 | Extends the give-up window to `give_up_hours × multiplier`. |
| `max_retry_interval_minutes` | positive integer | Tighter retry ceiling: the effective wait is capped at `min(max_interval_minutes, this value)`. |

### Legacy keys

Unknown keys are stripped, not rejected. Old configs carrying `stalled.speed_floor_bytes` or `stalled.slow.threshold_minutes` (both removed from the schema) load cleanly; the stale values are silently dropped.

## `schedule`

Required block with two parts; see [Weekly schedule](./weekly-schedule) for semantics.

- **`profiles`** — a record of named speed profiles. Each has `download` and `upload` [speed values](#speed-values). Profile names are free-form, with one exception: **`paused` is reserved** — a window pointing at the literal profile name `paused` is a pause window (all managed torrents paused), and defining a speed profile named `paused` is a validation error. A profile with `0` values means unlimited.
- **`windows`** — an array (may be empty = always unlimited). Each window:

| Field | Type / constraint | Description |
|-------|-------------------|-------------|
| `days` | array of `mon`…`sun`, ≥ 1 entry | The days the window **opens**. |
| `from` / `to` | strict 24-hour `"HH:MM"` | `from > to` is valid and means a midnight-crossing window. `from == to` is a zero-length window that never activates. `to` is exclusive. |
| `profile` | non-empty string, must reference a defined profile (or `paused`) | Unknown references are rejected with the list of defined profiles. |

The first matching window in array order wins; no match means unlimited.

## `server`

| Field | Type / constraint | Default | Description |
|-------|-------------------|---------|-------------|
| `port` | integer 1–65535 | `3030` | HTTP listen port (API + dashboard). |
| `log_level` | `debug` \| `info` \| `warn` \| `error` | `info` | Pino log level. `LOG_LEVEL` env overrides it; hot-reload applies changes live. |

## `env:NAME` resolution

Any string value in the YAML that is **exactly** `env:NAME` (pattern: `env:` followed by a letter/underscore, then letters/digits/underscores) is replaced with the value of environment variable `NAME` before validation. The walk is deep — it works at any position, not just `client.password`.

```yaml
client:
  password: env:QBIT_PASSWORD
```

- A value like `env:QBIT_PASSWORD` embedded in a longer string is **not** a reference; only exact matches resolve.
- If any referenced variable is missing, startup fails with a single error naming **all** missing variables at once: `Missing environment variables referenced in config: QBIT_PASSWORD, ...`.
- The same resolution runs on `PUT /api/config` bodies, so a submitted `env:NAME` reference never reaches the torrent client as a literal password.

## Hot-reload (`PUT /api/config`)

`GET /api/config` returns the active configuration with `client.password` masked as `***`. `PUT /api/config` accepts `{ "config": { ... } }` (a bare config object is also tolerated) and:

1. Treats a submitted password of `***` as "keep the current secret".
2. Resolves `env:NAME` references, then validates with the same Zod schema as boot. Failure → `400` with `{ error, issues: ["path: message", ...] }`; nothing is applied.
3. Applies the new config in memory (hot-reload): client-block changes recreate the adapter and reconnect; a changed poll interval resets the poll timer; `log_level` applies live; applied schedule limits are invalidated and re-applied on the next evaluation.
4. Persists to the booted `config.yaml` **atomically** (temporary file + rename). If the file on disk references the password via `env:NAME`, that exact reference is written back — the resolved secret never leaks into the YAML.
5. Returns the masked config. If the file write fails, the hot-reload stays applied and the failure is reported as an issue.

```bash
# Read the active config (password masked)
curl -H "Authorization: Bearer $ZEPHYRUS_TOKEN" http://localhost:9695/api/config

# Update the global cap without touching anything else:
# fetch the config, edit it, and PUT it back with the password left as "***"
curl -X PUT -H "Authorization: Bearer $ZEPHYRUS_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"config": { ... , "client": { ..., "password": "***" }, "global": {"max_active_downloads": 8}}}' \
  http://localhost:9695/api/config
```

The dashboard's Configuration screen uses this same endpoint. See the [API reference](./api-reference) for the full route table.

## Speed values

Schedule profile `download`/`upload` fields accept a plain number or a unit string. Everything is normalized to bytes/s internally. This table is the **authoritative unit reference** for the whole guide — other pages summarize it and link here.

| Format | Meaning | Base | Conversion to bytes/s |
|--------|---------|------|-----------------------|
| Plain number: `15000`, `0` | KiB/s (the qBittorrent convention) | 1024 | number × 1024; `0` = unlimited |
| `kb`, `mb`, `gb` (trailing lowercase `b`) | bits | 1000 | × 1000 / 1000² / 1000³, then ÷ 8 |
| `kbit` / `kbps`, `mbit` / `mbps`, `gbit` / `gbps` | bits | 1000 | same as the row above |
| `KB`, `MB`, `GB` (trailing uppercase `B`) | bytes | 1024 | × 1024 / 1024² / 1024³ |
| `KiB`, `MiB`, `GiB` (also written `kB`, `kib`, `mib`, `gib`) | bytes | 1024 | same as the row above |
| Bare `B` with no prefix: `"1875000 B/s"` | exact bytes/s | — | the number itself |

Rules that apply to every string form:

- Case matters **only for the trailing `b`/`B`**: lowercase `b` = bits (base 1000, ÷ 8), uppercase `B` = bytes (base 1024). Prefixes and the `bit`/`bps`/`ib` tails are case-insensitive — `"15 Mbps"`, `"15 mbps"`, and `"15 mbit"` all parse identically.
- An optional `/s` suffix is allowed.
- A unit must contain `b`/`B` — `"25 K"` is invalid, as is a negative number.
- The bare-`B` form exists for totals that are not multiples of 1024 (for example the 1,875,000 bytes/s behind `"15000 kb"`), so they round-trip exactly.

**Examples:**

| Input | Interpretation | Bytes/s |
|-------|----------------|---------|
| `15000` | 15000 KiB/s = 15 MiB/s | 15,360,000 |
| `0` | unlimited | 0 |
| `"15000 kb"` / `"15 Mbps"` / `"15 mbit"` | 15 Mbit/s (15,000,000 bits ÷ 8) | 1,875,000 |
| `"1 kbit"` | 1000 bits ÷ 8 | 125 |
| `"25 MB/s"` / `"25 MiB/s"` | 25 × 1024² bytes | 26,214,400 |
| `"500 KB/s"` / `"500 KiB"` | 500 × 1024 bytes | 512,000 |
| `"1 GB/s"` | 1024³ bytes | 1,073,741,824 |
| `"1 gbps"` | 10⁹ bits ÷ 8 | 125,000,000 |
| `"1875000 B/s"` | exact bytes | 1,875,000 |

**Lossless save → load.** When the config is persisted (dashboard save or `PUT /api/config`), profile speeds are written in canonical string form: multiples of 1024 become `"N KiB/s"`, odd totals become `"N B/s"`, and `0` stays `0`. A parsed bytes/s number is never written back as a bare number — that would inflate it ×1024 on the next load, since plain numbers always mean KiB/s.

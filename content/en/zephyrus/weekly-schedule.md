---
title: "Weekly schedule"
description: "Day/hour windows mapped to speed profiles: unlimited, aggregate bandwidth caps, or full pauses."
section: "User Guide"
order: 5
---

# Weekly schedule

The weekly schedule applies day + hour **windows**, each pointing at a **profile**. It is how you say "full speed at night, capped during the day, paused while I'm on video calls" — without touching qBittorrent's global settings.

```yaml
timezone: Europe/Istanbul

schedule:
  profiles:
    full:
      download: 0          # 0 = unlimited
      upload: 0
    night_limited:
      download: "25 MB/s"  # TOTAL bandwidth, split across active managed torrents
      upload: "5 MB/s"
  windows:
    - days: [mon, tue, wed, thu, fri]
      from: "08:00"
      to: "01:00"          # crosses midnight
      profile: night_limited
    - days: [mon, tue, wed, thu, fri]
      from: "01:00"
      to: "08:00"
      profile: full
    - days: [sat, sun]
      from: "00:00"
      to: "23:59"
      profile: full
```

## How windows resolve

- Every evaluation resolves the current time in the configured `timezone` (an IANA zone name, validated at load) and walks the windows **in array order — the first match wins**. Overlapping windows are therefore legal; order them deliberately.
- **No matching window = unlimited.** Unlisted time runs at full speed; you only need to describe the exceptions. An empty `windows: []` (the first-boot default) means always unlimited.
- A window's `days` list the days it **opens**; `from`/`to` are strict 24-hour `"HH:MM"` strings; `to` is exclusive (a 22:00–06:00 window ends exactly at 06:00).
- A per-minute cron tick watches for window transitions and forces an evaluation immediately when the active window changes, so boundaries are honored within a minute even between polls.

## Profile kinds

**Unlimited (`full` in the example).** A profile whose `download`/`upload` values are `0` removes all per-torrent limits Zephyrus applied. Any previously limited torrent gets `clearLimits`; unmanaged torrents were never limited in the first place.

**Limited.** The profile's `download` and `upload` values are **aggregate bandwidth ceilings across all managed torrents**, not per-torrent limits. On every evaluation tick the total is split **equally** across the managed torrents active at that moment:

| Share | Divisor (active managed torrents in these states) |
|-------|---------------------------------------------------|
| Download | `downloading` + `stalled` |
| Upload | `downloading` + `stalled` + `seeding` |

Each share is `floor(total / n)`, floored at 1 byte/s so a share can never accidentally read as "unlimited" (`0`). If no torrent is active, the full total is reserved for the next one that starts. When the active count changes — a torrent completes, is paused, or is adopted — the shares are recomputed and re-applied automatically.

Example: `download: "25 MB/s"` with 5 active downloaders gives each torrent a 5 MB/s limit. A sixth starts → everyone drops to ~4.16 MB/s; one completes → the remaining five rise again. The aggregate never exceeds 25 MB/s.

Details that keep this clean:

- **Paused torrents get no limits** — they transfer nothing, so limiting them would be pure churn. A torrent resumed inside a limited window receives its share on the first tick after resume (within one poll interval).
- Limits are applied as **per-torrent limits** through the adapter (`setDownloadLimit` / `setUploadLimit` / `clearLimits`). The client's global settings are never touched, and unmanaged/groupless torrents are never limited.
- Each limit change writes **one summary row** to the action log (with the affected torrent count), not one row per torrent — the log stays readable.
- If the adapter lacks speed-limit capability, the feature is skipped and a note is recorded in the action log instead of failing.

**Paused (reserved keyword).** A window whose `profile` is the literal name `paused` pauses **all managed torrents** (`pausedByUs=true`, reason `schedule`) for the duration of the window. Torrents already paused by you or an app are left alone. When the window ends, each torrent returns to its previous state — it is resumed only if no other pause reason (queue, stalled, slow) still holds it. You cannot define a speed profile named `paused`; the schema rejects it.

## Midnight-crossing windows

`from > to` is valid by design and means the window crosses midnight:

```yaml
- days: [fri]
  from: "22:00"
  to: "06:00"
  profile: night_limited
```

This window is active from **Friday 22:00 to Saturday 06:00**. The rule: the evening part matches when the current day is in `days` and the time is ≥ `from`; the morning tail matches when the time is < `to` and the *previous* day is in `days`. So `days` always names the day the window opens, never the day it ends.

A second example — a weeknight window that ends mid-morning:

```yaml
- days: [thu]
  from: "21:00"
  to: "09:00"
  profile: night_limited
```

This window is active from **Thursday 21:00 to Friday 09:00**:

- **Thursday evening (21:00–23:59):** the current day (`thu`) is in `days` and the time is ≥ `21:00` — the evening part matches.
- **Friday morning tail (00:00–08:59):** the time is < `09:00` and the *previous* day (`thu`) is in `days` — the tail matches, even though Friday itself is not listed.
- **Friday 09:00:** `to` is exclusive, so the window ends exactly at 09:00.
- **Friday 21:00 and Saturday 08:00:** not active — Friday is not in `days` (no evening part), and Saturday's previous day (Friday) is not in `days` either (no morning tail).

A window with `from == to` is a degenerate zero-length window and never activates.

## Speed units

Profile values follow the shared [speed-value rules](./configuration#speed-values); the authoritative unit table lives in Configuration. In short: a plain number is **KiB/s** (`0` = unlimited), lowercase-`b` units (`kb`, `Mbps`, `mbit`) are decimal bits ÷ 8, uppercase-`B` units (`KB`, `MiB`, `GB`) are binary bytes, and a bare `B` (`"1875000 B/s"`) is exact bytes/s.

Saving is lossless: when the config is written back to disk (dashboard save or `PUT /api/config`), speeds are stored in canonical string form (`"15000 KiB/s"`, `"1875000 B/s"`, or `0`), so a save → load cycle never reinterprets or inflates a value. See [Configuration → Speed values](./configuration#speed-values) for the full table and examples.

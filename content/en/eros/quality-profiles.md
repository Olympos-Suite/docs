---
title: "Quality Profiles"
description: "Ordered quality preference lists that gate every subscription download: seeded profiles, preference structure, elimination and selection, and the megapack exemption."
section: "User Guide"
order: 50
---

A quality profile is an **ordered list of preferences** that decides which torrent Eros may download for a subscription. Each preference is one rung: *quality × source × minimum seeders × maximum size*. Preferences are tried in ascending `priority` (lower = tried first); the **first preference with a matching group member wins**. There is **no unconstrained fallback**: a subscription without a profile, or a group matching no preference, downloads nothing — the reason is logged. You build your own fallback by adding an `any`/`any` rung as the last entry.

Profiles are managed under **Settings → Quality profiles** (`/api/quality-profiles`). Every subscription must carry one: creation requires a profile id, and clearing it later is rejected.

## Seeded profiles

On first boot, four profiles are seeded **only when the table is empty** — deleted profiles are never resurrected on later boots. `HD 1080p` carries the default flag.

| Profile | Default | Preferences (priority order) |
|---------|---------|------------------------------|
| **4K Ultra** | no | 2160p bluray (≥3 seeders, ≤60 GB) → 2160p webdl (≥3, ≤50) → 2160p webrip (≥2, ≤50) → 1080p bluray (≥2, ≤30) → 1080p webdl (≥2, ≤25) |
| **HD 1080p** | **yes** | 1080p bluray (≥2, ≤25) → 1080p webdl (≥2, ≤20) → 1080p webrip (≥1, ≤20) → 720p bluray (≥1, ≤15) → 720p webdl (≥1, ≤15) |
| **SD Compact** | no | 720p webdl (≥1, ≤10) → 720p webrip (≥1, ≤10) → 480p any (≥1, ≤5) → any/any (≥1, ≤5) |
| **Any Quality** | no | any/any (≥1 seeder, ≤50 GB) |

The trailing `any`/`any` rung in *SD Compact* and *Any Quality* is an explicit user fallback — the gate never invents one on its own.

## Preference structure

Each preference has five fields:

| Field | Values | Meaning |
|-------|--------|---------|
| `quality` | `2160p`, `1080p`, `720p`, `480p`, `any` | Resolution asked for; `any` is a wildcard. |
| `source` | `bluray`, `webdl`, `webrip`, `hdtv`, `dvd`, `any` | Source asked for; aliases normalized (`web-dl`/`web dl` → `webdl`, `blu-ray`/`blueray` → `bluray`, `web-rip` → `webrip`). |
| `minSeeders` | integer ≥ 0 (default 1) | Seeder floor. |
| `maxSizeGB` | positive number (default 50) | Hard size ceiling in GB. |
| `priority` | positive integer | Try order — lower first. |

A group member matches a preference when quality and source agree, `seeders ≥ minSeeders`, and size ≤ `maxSizeGB`. Releases whose titles carry no quality/source tags parse as `any`/`any`: they may match any preference, but a member with **explicitly matching** quality and source always wins over an untagged one within the same preference — an untagged release is the fallback, never the winner.

Profiles require a non-empty name and at least one preference; editing replaces the preference list as one unit. Names are per-user, and the UI offers edit/duplicate/delete with a confirmation on delete.

## Elimination, then selection

For each accepted [torrent group](./torrent-grouping), selection runs in two stages:

1. **Elimination** — preferences are tried in priority order. For each, every group member is checked against quality/source/seeders/size. The first preference with at least one matching member wins; if none matches, the group is skipped with the reason `No torrent matched any quality preference (…)`.
2. **Selection** — among the members matching the winning preference, the best is picked by: **spam-free title** > **resolution score** (`2160p=4, 1080p=3, 720p=2, 480p=1`, unknown 0) > **explicit source over unknown** > (during group fallback) a soft indexer-diversity tiebreak > **seeder count**. The diversity tiebreak prefers indexers that have not already failed for this group, but never excludes a candidate. This supersedes the provisional `bestTorrent` picked during [grouping](./torrent-grouping).

### The infoHash fallback

The selected member must have a usable infoHash — the queue is keyed by it. When it has none:

1. Another group member **matching the same preference** and carrying a hash is selected instead (same ranking).
2. If no hash-bearing sibling matches, the real hash is resolved from the selected member's own download link — the magnet's `btih`, or the SHA-1 of the fetched `.torrent`'s `info` dictionary.
3. Only when neither works is the group skipped. Hashless-indexer results stay downloadable; placeholder hashes are never stored.

## The default profile

**At most one** profile per user may carry `isDefault`: creating or updating a profile with the flag clears the previous default server-side. The default is a convenience, not a search-time rule:

- The subscribe dialog preselects the default profile once on load; you can pick another before confirming.
- The API requires an explicit profile id at creation — nothing is stamped implicitly.
- A subscription's profile can be switched but never removed (`null` is rejected).

> [!WARNING]
> Deleting a profile that subscriptions still reference is allowed, and those subscriptions keep pointing at the missing id. Their searches then skip every group with `No quality profile attached` until you assign a new profile. Deletion is confirmed in the UI; there is no undo, and boot never re-seeds deleted profiles.

## The megapack exemption

The [megapack first pass](./subscriptions) bypasses quality preferences entirely: packs are admitted on freshness, ownership, and seeder ranking alone, gated only by the per-subscription `includeMegapacks` opt-in (default off) and the `max_megapacks_per_run` cap. A 60 GB site pack cannot satisfy a `≤25 GB` rung, so applying the profile would make the feature useless; duplicate content inside packs is handled per file by hash instead. [Group fallback](./torrent-grouping) likewise exempts megapacks.

## Quality upgrades

With `upgrade_scene_quality` enabled (default **off**), the gate also ranks releases for *replacement*: when a search finds content the library already owns (durable group-member history) and the candidate ranks **strictly higher** under the profile, it is downloaded as a replacement. Ranking puts the preference slot first (stride 10) and the resolution ladder (`2160p > 1080p > 720p > 480p > unknown`) as the tiebreak within a slot; untagged releases rank conservatively so a re-download of the same resolution never triggers an upgrade. The existing scene must be finalized and have no active download; the old scene is deleted only after the replacement completes and organizes. Mechanics live in [Download management](./download-management).

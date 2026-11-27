---
title: "Quality Profiles"
description: "Ordered quality preferences that gate every grab: the seeded profiles, preference structure, default semantics, and assignment."
section: "User Guide"
order: 50
---

A quality profile is an **ordered list of preferences** that decides which releases Psyche may grab for a subscription. Each preference is one rung: *quality × source × minimum seeders × maximum size*. Preferences are tried in ascending `priority` (lower = tried first); the **first match wins**. A release that matches no preference is never auto-grabbed — there is no unlimited "best torrent" fallback.

Profiles are managed under **Settings → Quality profiles** (`/api/quality-profiles`).

## Seeded profiles

On boot, four profiles are seeded **only when the table is empty** — user-deleted defaults are never resurrected on later boots. `HD 1080p` carries the default flag.

| Profile | Default | Preferences (priority order) |
|---------|---------|------------------------------|
| **4K Ultra** | no | 2160p bluray (≥3 seeders, ≤60 GB) → 2160p webdl (≥3, ≤50) → 2160p webrip (≥2, ≤50) → 1080p bluray (≥2, ≤30) → 1080p webdl (≥2, ≤25) |
| **HD 1080p** | **yes** | 1080p bluray (≥2, ≤25) → 1080p webdl (≥2, ≤20) → 1080p webrip (≥1, ≤20) → 720p bluray (≥1, ≤15) → 720p webdl (≥1, ≤15) |
| **SD Compact** | no | 720p webdl (≥1, ≤10) → 720p webrip (≥1, ≤10) → 480p any (≥1, ≤5) → any/any (≥1, ≤5) |
| **Any Quality** | no | any/any (≥1 seeder, ≤50 GB) |

The trailing `any`/`any` rung in *SD Compact* and *Any Quality* is an **explicit** user fallback — the gate never invents one on its own.

## Profile structure

Each preference has five fields:

| Field | Values | Meaning |
|-------|--------|---------|
| `quality` | `2160p`, `1080p`, `720p`, `480p`, `any` | Resolution asked for; `any` is a wildcard. |
| `source` | `bluray`, `webdl`, `webrip`, `hdtv`, `dvd`, `any` | Source asked for; aliases normalized server-side (e.g. `web` satisfies `webdl`/`webrip`). |
| `minSeeders` | integer ≥ 0 (default 1) | Seeder floor. **Unknown seeders** (null/negative indexer data) pass. |
| `maxSizeGB` | positive number (default 50) | Hard size ceiling in GB. |
| `priority` | positive integer | Try order — lower first. |

A release matches a preference when quality and source agree (wildcards and alias normalization on both sides), seeders ≥ `minSeeders`, and size ≤ `maxSizeGB`. Releases whose names fail quality parsing map to `any`/`any` — they can match any preference's quality/source and are gated only by seeders and size. The full matching pipeline is in [Release matching](./release-matching).

Constraints: profile names are unique (collisions → `409 CONFLICT`), 1–64 characters; a profile holds 1–20 preferences. Editing replaces the preference list **as one unit** — there is per-rung patching.

### A worked example

Take the default **HD 1080p** profile and a candidate release `Show.Name.S01E02.1080p.WEB-DL.DDP5.1.H.264-GROUP` (4.2 GB, 12 seeders):

1. The parsed tag `web-1080p` maps to quality `1080p`, source `web` (the parser does not split WEB-DL/WEBRip; `web` satisfies both `webdl` and `webrip` preferences).
2. Rung 1 (`1080p bluray`) fails on source. Rung 2 (`1080p webdl`, ≥2 seeders, ≤20 GB) matches: quality equal, source equal, 12 ≥ 2, 4.2 ≤ 20.
3. Score: `1000 − 100×1 + min(200, 12) + 50 = 962`. The release is a grab candidate at tier index 1.

A 30 GB remux of the same episode matches **no** rung (size bounds fail everywhere) — it is excluded, and the reason surfaces on the wanted request. Adding a `1080p bluray ≤35 GB` rung would admit it; the gate never stretches a bound on its own.

In the UI, each profile is a card with its name, a **Default** badge, and the first five preference badges; the edit form exposes the full ordered list.

## The default profile

**At most one** profile may carry `isDefault`:

- Creating or updating a profile with `isDefault: true` clears the previous default server-side.
- New subscriptions without an explicit profile resolve to the default **at creation time** — the default's id is stamped onto the subscription.
- The default is editable like any other profile; there is no builtin immutability.

> [!NOTE]
> The default is a creation-time fallback, not a search-time one. A subscription whose profile id is null is blocked with an explicit reason even if a default exists — assign a profile (or re-save the subscription) to unblock it.

End to end: the default's id is stamped onto a new subscription at creation; if that profile is later [deleted](#deleting-profiles), `ON DELETE SET NULL` nulls the subscription's profile id. The next search then blocks the subscription before any indexer call, with the explicit `no quality profile set — set one to enable downloading` reason — no default is substituted at search time ([Subscriptions](./subscriptions#the-quality-gate), [Release matching](./release-matching#the-quality-gate)). Assigning a profile — re-saving the subscription — is what unblocks it.

## Assigning profiles

- **At subscribe time** — the add/subscribe flow lets you pick a profile; omitting it uses the default.
- **After the fact** — the subscription panel on the series/movie detail page has a profile select. Choosing "none" clears the profile (`null`), which gates the subscription until you assign one again.
- **Via the API** — `PUT /api/subscriptions/:id` with `qualityProfileId` (a number, or `null` to clear).

## Deleting profiles

**Any profile may be deleted — the default included.** Deletion is deliberate and has consequences:

1. Referencing subscriptions get `qualityProfileId = NULL` (the foreign key is `ON DELETE SET NULL`).
2. Those subscriptions' open requests are re-blocked with the explicit no-profile reason — downloading stops until you assign a new profile.
3. If the deleted profile was the default, **no default exists** until you promote another. New subscriptions then start profile-less.
4. Boot never re-seeds deleted profiles: seeding only runs into an empty table.

The UI asks for confirmation before deleting. There is no undo — recreate the profile and reassign it to the affected subscriptions.
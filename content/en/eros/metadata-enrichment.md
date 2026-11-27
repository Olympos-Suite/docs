---
title: "Metadata Enrichment"
description: "Hash-only scene identification: OSHash/pHash fingerprints verified against TPDB and StashDB, duration gates, unmapped scenes, and full hash-duplicate cleanup."
section: "User Guide"
order: 80
---

Eros's core bet is **trust the bytes, not the title**. Scene release names are inconsistent, repackaged, and rarely carry clean dates, so Eros never matches metadata by title, date, or duration guessing. The torrent is found first; metadata is a *result* of the download, not a prerequisite. The only authoritative evidence is the file's fingerprints — **OSHash** (byte-exact: first/last 64 KiB + file size) and **pHash** (perceptual, extracted with ffmpeg) — queried against [TPDB and StashDB](./integration).

## How a scene is matched

When a download's file becomes readable, `enrichScene` runs:

1. Resolve the file on disk (megapack mapping → `scene_files` → client file list → filesystem scan). No file yet → the scene stays `discovered` and a later job retries.
2. Compute OSHash + pHash (or reuse the hash already computed during download).
3. **Local safety net**: if another scene already owns this exact OSHash, the new scene is a [hash duplicate](#hash-duplicates-are-deleted-entirely) — handled before any provider call.
4. Query **TPDB** (`findByHash`), then **StashDB** (`findScenesByFingerprints`), fetching each candidate's full record and verifying it against the hard rules below.
5. The highest-scoring verified candidate wins. Equal scores within one provider reject the match; a cross-provider tie goes to TPDB (the primary provider).

A verified match applies the provider's title, description, date, duration, cover, and external IDs, links performers/studios, creates the scene folder from the [folder template](./file-organization), downloads the poster, and sets status `enriched`. The provider's own fingerprint list is remembered locally (`scene_external_hashes`) — that store powers sibling detection later.

## The evidence rules

Provider hash lists are community-submitted and sometimes polluted, so every candidate passes `selectBestHashCandidate`'s hard gates before it can match:

| Rule | Behavior |
|------|----------|
| Degenerate hashes | Empty, short (<8 chars), non-hex, or near-constant hashes (e.g. all zeroes) are never evidence. |
| Our hash in the record's list | The file's OSHash must literally appear in the candidate record's own hash list. |
| Submission floor | OSHash needs **≥1 submission** (byte-exact identity); pHash needs **≥2** (perceptual hashes collide across distinct files). |
| Duration gate | When both the file's and the record's durations are known, they must agree within **±60 s** — otherwise the candidate is rejected outright. |
| Performer corroboration | Below **5 submissions**, the record's performers must overlap the scene's performer attribution; ≥5 independent submissions count as community consensus and bypass the guard. Scenes with no performer attribution (scanner/discovery imports) are exempt. |

Acceptable candidates score 2 (base) +1 (≥2 submissions) +1 (duration agrees); the score only breaks ties between already-verified candidates.

## Sibling records and cross-verification

Providers catalogue the same release once per site it was posted to — different IDs, titles, and dates, but shared fingerprints. Before applying metadata, Eros checks whether the record describes a scene it already holds:

- The same external ID already assigned to another scene, or
- Fingerprint overlap in `scene_external_hashes`: exact OSHash intersection, or pHash within **Hamming distance ≤8**, weighted by submissions (≥2 on both sides = strong evidence).
- A tighter **±30 s duration gate** applies here: measured cases showed two genuinely different scenes sharing four OSHashes — duration told them apart.

A proven sibling is a duplicate, handled below. Soft-deleted scenes never claim provider records; a re-download enriches a fresh scene instead.

## Hash duplicates are deleted entirely

> [!WARNING]
> A scene proven to be a hash duplicate is **fully destroyed**: its torrent is removed from the client **with its files**, its folder is deleted from disk, and its scene/queue rows are deleted. The hash (and torrent name) is blacklisted so searches never re-grab it. This is automatic — there is no confirmation prompt.

The teardown is direction-aware:

| Situation | What happens |
|-----------|--------------|
| Both scenes are single torrents | Duplicate's torrent deleted with files, folder removed, rows deleted, blacklist reason `duplicate_scene`. |
| Duplicate is a single, survivor lives in a megapack | Single torrent deleted with files + blacklist `duplicate_of_megapack`; the pack is untouched. |
| Duplicate file lives inside a megapack | Only that file is de-prioritized (priority 0) and marked `duplicate`; the shared pack torrent stays intact. |

The loser's performer/studio links are merged onto the survivor first, so both subscriptions keep ownership. Other deletion paths (subscription delete, single-scene delete, cleanup) follow different rules — see [Deletion semantics](./deletion-semantics).

## Scene statuses

| Status | Meaning |
|--------|---------|
| `discovered` | Scene created, enrichment pending (file not readable yet, or not attempted). |
| `enriched` | Metadata attached on verified hash evidence. |
| `unmapped` | Enrichment ran and found **no hash evidence**. The folder is still created (under `unknown-studio` when the studio is unknown) and the scene shows a "No metadata" label. |
| `deleted` | Soft-deleted tombstone — see [Deletion semantics](./deletion-semantics). |

A **provider error is not a no-match**: if TPDB/StashDB fail, the scene's status is left untouched and an exponential retry backoff arms (5 min × 2^n, capped at 24 h) so a persistent outage is not re-hammered every 5 minutes. Only a genuine, verified no-match marks a scene `unmapped`.

## Megapacks: per-file mapping during download

Megapacks are fingerprinted **while still downloading**, not after:

- The `early-dedup` job (every 30 min) tracks each video file's piece range. The moment a file's first + last pieces land, an early OSHash is computed.
- Hash already owned locally → the file is marked `duplicate` and its download priority is set to 0 — duplicate bytes never waste disk.
- Otherwise the file's scene is created **at that moment** and enrichment runs immediately. Pack scenes appear gradually in the UI as files verify.
- At completion, `processMegapack` deletes duplicate files from disk, then binds every remaining file to a scene **by hash only** (exact OSHash → pHash Hamming ≤8 → new scene) and enriches each one.

## Manual re-enrichment

| Action | Where | What it does |
|--------|-------|--------------|
| **Scan Library** | Settings → Files (`POST /api/library/scan`) | Walks storage paths (depth 8, video files ≥50 MB, temp files skipped), imports unknown files as scenes, and enriches them. Files whose path or OSHash is already known are skipped — duplicates are reported, **never deleted, moved, or renamed**. Safe after a DB loss. |
| **Re-verify Metadata** | Scene detail menu (`POST /api/scenes/:id/enrich`) | `enriched` scenes are re-verified: evidenced matches refresh, unevidenced matches are **stripped back to `unmapped`**, sibling duplicates deleted. Other statuses run a fresh enrichment. |
| **Enrich Scenes** | Performer/studio detail (`POST /api/performers/:id/enrich-scenes`, `POST /api/studios/:id/enrich-scenes`) | Bulk re-verification of every enriched scene linked to the entity, with the same refresh/strip/dedup rules. Provider errors leave scenes untouched. |

## The daily retry

The `metadata-refresh` job (daily 03:00, `metadata_refresh_cron`) re-attempts up to **50 scenes** — `discovered` and `unmapped` first, plus `enriched` scenes missing a cover or tags. A community hash submitted yesterday can match a scene that was unmapped last week; missing hashes are healed first, so retries work even after retention removed the torrent from the client. The same run backfills studio banners and performer tags from the providers.

## Giving hashes back

After a successful match Eros contributes the computed **OSHash** (never pHash — algorithms differ across providers) back to the community: TPDB submissions happen on match; StashDB fingerprint submission is **opt-in** via the `contribute_hashes` setting (default off). Contribution is non-blocking and non-fatal. This is what grows the evidence base every other user matches against.

Developer internals — backoff state, tie-breaking, transaction boundaries, and the dedup teardown — are documented in [Enrichment pipeline](./enrichment-pipeline).
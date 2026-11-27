---
title: "Enrichment Pipeline"
description: "Hash-only scene identity internals: OSHASH/pHash evidence rules, provider cross-verification, sibling-record dedup, duplicate teardown, megapack per-file mapping, and the retry/repair machinery."
section: "Developer Guide"
order: 20
---

Eros identifies scenes by **file fingerprints only** — title/date matching is removed entirely. A provider record is applied to a scene only when the file's computed OSHASH appears in that record's own community-submitted hash list and survives hard verification gates. The engine is `metadata-enrichment-service.ts`, with identity rules in `scene-identity-service.ts`, local fingerprints in `fingerprint-service.ts`, and hashing in `hash-service.ts`. This page traces the internals; the user-facing behavior is in [Metadata Enrichment](./metadata-enrichment).

## Hash evidence

| Hash | Computation | Role |
|------|-------------|------|
| OSHASH | OpenSubtitles hash: file size + wrapping sum of 8-byte little-endian blocks over the first and last 64 KiB (`OS_HASH_CHUNK_SIZE` = 65536); 16-char lowercase hex | Byte-exact identity. The only hash queried against providers and contributed back. |
| pHash | ffmpeg frame extraction (midpoint → 5 s → no-seek fallback strategies) hashed with `imghash`; 64-bit, 16 hex chars | Perceptual similarity for re-encode detection; never sent to providers. |

`computeEarlyOsHash` reads the same two windows from a **partial** file using the declared total size for the tail position — valid once the covering pieces are downloaded. All-zero or unreadable results return `null` and are **never persisted** (hash fidelity outranks coverage). `isDegenerateHash` rejects evidence-free values: empty, shorter than 8 chars, non-hex, a single repeated character, or fewer than 3 distinct characters — all-zero hashes attached to unrelated provider records would otherwise chain scenes into one bogus identity.

Two stores hold evidence: `scene_files` carries **computed** local fingerprints (osHash/pHash/duration), while `scene_external_hashes` carries **provider-reported** fingerprints (hash, hashType, submissions, duration, provider, externalId) — the substrate for sibling-record dedup across TPDB and StashDB. See [Database](./database).

## The enrichScene flow

```text
backoff gate (force clears it)
  → resolveFilePath: megapack_items → scene_files → client file list → torrent-gone disk scan
  → no file on disk: stay 'discovered', retry later
  → bootstrap a scene_files row if none exists; reuse any persisted OSHASH
  → matchByHash:
      local findByOsHash safety net (another scene owns the hash ⇒ duplicate)
      TPDB findByHash → getScene → verify   (adapters in priority order)
      StashDB findScenesByFingerprints → getScene each → verify
      performer-disjoint guard → tie rules → best candidate
  → conflict check (findConflictingScene) ⇒ deleteDuplicateScene
  → apply metadata + links + folder + poster + store provider hashes
  → contributeHashes (OSHASH only)
```

`resolveFilePath` only trusts post-completion queue states (`seeding`/`completed`/`organized`) for the client-file-list fallback — hashing a partial file would produce garbage — backfills a missing `savePath` from the client, and after retention removed the torrent reconstructs the path by prefix-scanning the download root (largest video wins). Provider queries run **sequentially per provider**; any adapter rejection sets `providerErrored`, which is distinct from a genuine no-match.

## Verification hard rules

`selectBestHashCandidate` derives its thresholds from measured provider data (re-encodes of one scene land at Hamming 2–4; unrelated files at 36–38; single-submission hashes have carried wrong-scene labels):

1. **Our OSHASH must appear in the record's own hash list** — normalized to OSHASH/PHASH only (MD5 dropped), degenerate values rejected. Absent ⇒ score 0, no match.
2. **Submissions floor, asymmetric by type**: OSHASH accepts **≥ 1** submission — byte-exact identity means the submitter held the identical file, and the duration gate guards wrong-file matches. PHASH evidence keeps the **≥ 2** floor (perceptual hashes are collision-prone; pollution is measured even at 2 submissions).
3. **Duration hard gate ±60 s**: when both the file's and the record's durations are known and disagree beyond tolerance, the candidate is rejected outright — not down-scored.
4. **Score** (tie-breaking only): base 2, +1 if submissions ≥ 2, +1 if duration agrees — maximum 4. Candidates need score ≥ 2.

Two more guards run in `matchByHash` before selection:

- **Performer-disjoint guard** — when the scene has performer evidence (subscription context or links), a candidate whose performer names don't intersect is rejected unless its hash has **≥ 5 submissions** (`GUARD_BYPASS_MIN_SUBMISSIONS`, community consensus; the bypass is info-logged). Names normalize case/diacritics/whitespace/trailing numeric suffixes; containment matching requires the shorter name ≥ 6 chars, so `kylie` never matches `kylie shay`. Scenes with no performer evidence (scanner/discovery) are exempt.
- **Tie rules** — equal top scores from the **same** provider reject all candidates; a **cross-provider** tie resolves to TPDB (provider rank 0 vs StashDB 1).

## Sibling-record dedup

Providers catalog one release once per site — different ids/titles/dates, shared fingerprints. Before applying a verified match, `findConflictingScene` asks whether another scene already owns the record:

1. **Same external id** on another scene — a `json_extract` lookup written to hit the expression indexes (migration 0016); soft-deleted tombstones never claim records.
2. **Shared fingerprints** via `SceneIdentityService.findExistingSceneForRecord` over `scene_external_hashes`: the candidate record must carry a duration (no duration ⇒ no identity guess); OSHASH intersects exactly in SQL, PHASH candidates come from the block indexes and are filtered at **Hamming ≤ 8**. Evidence is strong when a shared hash has **≥ 2 submissions on both sides**; a scene qualifies with one strong hash, ≥ 2 shared OSHASHes, or ≥ 3 shared hashes total. The **sibling duration gate is ±30 s** — tighter than the match gate, enforcing encode/trim sameness. (Measured case: two genuinely different scenes shared 4 OSHASHes; only duration separated them.) Soft-deleted scenes and scenes without a duration are excluded; the strongest evidence tally wins.

On a successful match, `storeProviderHashes` writes the record's normalized fingerprints into `scene_external_hashes` (idempotent, `onConflictDoNothing`) — so the next scene matching a sibling record is caught even when the external ids differ.

## Duplicate teardown

`deleteDuplicateScene(survivor, duplicateId)` first **merges the loser's performer/studio links onto the survivor** (non-fatal), so both subscriptions keep ownership and won't re-download. Megapack ownership is resolved through `megapack_piece_mapping.matchedSceneId` or `megapack_items` joined to an `isMegapack` queue row — and **megapack-owned content always wins** over a single. Teardown is direction-aware:

| Case | Torrent | Rows / disk | Blacklist |
|------|---------|-------------|-----------|
| Duplicate is megapack-owned | Pack untouched; only that file de-prioritized (`setFilePriority` 0) | Mapping → `duplicate`, scene row deleted only | — |
| Single duplicating megapack content | Deleted **with files** | Queue + scene rows, folder | `duplicate_of_megapack` |
| Both singles | Deleted **with files** | Queue + scene rows, folder | `duplicate_scene` |

Folder removal is guarded (`isSceneScopedFolder`): a stale or broad template path pointing at a studio folder or library root is never `rm -rf`'d. Bare files (scanner imports with no folder) get the audit-style gates — inside an active storage root, regular video file, non-temp, ≥ 50 MB — then delete-then-verify. Finally the queue row is deleted, piece-mapping FK references are cleared explicitly, and the scene row delete cascades `megapack_items`, `scene_files`, and `scene_external_hashes`. Every step is non-fatal; the teardown never aborts midway. See [Deletion Semantics](./deletion-semantics).

## Outcomes, contribution, re-verification

- **Match** ⇒ `cleanupTentativeAttribution` first (subscription-derived performer/studio links contradicted by the verified record are removed; provider-linked entities and empty provider lists are never touched), then metadata apply: status `enriched`, external ids, find-or-create entity links, folder via the [folder template](./file-organization), poster, provider hashes stored, computed pHash persisted. `contributeHashes` then sends the **OSHASH only** back: TPDB `submitHash` on every match; StashDB `submitFingerprint` is opt-in via `contribute_hashes` (default off). Both non-fatal, reusing the already-computed hash/duration.
- **No evidence, no provider error** ⇒ status **`unmapped`**; the folder is still created (`unknown-studio` fallbacks).
- **Provider error** ⇒ status untouched, in-memory exponential backoff armed: 5 min × 2^(n−1), capped at 24 h; past 10 attempts the scene retries on the daily cadence. `force` (manual re-enrich) clears the backoff. Internal failures (locked/partial files) also keep the status — never `unmapped`.
- **`reverifyScenes`** (manual re-enrich, performer/studio bulk enrich) re-runs the hash evaluation on `enriched` scenes: verified matches refresh, unevidenced matches are stripped back to `unmapped`, hash-duplicate siblings are deleted. It trusts only `trustedPerformers` passed by the caller — never the possibly polluted scene links — and skips scenes untouched on provider errors.

## Megapack per-file flow

Detection (`megapack-detector`): strong title signals (`megapack`, `siterip`, `NN videos/scenes`) always qualify; weak signals (`pack`, `collection`, `complete`) only above 5 GB.

**While downloading** (`early-dedup` job, 30 min):

1. `initializeMapping` (idempotent) creates **only `megapack_piece_mapping` rows** — one per video file with its client-reported piece range, status `pending`, `matchedSceneId` NULL. **No scene rows are created upfront**: the former FIX-D behavior spawned hundreds of duplicate shell scenes for overlapping packs.
2. `pollAndProcessReadyFiles` processes ≤ 20 files per torrent per run whose first **and** last piece report state 2. Each file is claimed atomically (`pending → processing`, CAS — the completion path racing the same file loses and skips). The early OSHASH is computed from the declared size; a hash already owned by another scene marks the file `duplicate` and de-prioritizes it in the client (no scene ever materializes); otherwise the scene is created **lazily in one synchronous transaction** — scene + performer/studio links (resolved from the subscription before the tx) + `scene_files` + mapping update, with `ensureUniqueSlug` inside the tx so same-pack titles can't abort it. Enrichment runs after commit, non-fatal. Failed claims land in `failed`; stale claims and >24 h failures are reclaimed.
3. `processActiveSingles` gives single torrents the same early path, gated on the client's `piece-map` capability. `earlyHashPiecesComplete` verifies **every piece covering both 64 KiB windows** is downloaded, anchored to the file's own `pieceRange` — a multi-file single doesn't start at piece 0. A hash owned by a different scene deletes the duplicate entirely; otherwise the hash is persisted and enrichment fires immediately, mid-download.

**On completion** (`download-completion` job): `processMegapack` claims the queue row via CAS (`completedAt` NULL → stamped; a failure after the claim keeps the stamp — re-running would duplicate scenes). It unlinks duplicate files from disk (`cleanupDuplicateFiles`), consults the early mapping (processed files reuse their scenes; duplicates and in-flight claims are skipped), then processes the remainder: per-file OSHASH/pHash/duration outside any transaction, assignment by **OSHASH exact → pHash Hamming ≤ 8 → new scene**, two synchronous write transactions (early links, then legacy scene/`scene_files`/`megapack_items` creation), fingerprint storage, and per-scene enrichment. See [Torrent Grouping](./torrent-grouping) for how packs enter the pipeline.

## pHash block indexes

SQLite has no popcount, so Hamming comparison runs in memory — but not over the whole library. `packages/database/src/phash.ts` splits the 16-hex hash into **16 nibble blocks**: by pigeonhole, any pair within Hamming distance t ≤ 15 shares at least one identical block, so an OR over 16 `substr(lower(col), i, 1)` equality predicates selects a guaranteed superset of true matches. Expression indexes (migration 0015) on `scene_files.p_hash` and `scene_external_hashes.hash` serve those predicates; the SQL is rendered with literal positions to match the index definitions character-for-character. A `length(col) = 16` conjunct excludes non-canonical rows (length mismatch is infinite distance); odd-length candidates are fetched by exact length instead. The in-memory filter (`hammingDistance`: BigInt XOR + Kernighan popcount) then removes false positives — results identical to a full scan. Thresholds above 15 or non-canonical hashes fall back to the full scan. Both `fingerprint-service.findSimilarByPhash` (default distance 8) and the identity service's PHASH pass use this machinery.

## Retry and one-shot repair

**`metadata-refresh` job** (daily 03:00) retries up to **50 scenes**, oldest-`updatedAt`-first: `discovered`, `unmapped` (providers may have added the scene since), `enriched` without a cover (non-empty title), and `enriched` with NULL tags. Discovered/unmapped scenes first heal missing hashes via `ensureComputedSceneFile` (idempotent; works even after retention removed the torrent). Two bounded backfills follow: ≤ 25 studios missing banner/images with provider ids (`enrichStudioMetadata`), ≤ 25 performers with NULL tags and external ids (`enrichPerformerTags`).

**Startup dedup repair** (`dedup-repair-service`, gated by the `dedup_repair_done` settings flag) fixes the case-sensitive infoHash re-download bug once per database, after the container boots but before jobs start. The flag is stamped only after a clean run — failures retry next boot without blocking it, and restoring an older backup re-arms it. Three phases:

1. **Dead shells** — `discovered`/`unmapped` scenes with no `scene_files`, `megapack_items`, `torrent_groups`, or `download_queue` evidence are hard-deleted with their junctions.
2. **Duplicate re-adds** — queue rows grouped by `lower(info_hash)`: with a completed keeper, non-completed siblings are deleted from the client **with files**, blacklisted (`dedup_repair_readd`), and their rows removed. No completed keeper ⇒ the group is skipped; the only copy of an in-progress download is never removed.
3. **Orphan client torrents** — torrents with no queue row are deleted with files **only when provably Eros-managed** (category equals `torrent_category`, or a `subscription:` tag). Personal torrents are never touched.
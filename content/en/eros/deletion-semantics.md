---
title: "Deletion Semantics"
description: "The full deletion decision tree: subscription deletes with and without scenes, blacklist cleanup, soft-deleted scenes and restore, entity deletes, re-subscribes, and the weekly clean job."
section: "User Guide"
order: 100
---

Every delete in Eros lands in one of two outcomes: a **soft delete** (the scene row survives as a tombstone, files are removed, restore is possible) or a **full cleanup / hard delete** (row, files, torrent — everything goes). Which one you get depends on *what* you delete and on one protection rule:

> [!IMPORTANT]
> A scene is protected while **another subscription** still references it — through its performer, its studio, or a torrent group it owns. Bare performer/studio links to entities you are *not* subscribed to do **not** protect a scene.

## Deleting a subscription

The delete dialog's "delete scenes" switch (`deleteScenes`, **on by default**) picks the mode.

**With "delete scenes" ON** — every scene linked to the subscription (via its torrent groups or its performer/studio) is examined:

- **Another subscription depends on it** → untouched: scene row, performer/studio links, and disk files all stay.
- **No other dependency** → hard delete: the scene row is deleted (cascading its performer/studio links, file records, and stored hashes), its folder is removed from disk, its torrent is removed from the client **with files**, and leftover group/queue rows are cleaned.

> [!CAUTION]
> The hard-delete branch destroys files permanently — disk folder and torrent data alike. External cleanup is best-effort after the database commit: a client outage leaves the DB teardown intact but may leave torrent data behind.

**With "delete scenes" OFF** — scenes are not touched at all. Rows and performer/studio links survive, files stay on disk, and the scenes reappear in the list if you ever subscribe again. This is deliberate.

**Blacklist, both modes**: blacklist entries owned by the deleted subscription are purged inside the same transaction. Entries belonging to other subscriptions — or with no subscription — are untouched. Old bans therefore never leak into a future re-subscribe.

## Deleting a single scene

From the scene detail view, deletion is a two-step affair:

1. **First delete → always soft.** The scene becomes a tombstone (`status = 'deleted'`): file records, stored hashes, and queue rows are removed (freeing the hash for re-download), performer/studio links are **kept**, and the disk folder plus any client torrent are removed best-effort.
2. **Deleting the tombstone → permanent purge.** A second delete on an already-deleted scene hard-deletes everything that remains.

> [!WARNING]
> Even the "soft" first delete removes the scene's **files from disk and the torrent from the client**. Soft refers to the database record only — the media is gone until you re-download it.

## Soft-deleted scenes: restore and final fate

- While the subscription lives, tombstones appear in the library as **Deleted** with a **Restore** action. Restore returns the scene to `discovered` and drops stale queue rows, so the content can be downloaded again.
- If the owning subscription is later deleted **with scenes**: a tombstone with no other subscription dependency is purged completely; one that another subscription still references stays untouched and restorable.
- Tombstones never participate in hash-duplicate matching — a re-download enriches a fresh scene instead of colliding with a dead record.

## Deleting a performer or studio

Deleting the entity runs the same machinery:

1. Its subscription (if any) is deleted first, under the rules above.
2. Its scenes follow the dependency rule: no other subscription referencing them → hard delete (row + cascade + disk + torrent); otherwise they stay in the library.
3. The entity record itself is pruned once no scenes or dependencies remain.

Entity deletion deliberately adds **no blacklist entries** — the content must stay re-downloadable if you change your mind.

## Re-subscribing

| Previous delete used | What a re-subscribe shows |
|----------------------|---------------------------|
| "delete scenes" OFF | Old scenes return to the list (their links survived) — intentional. |
| "delete scenes" ON | Dependency-less scenes were truly destroyed; they do not come back. |
| Either mode | The old subscription's blacklist was purged, so previous bans don't affect the new subscription. |

## The weekly clean job

The `cleanup` job (`cleanup_cron`, default weekly Sunday 00:00) removes accumulated leftovers in five phases:

1. Job-run history older than `job_logs_retention_days` (default 30).
2. `completed`/`organized` queue rows older than `cleanup_days` (default 7) — **guarded**: rows whose scene is still `discovered` are kept so enrichment never strands them.
3. Orphaned torrent groups (no scene, older than 30 days).
4. Application logs older than `log_retention_days` (default 14).
5. **Download-root orphan sweep**: entries under active download roots are deleted from disk only when they are provably orphaned — not a live torrent's save path, not an active queue row's folder, and not part of the organized library.

> [!CAUTION]
> Phase 5 deletes files. Its safety rule: if the torrent client is unreachable or unconfigured, the step is **skipped entirely** — orphan status can only be proven against the client's torrent list. The download root itself is never deleted.

## Hash duplicates are different

Hash-duplicate cleanup during [enrichment](./metadata-enrichment) is its own path: the duplicate is destroyed entirely (torrent **with files**, folder, rows) **and blacklisted** so it cannot be re-grabbed — with direction-aware handling when a megapack is involved. Subscription/entity deletes above never blacklist; stalled-download removal does (`stalled_removed`). See [Download management](./download-management) for the queue-side flows.

## Summary

| Event | Condition | Result |
|-------|-----------|--------|
| Subscription deleted + "delete scenes" | Scene depended on by another subscription | Untouched |
| Subscription deleted + "delete scenes" | No other dependency | Hard delete (DB + disk + torrent) |
| Subscription deleted (either mode) | Blacklist rows owned by it | Deleted |
| Subscription deleted, scenes kept | — | Scenes + links stay as they are |
| Single scene deleted (first time) | — | Soft delete (record stays, files go) |
| Single scene deleted (tombstone) | — | Permanent purge |
| Soft-deleted scene + subscription hard delete | No other dependency | Purged |
| Performer/studio deleted | Same dependency rule | Hard delete or untouched |
| Re-subscribe | Previous delete kept scenes | Old scenes return |
| Download leftover (gone from client) | Not active queue / library | Clean job deletes from disk |
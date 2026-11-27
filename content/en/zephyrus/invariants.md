---
title: "Invariants"
description: "The non-negotiable rules from AGENTS.md and the spec: what each forbids, why, and where the code enforces it."
section: "Developer Guide"
order: 6
---

Zephyrus is an optional policy layer over someone else's torrent client. Its safety comes from a small set of rules that are **spec breaches to violate, not style issues**. `AGENTS.md` lists them in two groups — 8 non-negotiable invariants and 4 critical correctness rules (12 total) — grounded in the six design principles of spec §2. Authority chain in the repo: `Zephyrus.md` (spec) > `AGENTS.md` > code; if code and spec disagree, the spec wins until the spec itself is changed.

## The six design principles (spec §2)

1. **Zephyrus is an optional layer.** No suite app depends on it. Uninstalled, torrents download, seed, get removed and organized by their owning apps under client defaults; no critical flow breaks.
2. **The torrent client is the single source of truth.** The DB holds only what the client doesn't know (action history, policy state) and is rebuildable from the client.
3. **Zephyrus never removes torrents.** Pause, resume, reannounce, per-torrent limits — nothing else. Removal is always the owning app's job.
4. **Zephyrus never touches files.** No move, rename, delete, folder creation — that is domain knowledge belonging to the apps.
5. **Zero domain knowledge.** No scenes, subscriptions, series, movies, metadata, enrichment. Zephyrus knows only: torrent + group (category/label) + client state.
6. **Apps never call Zephyrus.** Eros/Psyche add torrents directly to the client; Zephyrus discovers them via group scan (adoption). The only contract is the group naming convention.

## Non-negotiable invariants (AGENTS.md)

### 1. Never remove/delete torrents

Zephyrus may pause, resume, reannounce, and set per-torrent speed limits — nothing else. Removal decisions (e.g. seed-window expiry) belong to the owning app.
**Enforced by:** the `TorrentClient` type has no removal method (`src/adapters/torrent-client.ts`); the compile-time guard in `torrent-client.test.ts`; the orchestrator's executor handles only pause/resume/reannounce/limit kinds. "Given up" stalled torrents are deprioritized, never deleted.

### 2. Never add torrents

Adding is the apps' job; Zephyrus adopts via group scan.
**Enforced by:** no `add` method on `TorrentClient`; the same compile-time guard. There is no code path anywhere that creates a torrent in the client.

### 3. Never touch files

No rename, move, delete, or file-priority changes. File organization belongs to the apps.
**Enforced by:** no file-related method on `TorrentClient`. The qBit state mapping even classifies `moving` (a file move in progress) as `checking` so policy keeps such torrents untouched.

### 4. Never assign/change groups (categories/labels)

Group membership is the ownership contract, set by the owning app — Zephyrus reads it, never writes it.
**Enforced by:** no `setCategory` method on `TorrentClient`; adapters map `category` → `group` read-only (`mapTorrentRecordToSnapshot`).

### 5. Never change client global settings

The weekly schedule is enforced via **per-torrent limits only**; unmanaged torrents must stay unaffected.
**Enforced by:** the interface exposes only per-torrent `setDownloadLimit`/`setUploadLimit`/`clearLimits` (hash-list based); no global-settings method exists. The engine emits limit actions exclusively for managed snapshots, and `applyUnmanaged` clears Zephyrus-applied limits when a torrent leaves management.

### 6. No domain logic

No metadata, scenes, seed counting, removal timing. Zephyrus knows only torrent + group + client state.
**Enforced by:** the canonical vocabulary in `src/core/types.ts` (`TorrentSnapshot` carries exactly those fields); the engine's inputs are snapshots + config + capabilities — there is nowhere for domain data to enter.

### 7. No webhook/event infrastructure in v1

Explicitly out of scope; no notification channel in either direction between apps and Zephyrus.
**Enforced by:** absence by design — integration is poll-based (adapter) and HTTP request/response (API). Do not add event emitters, webhooks, or push channels without a spec change.

### 8. Type-level mutation ban on the adapter interface

`TorrentClient` must not expose `add`, `delete`, `rename`, or `setCategory`. The ban is enforced **by types, not by code review**.
**Enforced by:** the interface itself plus a compile-time guard test (`src/adapters/torrent-client.test.ts`):

```ts
type BannedClientMethod = 'add' | 'delete' | 'remove' | 'rename' | 'setCategory'
type BannedMethodLeak = Extract<keyof TorrentClient, BannedClientMethod>
type AssertNever<T extends never> = true
```

If a banned method ever appears on the interface, `BannedMethodLeak` stops being `never` and the build fails. The mock adapter honors the same surface. See [Adapters — Type-level mutation ban](./adapters#type-level-mutation-ban) for the `TorrentClient` interface and the full compile-time guard implementation.

## Critical correctness rules (AGENTS.md)

### 9. `pausedByUs` is write-ahead; fail safe on DB loss

The flag is written to the DB **before** the pause action executes. Only torrents Zephyrus itself paused are ever resumed. If the DB is lost, touch no paused torrent.
**Enforced by:** `runPolicyCycle` in `src/services/orchestrator.ts` persists every pause action's flags before `executeActions`; unexecuted resumes keep their flags; `syncTorrentsTable` latches **safe mode** when a managed torrent is paused without proof of ownership; graceful shutdown releases only `pausedByUs` torrents. Engine-side, `addPauseReason`/`removePauseReason` maintain `pausedByUs === reasons.length > 0`, and every resume path checks ownership (user/app pauses are never lifted — including by pin releases and schedule exits). See [Database](./database).

### 10. The client is the source of truth; the DB is rebuildable

SQLite holds only action history and policy state; it must be fully rebuildable from the client.
**Enforced by:** `TorrentsRepository.upsertMany` mirrors client fields every tick and never clobbers policy flags; `removeByHashes` drops rows for disappeared torrents; the schema comments state the rebuildability contract. Auth tables (`users`/`sessions`/`settings`) are the documented exception — app auth, not torrent state.

### 11. Only `managed_groups` torrents are managed

Managed groups = the keys of `config.groups`. Groupless and unlisted-group torrents are untouchable. If a torrent's group is removed from config, release it (resume if paused by us).
**Enforced by:** `isManagedSnapshot` in `src/core/policy/unmanaged.ts` gates every engine module; `applyUnmanaged` resumes + clears limits + drops state when a group leaves config; `GET /api/torrents` lists managed only; pin mutations 404 for unmanaged hashes; safe-mode latching concerns managed torrents only.

### 12. The policy engine is a pure function

`(snapshot, config) → action list`; all side effects live in the adapter layer. Test the engine with a mock adapter, never a live client.
**Enforced by:** `evaluatePolicies` in `src/core/policy/policy-engine.ts` — no I/O, injected `now`, cloned inputs, deterministic output; the orchestrator alone executes actions and persists state; the test suite runs the engine on fixtures and the runtime on the scriptable mock (`src/adapters/mock/`). Live qBittorrent is required only for manual/E2E verification, never CI.

## How the rules interlock

The type-level ban (8) makes rules 1–5 structurally unbreakable from the adapter side. Ownership (9, 11) makes pause/resume safe even across crashes, DB loss, and config changes. Purity (12) makes every policy decision reproducible and testable, and the audit trail (`action_log`, one human-readable reason per action) makes every executed decision traceable. When a change seems to require bending any of these, the change is wrong — or the spec must be amended first.

Related pages: [Architecture](./architecture), [Adapters](./adapters), [Policy Engine](./policy-engine), [Database](./database), [Testing](./testing).
---
title: "Invariants"
description: "Eros's binding contribution rules: mechanical layering, hash-only identity, the quality gate, group thresholds, deletion semantics, and the TypeScript conventions."
section: "Developer Guide"
order: 60
---

These rules are binding for every change to Eros. They come from the repo's agent notes (`AGENTS.md`), contribution guide (`CONTRIBUTING.md`), deletion decision tree (`DELETION_SEMANTICS.md`), and flow documentation (`flow.md`); where this page summarizes, those documents and the code govern. Several rules are enforced mechanically — by ESLint zones, types, or database constraints — not by review.

## Layering

Every backend call path follows **Routes → Controllers → Services → Repositories → Database (SQLite / better-sqlite3)**. No layer may be skipped; a route must never call a repository directly. ESLint `import-x/no-restricted-paths` zones enforce this:

- **Routes** — `error`: no imports from services, adapters, repositories, `@repo/database`, or the SQLite drivers. Routes bind controllers only.
- **Controllers** — `error`: no DB-layer or driver imports. Three files carry pre-existing violations at `warn` (log, job, and service-connection controllers).
- **Services** — `warn` on `drizzle-orm`/`better-sqlite3` driver imports (query logic belongs in repositories); importing `@repo/database` schemas/`DbType` is intentionally allowed.

Documented exceptions: `LogController` → `AppLogsRepository` and `JobController` → `JobLogsRepository` (no service layer), `ServiceConnectionController` → adapter factory, the three inline streaming handlers in `routes/backup.ts`, and a few pipeline services/jobs holding `DbType` for sweep queries no repository covers. Do not add new exceptions without recording them.

Frontend layering is equally fixed: thin Server Component page shells → feature Client Components (`src/features/*`) → TanStack Query hooks → `api-client.ts` → the `/api/*` catch-all proxy. Filter/pagination state lives in URL params. See [Architecture](./architecture).

## Hash-only identity

Enrichment matches scenes to TPDB/StashDB **only by hash evidence** (OSHASH/pHash). Title/date/duration matching was removed and must not return. Duration is a **verification gate, never an identification signal**:

- Provider-record vs file duration must agree within **±60 s** or the candidate is rejected outright.
- Sibling-record detection (same release catalogued per site) uses a tighter **±30 s** gate plus hash intersection: exact OSHASH or pHash Hamming **≤ 8**.
- Submission floors are asymmetric: OSHASH (byte-exact) is accepted with **≥ 1** submission because the duration gate guards it; pHash (collision-prone) requires **≥ 2**. Degenerate hashes (empty, short, non-hex, single repeated character, < 3 distinct characters) are never evidence.
- Low-submission matches need performer corroboration; **≥ 5** independent submissions count as community consensus that bypasses the guard.
- Provider errors leave the scene untouched (`discovered`, retried later); no evidence marks it `unmapped`. Only OSHASH is contributed back to providers — never pHash.

Provider-reported fingerprints are stored in `scene_external_hashes` for cross-provider sibling dedup. Full pipeline: [Enrichment pipeline](./enrichment-pipeline).

## Subscriptions and groups

- **Subscriptions target a performer or a studio — never a single scene.**
- **TorrentGroups need members before they become scenes**: `torrent_group_min_members` (default **2**, floor 2 — smaller configured values are ignored) is the acceptance threshold; groups below it are discarded. Synthetic single-torrent groups from the LLM/JAV paths are exempt, and megapacks bypass grouping entirely.
- **Scenes are created at download start**, after the torrent client accepts the add — never before (orphan-scene protection), never from enrichment. Blacklist and queue-dedup checks run first; a failed add creates no scene. Title-based scene reuse (`findSimilarExistingScene`) was removed: every torrent opens its own scene, and true duplicates are torn down by hash dedup.

## Quality gate

Regular group selection passes the quality profile gate: preferences are tried **in priority order**, and there is **no unconstrained best-torrent fallback** — if no member matches any preference (or no profile is attached), nothing is downloaded and the reason is logged. Users build their own fallback by adding an `any`/`any` preference as the last list entry. Hashless-member fallback stays within the *matched* preference, or resolves the real hash from the download link. Megapacks are exempt from grouping and the gate — but only via the subscription's `includeMegapacks` **opt-in**.

> [!NOTE]
> Older flow text describing "first preference only, then fall back to `bestTorrent`" is superseded by this gate in the current orchestrator code.

## Deletion semantics

The decision tree in `DELETION_SEMANTICS.md` reduces to these rules:

- **Deleting a single scene is always soft**: the row stays as a `deleted` tombstone, disk files and the torrent are removed, junctions are kept, and *Restore* brings it back for re-download.
- **Subscription delete with `deleteScenes=true`**: a scene is protected only if **another subscription depends on it** — a junction to a performer/studio that is itself subscribed, or a `torrent_groups` row owned by another subscription. A junction alone protects nothing (every enriched scene has a studio junction; the old existence check deleted nothing). Unprotected scenes get **hard delete**: row + cascades, folder removed, torrent removed **with files**, group/queue remnants cleaned. Protected scenes are untouched.
- **Subscription delete with `deleteScenes=false`**: scenes and junctions stay exactly as they are; re-subscribing later brings them back — deliberate behavior.
- **Blacklist rows belonging to the deleted subscription are removed in both modes**, inside the transaction; other subscriptions' and null-scoped entries survive.
- **Performer/studio delete** tears down its subscription first (same rules), applies the same dependency rule to scenes, and prunes the entity when nothing references it.
- **Hash-duplicate scenes are deleted entirely** — torrent removed with files, folder deleted, DB rows deleted — after merging the duplicate's performer/studio relations onto the survivor. Exception: a megapack-owned duplicate only de-prioritizes its file (priority 0) and deletes the scene row; the shared pack torrent and folder survive.

Full decision tree and the weekly orphan-cleanup guards: [Deletion semantics](./deletion-semantics).

## Seed retention and megapacks

- **`seed_time_hours` (default 72) is the only removal clock.** After the window, the torrent is removed from the client **with files kept**, the queue row becomes `organized`, and folder sweeps rename/move to the post-enrichment template. Sweeps are rename-only and idempotent — never destructive.
- **Megapacks are checked per file during download**: `initializeMapping` writes piece-mapping rows only (no shell scenes); when a file's first + last pieces land, its early OSHASH is computed — a local fingerprint hit de-prioritizes the file and marks it duplicate (duplicates never create scenes), otherwise the scene is created lazily and enriched.
- **Be honest about capabilities**: torrent clients declare what they support (e.g. `piece-map`); features degrade gracefully when a capability is missing. Never approximate data you cannot retrieve — piece ranges are not estimated from file offsets.

## Contracts and conventions

- **Zod at both ends**: `@repo/shared-types` schemas validate route boundaries (lenient transform query schemas parse + clamp junk instead of 400ing; required params still 400) and controller bodies (defense in depth). Every error path emits the shared `api-envelope` codes — see [API reference](./api-reference).
- **DB access only via Drizzle** in `@repo/database`; WAL + foreign keys on every connection. Never edit applied migrations — always generate a new one (`pnpm db:generate`).
- **Jobs**: the four essential pipeline jobs (torrent-progress-sync, download-completion, early-dedup, torrent-retention) can never be stopped or disabled (`400 JOB_NOT_DISABLEABLE`); runs never overlap themselves, history persists in `job_logs`, and stale `running` rows are finalized as failed at boot.

TypeScript conventions (AGENTS.md, enforced in review and lint):

| Rule | Detail |
|------|--------|
| No enums | `as const` objects + type inference. |
| No `any` | `unknown` + type guards. |
| No `I` prefix | `User`, not `IUser`. |
| Exported functions | Return type annotation required. |
| 2+ parameters | Object destructuring. |
| Cross-package imports | Workspace names: `@repo/database`, `@repo/shared-types`. |
| Local imports | `@/` alias. |
| File naming | kebab-case (`user-service.ts`); PascalCase for React components. |

Before opening a PR: `pnpm build` clean, tests green, and tests added for any new service/controller/adapter logic — see [Testing](./testing). Provider additions follow the checklist in [Adapters](./adapters).
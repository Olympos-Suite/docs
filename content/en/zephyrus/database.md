---
title: "Database"
description: "Drizzle schema, WAL-mode SQLite, auto-applied migrations, the repository pattern, and the write-ahead pausedByUs design."
section: "Developer Guide"
order: 5
---

Zephyrus uses **better-sqlite3 + Drizzle ORM** with a single SQLite file (default `./data/zephyrus.db`, override with `ZEPHYRUS_DB`). The database is deliberately small: the torrent client is the source of truth, and SQLite holds only a client mirror, policy flags, the action audit trail, and app authentication. Everything except policy flags and auth is rebuildable from the client.

## Opening the database

`src/db/db.ts` — `openDatabase({ path, migrationsFolder = './drizzle' })`:

```ts
const sqlite = new Database(path)
sqlite.pragma('journal_mode = WAL')
sqlite.pragma('foreign_keys = ON')
const db = drizzle(sqlite, { schema })
migrate(db, { migrationsFolder })
```

- Parent directories are created when missing (an empty Docker `/data` volume must boot).
- **WAL mode** for concurrent read/write behavior; **foreign keys ON** (the `sessions.user_id` reference is enforced).
- **Migrations auto-apply on boot** — there is no separate migrate step in normal operation. The returned handle adds a `close()` method used by graceful shutdown.

### Migrations

Generated SQL lives in `drizzle/` (drizzle-kit config: `drizzle.config.ts`, dialect sqlite, schema `./src/db/schema.ts`, out `./drizzle`):

| Migration | Contents |
|-----------|----------|
| `0000_smart_whistler.sql` | `torrents` + `action_log` tables and their indexes |
| `0001_steep_red_shift.sql` | Auth tables: `users`, `sessions`, `settings` |
| `0002_safe_guardian.sql` | `torrents.pinned` column (user manual priority) |

Workflow when changing the schema: edit `src/db/schema.ts`, run `pnpm db:generate` (drizzle-kit generate) to produce a new migration, commit it. `pnpm db:migrate` (drizzle-kit migrate) exists for manual application, but boot applies pending migrations automatically. Never hand-edit generated SQL or the `drizzle/meta` snapshots.

## Schema

Defined in `src/db/schema.ts`. Column types use `$type<...>()` with the canonical unions from `src/core/types.ts` — no TS `enum` anywhere.

### `torrents` — mirror + policy state

| Column | Type | Notes |
|--------|------|-------|
| `info_hash` | text, **PK** | Universal torrent identity |
| `name` | text, not null | Client mirror |
| `group` | text, nullable | Client category/label ("group" is a reserved SQL word; Drizzle quotes it). Indexed (`torrents_group_idx`) |
| `client_state` | text (`TorrentState`), not null | Last seen canonical state |
| `paused_by_us` | integer boolean, not null, default false | **Write-ahead ownership flag** |
| `pause_reason` | text (`PauseReason`), nullable | Single value: `queue` / `stalled` / `slow` / `schedule`; cleared on resume |
| `pinned` | integer boolean, not null, default false | User manual priority; DB loss → pins lost → normal management (fail-safe) |
| `added_at` | integer, not null | Epoch ms as seen by the client (drives FIFO prioritization) |
| `updated_at` | integer, not null | Last mirror refresh |

### `action_log` — audit trail

| Column | Type | Notes |
|--------|------|-------|
| `id` | integer, PK autoincrement | |
| `info_hash` | text, nullable | Null for system notes and limit summaries |
| `action` | text (`ActionKind`), not null | `pause` / `resume` / `reannounce` / `limit` / `unmanage` / `note` |
| `reason` | text, not null | Human-readable justification (the engine action's `description`) |
| `created_at` | integer, not null | Epoch ms; indexed (`action_log_created_at_idx`) |

Every policy action is logged with a reason. Pause/resume/reannounce write one row per affected hash; `setLimits`/`clearLimits` collapse to the `limit` kind and write **one summary row per action** (null hash, reason ends with "(N torrents)") — per-hash rows would flood the log on every share change. Rows older than **90 days** are pruned at orchestrator start.

### Auth tables (wizard + sessions)

| Table | Columns | Purpose |
|-------|---------|---------|
| `users` | `id` PK, `username` (unique), `password_hash`, `created_at` | First-run admin account; hash format `scrypt$<saltHex>$<hashHex>` |
| `sessions` | `token_hash` PK (sha256 hex of the token), `user_id` FK → users.id, `created_at`, `expires_at` (indexed), `last_seen_at` | 30-day bearer sessions; the raw token is never stored, so a DB leak cannot replay sessions |
| `settings` | `key` PK, `value` | Key/value runtime settings; currently `client_configured` ('true'/'false'), set by the setup wizard after a verified connection |

These tables are the exception to "rebuildable from the client" — they are app auth state, not torrent state.

## Repository pattern

One class per table in `src/db/repositories/`, each constructed with `{ db }`. Services (orchestrator, auth, setup) are the only callers — routes and controllers never import repositories.

### `TorrentsRepository`

- `upsertMany({ rows })` — insert-or-update by `info_hash`. **On conflict only client-mirror fields are updated** (`name`, `group`, `client_state`, `added_at`, `updated_at`); `paused_by_us` / `pause_reason` / `pinned` are never part of the upsert payload, so a mirror refresh can never clobber policy state.
- `setPausedByUs({ hashes, paused, reason })` — single UPDATE toggling the write-ahead flag + reason for a batch of hashes.
- `setPinned({ infoHash, pinned })` — toggle the user pin; never touches pause state.
- `findByHash`, `listAll` (oldest-added first — FIFO order), `removeByHashes` (drop rows for torrents that disappeared from the client), `countByGroup`, `countByState`.

### `ActionLogRepository`

- `append({ infoHash, action, reason })` — insert with `createdAt: Date.now()`, returns the row.
- `listRecent({ limit })` — newest first (`created_at` DESC, `id` DESC tiebreaker).
- `deleteOlderThan({ cutoff })` — retention prune.

`UsersRepository`, `SessionsRepository`, and `SettingsRepository` back the auth/setup services (user creation/count, session create/find-active/touch/revoke/prune-expired, settings get/set).

## Write-ahead `pausedByUs`: crash-safe ownership

The most important correctness rule in the codebase (spec §5.4): **Zephyrus only ever resumes torrents it paused itself**, and the ownership flag is written to the DB *before* the pause executes.

In `orchestrator.ts` (`runPolicyCycle`), the sequence per tick is:

```ts
// WRITE-AHEAD (spec §5.4): persist the pause intent BEFORE executing.
for (const action of evaluation.actions) {
  if (action.kind === 'pause') {
    torrentsRepo.setPausedByUs({ hashes: action.hashes, paused: true, reason: action.reason })
    ...
  }
}
const executed = await executeActions(evaluation.actions, capabilities)
```

Why write-ahead:

- **Crash between DB write and client call:** the flag says "ours". On reboot the torrent may still be running in the client; the engine re-derives the pause from live state and re-pauses. No ownership is lost.
- **Crash after the client call:** the flag already matches reality. The next boot resumes it when policy allows — never a user/app pause.
- **Failed or unattempted resumes:** if a resume action fails (or the batch breaks before reaching it), the orchestrator restores the pre-evaluation state for those hashes and skips their flag persistence — the write-ahead flag stays `true`, so ownership survives execution failures too.
- **DB loss:** with no rows, every paused managed torrent is "not provably ours". Reconciliation adopts it as `pausedByUs = false` and latches **safe mode** for the process lifetime: such torrents are never touched. Inaction over wrong action. The mirror rebuilds from the client; pins are lost (fail-safe back to normal management).

### Single reason column vs multi-reason engine state

The engine tracks **multiple concurrent pause reasons** per torrent (e.g. `queue` + `schedule`); a resume happens only when all reasons clear. The DB stores a single `pause_reason` column, chosen by priority `schedule > stalled > slow > queue` (`pickPauseReason`). After a restart, a multi-reason pause is restored as single-reason — a transient overshoot: the very next evaluation re-derives every still-valid reason from live state (schedule window, queue counts, stall continuity) and re-pauses as needed, self-correcting within one tick. The write-ahead flag itself is never lost, so the system never resumes something it paused.

## Reconciliation each tick

`syncTorrentsTable` in the orchestrator keeps the mirror honest:

1. Adopt flags/policy state for DB rows unknown to this process (restart with a preserved DB) — including `pinned`.
2. `upsertMany` the current snapshots (mirror fields only).
3. Adopt unknown torrents into policy state; a managed + paused + not-ours torrent latches safe mode.
4. Delete DB rows (and in-memory flags) for hashes absent from the client — the owning app removed the torrent; the engine additionally writes a "torrent disappeared from client" note.

Related pages: [Architecture](./architecture) (poll loop), [Policy Engine](./policy-engine) (state types), [Invariants](./invariants) (ownership rules), [API Reference](./api-reference) (how the audit trail is exposed).
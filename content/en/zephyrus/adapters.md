---
title: "Adapters"
description: "The TorrentClient contract, the type-level mutation ban, the qBittorrent 5.x adapter, the scriptable mock, and how to add a new client."
section: "Developer Guide"
order: 3
---

All client-specific code lives behind one interface: `TorrentClient` in `src/adapters/torrent-client.ts`. The policy engine and orchestrator see only canonical snapshots and capability flags — they never know which client is on the other side. v1 ships one real adapter (qBittorrent 5.x) and one scriptable in-memory mock used by the integration tests.

## The TorrentClient contract

The complete interface, from `src/adapters/torrent-client.ts`:

```ts
/**
 * SAFETY: `add`, `delete`, `rename`, `setCategory` (and any file/category/
 * removal mutation) are deliberately ABSENT. Zephyrus must never add/remove
 * torrents, touch files, or assign groups — the ban is enforced by this type,
 * not by code review. Do not add such methods for any reason.
 */
export type TorrentClient = {
  connect(): Promise<void>
  listTorrents(): Promise<TorrentSnapshot[]>
  pause(hashes: string[]): Promise<void>
  resume(hashes: string[]): Promise<void>
  reannounce?(hashes: string[]): Promise<void>
  setDownloadLimit?(hashes: string[], bytesPerSec: number): Promise<void>
  setUploadLimit?(hashes: string[], bytesPerSec: number): Promise<void>
  clearLimits?(hashes: string[]): Promise<void>
  capabilities(): ClientCapabilities
}
```

- `connect` authenticates / establishes a session; `listTorrents` returns the full current picture as canonical `TorrentSnapshot[]` (poll-based; the adapter may sync incrementally internally).
- `pause`/`resume` are the only mandatory mutations. Everything else is an **optional capability**; `capabilities()` must honestly report which optional methods work. The orchestrator gates every optional call on both the capability flag and the method's presence.
- Limits are **per-torrent**, bytes/s, `0 = unlimited`. There is deliberately no method for client global settings.

### Type-level mutation ban

The ban on `add` / `delete` / `rename` / `setCategory` is enforced by the type system, and a compile-time guard test fails the build if anyone widens the interface (`src/adapters/torrent-client.test.ts`):

```ts
type BannedClientMethod = 'add' | 'delete' | 'remove' | 'rename' | 'setCategory'
type BannedMethodLeak = Extract<keyof TorrentClient, BannedClientMethod>
type AssertNever<T extends never> = true
// If a banned method ever appears, BannedMethodLeak is that method name
// instead of never, and this assignment fails to compile.
const banHolds: AssertNever<BannedMethodLeak> = true
```

An adapter author cannot "just add" a removal method for convenience — there is no compilable path. This guard is the enforcement mechanism for [Invariant 8, "Type-level mutation ban on the adapter interface"](./invariants#8-type-level-mutation-ban-on-the-adapter-interface), which states the same ban as a non-negotiable rule.

### Error taxonomy

`src/adapters/client-error.ts` defines two typed errors that drive the orchestrator's failure posture:

| Error | Meaning | Orchestrator reaction |
|-------|---------|----------------------|
| `ClientUnreachableError` | Network failure or non-2xx mid-session | Keep last known state, enter degraded mode, retry with backoff. Never crash. |
| `ConnectionUnsupportedError` | Client answered but cannot be supported: Web API too old, login rejected, host banned | Degrade + error-level log. Operator intervention required; blind retries will not fix it. |

## qBittorrent 5.x adapter

`src/adapters/qbittorrent/qbittorrent-client.ts`, built against the qBittorrent Web API **>= 2.11.0** (qBittorrent 5.x). `createQbittorrentClient({ config, fetchImpl })` takes the `client` config block and an injectable `fetch` (the test seam — adapter tests mock HTTP, never a live client).

### Version gate and auth

- `connect()` logs in, then reads `GET /app/webapiVersion` and rejects anything below 2.11.0 with `ConnectionUnsupportedError` ("upgrade the client").
- Login is `POST /api/v2/auth/login`, **form-urlencoded** (the Web API accepts no JSON bodies), with a mandatory `Referer` header pointing at the client base URL (CSRF check).
- Login response shapes differ by version: <= 5.1 replies `200 "Ok."`; >= 5.2 replies `204` with an **empty body** — an empty 2xx body is success, not an error. Wrong credentials: `401` on modern clients, legacy `403`/`200 "Fails."`; a 403 without "Fails." may mean the host is banned after repeated failures. All map to `ConnectionUnsupportedError`.
- The session cookie is `QBT_SID_<webui-port>` since qBit 4.5 (legacy name `SID`); the adapter echoes back whichever name the client set and sends it on every later request.
- On an unexpected `401`/`403` mid-session (e.g. the client restarted), the adapter **re-logs in once and retries the request exactly once**; a second rejection is `ConnectionUnsupportedError`.

### Incremental sync via `rid`

`listTorrents()` performs exactly one `GET /sync/maindata?rid=<n>` per call and maintains the full picture in a merged map:

- First call uses `rid=0` → full snapshot (`full_update: true` replaces the map wholesale).
- Later calls send the last `rid`; deltas are merged field-wise per torrent (partial deltas cannot lose state), and `torrents_removed` hashes are deleted.
- Raw records map to `TorrentSnapshot` via `mapTorrentRecordToSnapshot`: the map key is the authoritative infoHash; `category` → `group` (empty string → null); `added_on` seconds → ms; missing/invalid fields degrade to safe defaults. Results are sorted by infoHash for determinism.

### Actions

All torrent actions are form-urlencoded POSTs with **pipe-joined hashes** (`hashes=a|b|c`); empty hash lists short-circuit without a request.

| Interface method | qBit endpoint | Notes |
|------------------|---------------|-------|
| `pause` | `POST /torrents/stop` | v5 renamed pause/resume; the old `/pause` route 404s in v5 |
| `resume` | `POST /torrents/start` | |
| `reannounce` | `POST /torrents/reannounce` | |
| `setDownloadLimit` | `POST /torrents/setDownloadLimit` | `limit` param, truncated integer bytes/s |
| `setUploadLimit` | `POST /torrents/setUploadLimit` | |
| `clearLimits` | both limit endpoints with `limit=0` | qBit semantics: 0 clears the per-torrent limit |

`capabilities()` reports all three optional capabilities as `true`. Documented v1 decision: no explicit per-request timeout — the surrounding poll loop owns timing and retry policy.

### State mapping

`state-mapping.ts` maps raw v5 state strings to the canonical model; unrecognized strings (future states, legacy v4 names like `pausedDL`) degrade to `unknown` so the engine simply ignores the torrent — tolerant by design, never throws.

| Raw qBit state | Canonical | Rationale |
|----------------|-----------|-----------|
| `downloading`, `forcedDL`, `metaDL`, `allocating` | `downloading` | Download phase, incl. forced/metadata/allocation |
| `stalledDL` | `stalled` | Authoritative stall signal |
| `queuedDL` | `queued` | qBit's internal queue waiting room: occupies a Zephyrus started-slot, never stall-tracked |
| `stoppedDL`, `stoppedUP` | `paused` | v5 renamed paused states |
| `uploading`, `forcedUP`, `queuedUP`, `stalledUP` | `seeding` | Upload phase — never touched by download policy |
| `checkingDL`, `checkingUP`, `checkingResumeData`, `moving` | `checking` | Active but not transferring; `moving` is a transient file op kept untouched |
| `error`, `missingFiles` | `error` | Policy must not touch it |
| anything else | `unknown` | Ignored by the engine |

### Backoff

`backoff.ts` is a pure helper: delay for attempt N (1-based) = `1000 × 2^(N−1)` ms, capped at 5 minutes. The orchestrator clamps the reconnect delay to at most the poll interval and tracks a single retry timer (a new failure replaces the pending retry instead of stacking timers).

## The scriptable mock adapter

`src/adapters/mock/mock-client.ts` provides `createMockClient(options)` — an in-memory `TorrentClient` that is living proof the engine/runtime never depend on qBittorrent specifics. Like the real adapter, it exposes no banned mutation methods. It always implements the optional capability methods (scriptable) and remains assignable to `TorrentClient`.

Behavior: `pause` sets snapshots to `paused` (speed 0); `resume` flips `paused` → `downloading`; limits are stored in a map. Every interaction is recorded in order.

| Scripting API | Purpose |
|---------------|---------|
| `setSnapshots({ snapshots })` | Replace the whole torrent list (deep-copied in) |
| `setState({ infoHash, state })` | Patch one torrent's canonical state |
| `getSnapshots()` / `getCalls()` / `clearCalls()` | Inspect state and the ordered call log (`method`, `hashes`, `value`, `at`) |
| `failNextLists({ count })` | Next N `listTorrents()` calls reject with `ClientUnreachableError` (degraded-mode tests) |
| `failures.failPauseHashes` / `failResumeHashes` (options) | Per-hash pause/resume rejections (mid-batch failure tests) |
| `delays.listMs` / `pauseMs` / `resumeMs` (options) | Artificial latency for concurrency/re-entrancy tests |
| `getLimits()` | Currently stored per-torrent limits |
| `capabilities` (option) | Simulate a capability-poor client |
| `now` (option) | Injectable clock for deterministic call timestamps |

Typical integration pattern (see [Testing](./testing)): build a world with the mock + a temp-dir DB, call `orchestrator.tick()`, then assert on `mock.getCalls()` and the DB flags.

## Adding a new client (Transmission, Deluge, ...)

The engine and its tests are `client.type`-independent (spec acceptance criterion 12: a new adapter must not touch a single line of engine code). Steps:

1. **Extend the config schema.** `clientSchema` in `src/config/schema.ts` currently uses `type: z.literal('qbittorrent')`, structured so a second client turns it into a discriminated union. Add the new variant with that client's connection fields; everything outside the `client` block stays client-agnostic.
2. **Implement `TorrentClient`** in `src/adapters/<client-name>/<client-name>-client.ts`. Map the client's states into the canonical `TorrentState` model (a `state-mapping.ts` per adapter is the established pattern), translate pause/resume/limits into the client's API, and report honest `capabilities()`. Do not add banned methods — the compile guard will reject them anyway. Throw `ClientUnreachableError` for transient failures and `ConnectionUnsupportedError` for operator-fixable ones.
3. **Wire the factory.** The orchestrator takes an injectable `clientFactory` (default: `createQbittorrentClient`); `src/index.ts` constructs the initial adapter. Select the adapter by `config.client.type` in both places. Note: the first-run setup wizard (`src/services/setup-service.ts`) currently hardcodes `type: 'qbittorrent'` for its connection test — extend it too if the wizard should support the new client.
4. **Test with HTTP mocks.** Follow `qbittorrent-client.test.ts`: inject a fake `fetchImpl`, cover auth, state mapping, incremental sync (if any), and error taxonomy. Add mock-adapter integration scenarios only if the new client changes runtime behavior — the policy suite itself needs no changes.
5. **Leave the engine alone.** If a feature seems to require engine changes for one client, model it as a capability flag instead; the engine already degrades gracefully (e.g. limit actions become audit notes when the adapter lacks limit capability).

One Zephyrus instance manages exactly one client connection; multiple clients mean multiple instances.

Related pages: [Architecture](./architecture), [Policy Engine](./policy-engine), [Testing](./testing), [Integration](./integration) (how suite apps hand torrents over via groups).
---
title: "Invariants"
description: "Psyche's non-negotiables: metadata-first, zero spec deviations, permanent SQLite, arr-scope boundaries, the envelope mandate, and mechanical layering."
section: "Developer Guide"
order: 60
---

These rules are binding for every change to Psyche. They come from the repo's single source of truth (`psyche.md`, Parts A–D) and its agent editing rules (`AGENTS.md`); where this page summarizes, those documents govern. Several are enforced mechanically — by types, lint, or database constraints — not by review.

## Metadata first

**Metadata first, download second.** Library entities (series, seasons, episodes, movies, people) are TMDB-anchored and created at subscribe/add time — **never from download events**. Consequences that every feature must preserve:

- The subscription engine diffs **TMDB** for new seasons/episodes; indexers are consulted only when there is something to find.
- Post-download work is organizing (move/rename/link), not identification. The organizer resolves queue → request → subscription → pre-existing entity and never creates or re-identifies rows.
- Identity never depends on release naming, so scoring cannot drift between grab and import, and language behavior is a property of cached metadata, not of files.

This is the structural fix for the classic *arr weaknesses: no custom-format mismatch, no upgrade loops, no language-fallback failures. See [Metadata pipeline](./metadata-pipeline).

## Zero deviations

Psyche starts with **zero deviations from Part A** (the suite standard); the A.12 deviations table is empty. Any deliberate deviation must be **recorded in A.12 before implementation** — never shipped first and documented later. Spec/code discrepancies found during inspection (e.g. the TMDB key's move to `service_connections`) are implementation evolution noted in the spec, not silent drift.

## SQLite is permanent

SQLite is the **permanent** database for this domain; PostgreSQL is rejected outright — a second engine is deployment friction this app does not need. One file under `/config`, WAL + foreign keys on every connection, Drizzle as the only access path, repositories as the only Drizzle consumers. Do not add engine abstractions "for later". See [Database](./database#pragmas-and-migrations).

## Scope: acquire + organize

Psyche's scope is the arr model: **acquire and organize**. Permanently out of scope:

- playback, transcoding, post-processing, and any streaming/player UI;
- subtitles (dedicated tools own that domain — no subtitle tables, no subtitle logic).

Also fixed boundaries: **people are browsable, not subscribable**; movies are single-version in v1 (the schema must not preclude later multi-version, but nothing implements it); the library is **single-admin** — no multi-user accounts, roles, or request workflow.

## Envelope mandate

Every API branch emits `{ success: true, data }` or `{ success: false, error, code, details? }` — **`code` is always present**. The centralized error handler covers every failure class (Zod, app errors, Fastify-native, not-found, unknown); the web client preserves `code`/`details`. New routes must not invent response shapes. See [API reference](./api-reference#response-envelope).

## Layering

Routes → Controllers → Services → Repositories → Database, **no layer skipped**, enforced by ESLint restricted-path rules (routes→services/repositories/adapters and controllers→repositories/DB are errors). Controllers stay thin one-liner delegations; services hold business logic; Awilix registrations are explicit singletons with a boot smoke-check. See [Architecture](./architecture#layering).

## Settings mapping

Settings live in the DB, Zod-validated, with **camelCase (API) ↔ snake_case (DB)** key mapping per dotted segment. Defaults seed on boot for absent keys; sensitive values mask to `********` in every response. Quality-profile defaults seed **only into an empty table** — user-deleted defaults are never resurrected. There is no config file and no declarative export/apply layer.

## Auth and sessions

The v1 auth stack is fixed: **session + API key**, nothing else (OIDC/SSO is deferred). Sessions are SQLite-backed with a 24 h cookie; **restarts never log users out** — the secret persists at `/config/session.secret` (env override ≥ 32 chars always wins; unwritable config dir degrades to an ephemeral secret with a loud warning). Session auth wins over key auth. API-key plaintext is shown exactly once; only the hash is stored. Secrets are never logged — pino redaction runs before the persisted sink, plus a binding-level scrub.

## Jobs and history

The job contract is part of the suite standard: essential pipeline jobs (queue-poller, library-organizer, download-retention) **can never be stopped** (409) or disabled; run history persists in `job_logs` and is **never cleared by a restart**; stale `running` rows from a crash are finalized as failed at boot. Manual triggers return immediately and run detached. New jobs join the same registry, schedule-override, and history machinery — no ad-hoc timers.

## Scored once

Every release is scored **once**, at search/grab time, from release attributes. `score_total` and `quality_tag` are copied **verbatim** into the queue and never recomputed downstream; file-link `quality_tag` is read-only provenance. No re-scoring at import means no grab/import drift and no upgrade loops by construction. See [Release matching](./release-matching#scoring).

## Deferred and out of scope

The following are **not implemented** and must not be promised by docs, UI, or API surface. They are deliberate deferrals (or permanent rejections), not bugs:

| Item | Status |
|------|--------|
| Trakt/Plex watchlist or import-list sync | Deferred — discovery + manual add covers the core loop. |
| Multi-version movies/episodes | Deferred — schema must not preclude it; v1 is single-file. |
| Request/approval workflow | Deferred — single-admin library in v1. |
| OIDC/SSO | Deferred — session + API-key stack is v1 auth. |
| Notifications/webhooks (ntfy, Discord, Telegram, …) | Deferred. |
| Plugin runtime | Deferred — typed adapter contracts are the v1 extension surface. |
| Transcoding/post-processing | **Permanently out of scope.** |
| PostgreSQL | **Permanently rejected.** |
| Subtitles | **Out of scope** — dedicated tools own the domain. |

When implementing anything adjacent to these, keep the schema and contracts from *precluding* the deferred items where the spec says so — but ship nothing that implies they exist.
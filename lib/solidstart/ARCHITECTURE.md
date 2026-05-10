# sync_helper for SolidStart — Proposed Architecture

A web/Tauri counterpart to `sync_helper_flutter`. Same offline-first pattern,
same wire protocol, same backend (`sync_helper_service`) — different host
runtime (browser + SSR + Tauri WebView instead of Flutter).

---

## Goals

1. Offline-first reactive data layer for SolidStart apps.
2. Same code runs in three environments:
   - **Browser (after hydration)** — full client.
   - **SolidStart server (during SSR)** — fetch-only mode, no local DB.
   - **Tauri WebView (mobile/desktop)** — full client, no SSR.
3. Reuse `sync_helper_service` unchanged — no backend modifications.
4. Reactivity native to SolidJS (signals, stores, resources).

---

## Non-Goals

- Replacing the Flutter library — it stays as-is for Flutter apps.
- New sync protocol — we conform to the existing one.
- New auth scheme — Firebase JWTs as today.

---

## Wire Protocol (unchanged)

The library speaks the same HTTP + SSE protocol as `sync_helper_flutter`:

| Endpoint              | Method | Purpose                              |
|-----------------------|--------|--------------------------------------|
| `/data?name=&lts=...` | GET    | Pull rows newer than `lts`           |
| `/data`               | POST   | Upload `is_unsynced` rows (lts gate) |
| `/events?app_id=...`  | GET    | SSE stream of change notifications   |
| `/models?app_id=...`  | GET    | Schema fetch for the code generator  |
| `/latest-lts?name=`   | GET    | Diagnostic                           |

Same conflict model: server-wins on `lts` mismatch, archive table for soft
deletes.

---

## Layers

```
┌──────────────────────────────────────────────────────────────┐
│  Application code (SolidStart routes / Tauri WebView UI)     │
│    createSyncQuery(sql)   write(table, data)                 │
├──────────────────────────────────────────────────────────────┤
│  Reactivity adapter (SolidJS)                                │
│    Signal + store glue, change-table subscription            │
├──────────────────────────────────────────────────────────────┤
│  Sync engine (framework-agnostic core)                       │
│    push/pull loop, SSE listener, archive deletes, lts track  │
├──────────────────────────────────────────────────────────────┤
│  Local store              │   Transport                      │
│    sqlite-wasm in browser │     fetch + EventSource          │
│    sqlite-wasm in Tauri   │     (same in all hosts)          │
└──────────────────────────────────────────────────────────────┘
```

The two bottom rows are pure TS, no framework dependency. The reactivity
adapter is the only SolidJS-aware layer; a future React/Svelte adapter
would slot in alongside it without touching the engine.

---

## Local Store

**Choice: sqlite-wasm** (`@sqlite.org/sqlite-wasm` or `wa-sqlite`).

Why:
- Same SQL surface as Flutter — keeps `models.json` schema and migration
  output portable.
- Works in browser (OPFS-backed for persistence) and Tauri (same WASM
  module, optionally swap to native sqlite via Tauri plugin later).
- IndexedDB alternative was considered and rejected: requires translating
  every query, and the migration / `lts` / `is_unsynced` semantics are
  awkward without SQL.

DB path layout mirrors the Flutter package:
```
OPFS:/<appId>/<userId>/helper_sync.db
```
User isolation via separate DB files. Clear-user-data = delete file.

---

## Reactivity (SolidJS)

Three primitives, all backed by the local SQLite:

```ts
// Reactive query — re-runs when any of its tables change.
const tasks = createSyncQuery<Task>(
  'SELECT * FROM tasks WHERE done = 0 ORDER BY priority',
  { tables: ['tasks'] }
);

// Single-row variant.
const me = createSyncOne<User>(
  'SELECT * FROM users WHERE id = ?',
  () => [userId()]
);

// Imperative writes — return promises, integrate with createResource.
await write('tasks', { id, name, priority });
await writeBatch('tasks', rows);
await writeTransaction(async (tx) => { ... });
await del('tasks', id);
```

Implementation: a per-DB pub/sub. After every successful write or pull,
the engine emits the affected table names; `createSyncQuery` listens and
re-executes its SQL. Identical mental model to Flutter's `watch` stream.

---

## SSR Strategy

The hardest design question. We pick a clean rule:

> **The local SQLite layer never runs on the SolidStart server. Server-side
> rendering uses HTTP-only fetches against `sync_helper_service` directly.**

Why: spinning up sqlite-wasm + OPFS per render is wrong (per-request,
ephemeral, no persistence point). Easier to fetch once and bake into HTML.

### Server render path

```ts
// In a route's load function (runs on server during SSR):
const initial = await fetchInitial<Task[]>('tasks', { lts: null });
return { tasks: initial };
```

The route's `load` calls a thin server-only fetch helper that:
1. Reads the user's Firebase ID token from cookies.
2. Calls `GET /data?name=tasks` on `sync_helper_service`.
3. Returns rows. Serialized into HTML by SolidStart automatically.

### Client hydration path

On hydrate:
1. Open sqlite-wasm, run migrations.
2. **Seed** the local DB with the SSR data so `createSyncQuery` returns
   the same rows immediately — zero flicker on the first frame.
3. Kick off normal sync (push, pull, SSE).
4. Components transparently switch from "data passed via SSR props" to
   "data from local SQLite". The reactive query starts emitting; if the
   pull changes anything, the UI updates.

### Tauri path

Skip SSR entirely. App opens, sqlite-wasm opens, UI reads from local DB.
On first launch the DB is empty so UI shows a loading state until the
first pull completes; on subsequent launches it shows last-known data
instantly.

---

## Auth

**Browser / Tauri:** Firebase JS SDK. The engine asks for a fresh ID
token before each network call (Firebase handles caching + refresh).

**SolidStart server (SSR only):** the route's request comes with a
Firebase session cookie (set client-side after login). The server-side
fetch helper reads that cookie and forwards it as `Authorization:
Bearer <token>` to `sync_helper_service`. No service account, no
elevated privilege — server acts strictly on behalf of the user.

---

## Code Generation

CLI: `pnpm sync-generate http://server:8080 your.app.id`.

Mirrors `bin/sync_generator.dart`:
1. Prompt for Firebase email/password.
2. POST `/models` to authenticate + fetch schema.
3. Emit `src/generated/sync.ts` containing:
   - TS types per table (`type Task = { id: string; ... }`).
   - Migration list (CREATE / ALTER statements pulled from
     `client_create` / `client_migration` JSON in the model row).
   - `SYNCABLE_TABLES`, `SYNCABLE_COLUMNS` maps consumed by the engine.

Run after every backend schema bump, same as the Flutter version.

---

## Package Layout

```
sync_helper_web/                  (separate package, not nested in this repo)
├── package.json
├── src/
│   ├── core/                     framework-agnostic
│   │   ├── store.ts              sqlite-wasm wrapper, migrations
│   │   ├── engine.ts             push/pull/SSE loop
│   │   ├── transport.ts          HTTP + EventSource client
│   │   ├── auth.ts               Firebase token provider interface
│   │   └── types.ts
│   ├── solid/                    SolidJS adapter
│   │   ├── createSyncQuery.ts
│   │   ├── createSyncOne.ts
│   │   └── SyncProvider.tsx
│   ├── ssr/                      server-only helpers
│   │   └── fetchInitial.ts
│   └── index.ts
├── bin/
│   └── sync-generate.ts          code generation CLI
└── README.md
```

Published as `sync_helper_web` (or scoped `@yourorg/sync-helper-web`).

---

## Open Questions / Tradeoffs

1. **OPFS support gap.** Older Safari on iOS lacks full OPFS. Fallback
   path: in-memory sqlite-wasm with no persistence (treat as ephemeral
   cache, re-pull on every load). Acceptable for v1.
2. **Bundle size.** sqlite-wasm is ~1MB gzipped. Lazy-load it after
   hydration so it doesn't block first paint.
3. **SSR seeding cost.** Serializing thousands of rows into HTML balloons
   payload size. Cap SSR to "above the fold" data; let the client pull
   the rest after hydration.
4. **Schema drift between SSR fetch and client pull.** Both go through
   the same API and respect the same model version, so this is no worse
   than two clients seeing different lts values — server handles it.
5. **Tauri SQLite native vs WASM.** Start with WASM everywhere for
   simplicity. If perf is an issue on mobile Tauri, swap to the native
   sqlite Tauri plugin behind the same `core/store.ts` interface.

---

## Milestones

1. **M1 — core engine, no UI.** sqlite-wasm wrapper + push/pull against
   a real `sync_helper_service`. CLI test harness.
2. **M2 — SolidJS adapter.** `createSyncQuery` + provider + write API.
   Demo SolidStart app reads/writes one table.
3. **M3 — SSR seeding.** `fetchInitial` on the server, hydration seed,
   no-flicker first frame.
4. **M4 — code generator.** `sync-generate` CLI, types + migrations.
5. **M5 — Tauri.** Verify same bundle runs in Tauri WebView; persistence
   via OPFS or Tauri sqlite plugin.

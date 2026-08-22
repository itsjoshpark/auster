# Auster — Design Specification

Auster is a macOS menu-bar Dropbox sync client in SwiftUI, replicating Maestral's
behavior. This spec defines the architecture; algorithms live in
[research/maestral-sync-engine.md](research/maestral-sync-engine.md), API usage in
[research/dropbox-api-notes.md](research/dropbox-api-notes.md), UX in
[research/maestral-ux.md](research/maestral-ux.md), decisions in
[decisions.md](decisions.md).

## 1. Repository layout

```
auster/
├── Auster.xcodeproj            # app target (thin UI shell)
├── Auster/                     # app sources
│   ├── AusterApp.swift         # @main: MenuBarExtra + Settings scenes, onOpenURL
│   ├── MenuBar/                # menu bar window views + status icon logic
│   ├── Settings/               # settings tabs (General, Selective Sync, Account, About)
│   ├── Onboarding/             # setup wizard window
│   ├── Windows/                # Recent Changes, Sync Issues windows
│   ├── Support/                # notifications, login item, Sparkle glue, Finder reveal
│   └── Resources/              # assets, Info.plist (URL scheme db-<APPKEY>, LSUIElement)
├── AusterCore/                 # local Swift Package — the engine (no UI imports)
│   ├── Package.swift           # deps: SwiftyDropbox, GRDB
│   ├── Sources/AusterCore/
│   │   ├── Client/             # DropboxService: async wrappers over SwiftyDropbox,
│   │   │                       #   retry/backoff, protocol for mocking
│   │   ├── Database/           # GRDB schema + DAOs: index, hash cache, errors, history
│   │   ├── FileSystem/         # FSEventStream wrapper, ignore filter, local scanner,
│   │   │                       #   content hasher, path store (casing/normalization),
│   │   │                       #   atomic file ops, cache dir
│   │   ├── Engine/             # SyncEngine actor: upload/download cycles, conflict
│   │   │                       #   resolution, event cleaning, catch-up scan
│   │   ├── Coordination/       # SyncCoordinator: lifecycle, workers, connection
│   │   │                       #   monitor, pause/resume, selective sync ops
│   │   ├── State/              # SyncState (@Observable façade), SyncEvent/Activity
│   │   │                       #   models, config store (UserDefaults-backed)
│   │   └── Auth/               # link/unlink flows, account info cache
│   └── Tests/AusterCoreTests/
└── docs/                       # this documentation
```

Rule: `AusterCore` never imports AppKit/SwiftUI (Foundation + CryptoKit +
CoreServices/FSEvents only, plus deps). The app target contains no sync logic.

## 2. Core components and boundaries

- **`DropboxService`** (protocol + live implementation): every Dropbox route the
  engine needs, exposed as `async throws` methods with typed errors
  (`DropboxServiceError`), central retry/backoff (rate limits, 5xx,
  data-corruption re-tries), and transfer progress callbacks. The engine never
  touches SwiftyDropbox types directly — this is the mocking seam.
- **`SyncDatabase`** (GRDB): tables `index`, `hash_cache`, `sync_errors`,
  `history` exactly as in the sync-engine reference §1; plus a `state` key-value
  table (cursors, indexing flags, pending downloads). Single writer queue.
- **`LocalFileMonitor`**: FSEventStream (file-level events,
  `kFSEventStreamCreateFlagFileEvents`) → raw event structs → `IgnoreFilter`
  (research §5.2) → `AsyncStream` consumed by the coordinator. Also hosts
  `rescan(path)` synthesis.
- **`PathStore`**: dbx-path ↔ local-path conversion, normalization (lowercase +
  NFC), cased-path resolution with LRU cache, case-sensitivity probe.
- **`ContentHasher`**: streaming Dropbox content hash (CryptoKit), backed by the
  hash-cache table.
- **`SyncEngine`** (actor): the algorithms of research §§3–9. Owns database +
  hasher + path store; takes `DropboxService` and `LocalFileMonitor.ignore` as
  dependencies. Exposes `downloadCycle()`, `uploadCycle(events:)`,
  `catchUpScan()`, `fetchRemoteItem(path:)`, conflict logic internal.
- **`SyncCoordinator`** (actor): owns the worker task group (longpoll loop, upload
  loop, pending-downloads drain, connection monitor via `NWPathMonitor`), the
  startup sequence, pause/resume/cancel, selective-sync include/exclude
  operations, rebuild-index. Publishes into `SyncState`.
- **`SyncState`** (`@Observable`, MainActor): status enum (setup / connecting /
  idle / syncing(progress) / paused / error(fatal)), account info + usage,
  activity list, recent history, sync-error list, notification snooze. The only
  thing views read.
- **App target**: `MenuBarExtra` (window style) rendering from `SyncState`;
  Settings scene with 4 tabs; onboarding wizard window; notifications manager
  (UserNotifications) driven by engine events; `SMAppService` login item; Sparkle.

## 3. Data flow

- **Remote → local**: longpoll task → coordinator → `SyncEngine.downloadCycle()`
  (list/continue → clean → order → apply with conflict table) → DB + disk (via
  ignore filter) → `SyncState` updates + notification batch.
- **Local → remote**: FSEvents → ignore filter → debounced batch → coordinator →
  `SyncEngine.uploadCycle(events:)` (clean → convert+hash → order → per-event
  handlers) → DB + `SyncState`.
- **Concurrency**: one sync mutation at a time (engine actor serializes cycles);
  parallelism only *inside* a cycle for transfers (bounded task groups, ≤6 each
  direction). Cancellation via `Task` cancellation checked between items.

## 4. Auth & onboarding flow

Per research/dropbox-api-notes §1: `setupWithAppKeyDesktop` at launch;
`authorizedClient != nil` decides wizard vs normal startup. Wizard link page runs
`authorizeFromControllerV2`; `.onOpenURL` → `handleRedirectURL`. After linking:
fetch account (reject team accounts with a friendly "not yet supported" page —
D4), pick folder (merge/create), initial selective-sync tree, then coordinator
start. Unlink (settings): stop sync, `unlinkClients()`, wipe DB + cursors, keep
local files, relaunch into wizard.

## 5. Error handling

- `SyncItemError` (per-path): recorded in `sync_errors`, surfaced in Sync Issues,
  auto-retried on next pass/startup; never stops the cycle.
- `SyncFatalError` (folder missing, auth revoked, DB corruption, unexpected):
  pause sync, error state + notification, targeted recovery UI (relocate folder /
  re-link / auto-rebuild on DB corruption).
- Connectivity errors: silent auto-pause/resume ("Connecting…" status).
- All safety principles of decisions.md D9 apply.

## 6. Testing strategy

- **Unit (bulk of coverage, TDD)**: event cleaning, conflict decision table,
  ordering, path/normalization, hashing (against Dropbox's published test
  vectors), DB round-trips — pure functions/actors with mock `DropboxService` +
  temp directories.
- **Scenario tests**: a `FakeRemote` in-memory Dropbox implementing
  `DropboxService` (paths, revs, cursors, autorename semantics) + a temp local
  folder; drive full engine cycles through scripted scenarios (create/edit/
  delete/move both sides, conflicts, offline catch-up, selective sync, casing).
  These are the acceptance tests for the engine.
- **Integration (opt-in)**: real API against Josh's account under
  `/AusterIntegrationTests/<uuid>`, env-gated, self-cleaning.
- **UI**: lightweight — state-driven view models unit-tested; manual test script
  per milestone.

## 7. Distribution (final phase)

Developer ID signing, hardened runtime, notarization, DMG, Sparkle appcast
(EdDSA-signed), release CI later. Not needed during development; run from Xcode.

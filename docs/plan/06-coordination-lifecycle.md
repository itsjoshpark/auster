# Phase 6 — Coordination, Lifecycle & Error States

**Goal:** The always-on machinery: startup sequence, longpoll + upload worker
loops, connection monitoring, pause/resume, fatal-error handling, rebuild index,
and the observable `SyncState` the UI reads.

**Reference:** engine-doc §2 (workers), §3 (startup), §9 (guard rails), §10
(status); maestral-ux §9 (pause persistence, auto-pause on disconnect).
**Definition of done:** app left running stays converged through network drops,
pause/resume, and relaunches; state transitions unit-tested.

### Task 6.1: Error taxonomy & SyncState

**Files:** create `State/SyncState.swift`;
tests `Tests/.../SyncStateTests.swift`.
(`SyncItemError` / `SyncFatalError` already exist from Phase 4 Task 4.2.)

**Interfaces produced:**

```swift
@MainActor @Observable public final class SyncState {
    public enum Status: Equatable { case needsSetup, connecting, idle, syncing(detail: String),
                                    paused, fatalError(SyncFatalError) }
    public private(set) var status: Status
    public private(set) var account: AccountInfo?
    public private(set) var usageText: String            // "12.3% of 2 TB used"
    public private(set) var activity: [ActivityItem]     // in-flight transfers (path, direction, done/total bytes)
    public private(set) var recentChanges: [HistoryEntry]
    public private(set) var syncErrors: [SyncErrorEntry]
    // mutation funcs called by coordinator (all MainActor-hopping helpers)
}
public struct ActivityItem: Identifiable, Sendable, Equatable { public var id: String /* dbxPathLower */; public var dbxPath: String; public var direction: SyncDirection; public var completed: Int64; public var total: Int64 }
```

- [x] TDD state mutation helpers (activity add/update/remove, status precedence:
  fatalError > paused > syncing > connecting > idle). Commit.

### Task 6.2: SyncCoordinator

**Files:** create `Coordination/SyncCoordinator.swift`,
`Coordination/ConnectionMonitor.swift`; tests `Tests/.../SyncCoordinatorTests.swift`.

**Interfaces produced:**

```swift
public actor SyncCoordinator {
    public init(service:, database:, config:, state: SyncState, engine: SyncEngine,
                monitor: LocalFileMonitor, notifier: SyncNotifying /* Phase 8 impl; protocol here */)
    public func start() async        // full startup sequence then steady-state loops
    public func pause() async        // persists isPaused (ux §9)
    public func resume() async
    public func stopForQuit() async
    public func rebuildIndex() async // stop → clear index+cursors → start (engine-doc §9)
    public func setExcluded(items: Set<String>) async  // Phase 7 fills real logic; stub now
}
public protocol SyncNotifying: Sendable {    // engine-doc §10 batching rules; UI impl in Phase 8
    func notifyDownloadBatch(_ completed: [SyncItemEvent])
    func notifyConflict(_ event: SyncItemEvent)
    func notifyItemError(_ error: SyncItemError)
    func notifyFatal(_ error: SyncFatalError)
}
```

Startup sequence (engine-doc §3, minus team steps): ensure root present → account
+ usage refresh → retry download errors (`fetchRemoteItem` each) → drain
pending-downloads queue → `downloadCycle()` → `catchUpScan` + `uploadCycle` →
start steady loops. Steady loops as child tasks:
**longpoll loop** (`longpoll(cursor, 40)` → on changes: sleep 2 s →
`downloadCycle`; honor backoff; usage refresh after cycles),
**upload loop** (await monitor stream, debounce 1 s of quiet, `uploadCycle`),
**connection monitor** (`NWPathMonitor`; also map `.connection` errors: status
`connecting`, retry with backoff, auto-resume — never flip user `isPaused`).
Error funnel per engine-doc §2: connection → auto-pause+auto-resume; fatal →
`state.status = .fatalError`, notify, stop loops; item errors → DB + state list,
cycle continues.

- [x] TDD with mock service + temp dirs (fake longpoll returning scripted
  sequences): startup order (recording mock asserts call order); longpoll
  changes triggers download; connection error flips to connecting and recovers
  when service healed; pause cancels loops and persists; resume replays startup;
  quit is clean (no orphan tasks — assert via task handles); rebuildIndex clears
  cursor + index then reconverges; fatal folder-missing surfaces and loops stop.
- [x] Wire into app: on launch, if `AuthManager.isLinked` and folder configured →
  build the object graph (composition root `Auster/Support/AppEnvironment.swift`,
  create it here) and `coordinator.start()`; else `.needsSetup`. Temporary debug
  window rows: status text + pause/resume button (replaced Phase 8).
- [x] Manual soak: run 10+ min with live account; toggle Wi-Fi off/on; pause,
  edit files, resume → converges. Commit.
      *Partly done 2026-08-23. A 12-minute soak with a remote and a local change
      every 90 s converged every round with no errors, and quit/relaunch
      mid-divergence resumed from the cursor and produced a conflicted copy
      rather than a lost update. **Still outstanding:** the Wi-Fi toggle and the
      pause/resume path. The machine's only active interface carries this
      session, so dropping it is Josh's to do; pause/resume lives behind the
      MenuBarExtra panel, which does not accept synthesised clicks.*

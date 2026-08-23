# Phase 5 — Local Monitoring & Upload Sync (Local → Remote)

**Goal:** FSEvents watching with the self-event ignore mechanism, event
cleaning, upload handlers, and the offline catch-up scan. After this phase the
engine is a complete two-way syncer.

**Reference:** engine-doc §5 (all), §6 (catch-up), §7 (transfers), §8.
**Definition of done:** scenario tests green, including the echo test (a
download must not trigger an upload); manual: edit/create/move/delete files
locally and see them on dropbox.com; big-file (>10 MB) upload works.

### Task 5.1: FSEvent stream & ignore filter

**Files:** create `FileSystem/LocalFileMonitor.swift`, `FileSystem/IgnoreFilter.swift`,
`FileSystem/RawFSEvent.swift`; tests `Tests/.../IgnoreFilterTests.swift`,
`Tests/.../LocalFileMonitorTests.swift`.

**Interfaces produced:**

```swift
public struct RawFSEvent: Sendable, Equatable {
    public enum Kind: Sendable, Equatable { case created, deleted, modified, moved(to: URL) }
    public var kind: Kind; public var url: URL; public var isDirectory: Bool
}
public final class IgnoreFilter: FileEventIgnoring, @unchecked Sendable {  // lock-protected; engine-doc §5.2
    public func ignoring<T>(_ expected: [ExpectedFSEvent], _ body: () throws -> T) rethrows -> T
    public func shouldDrop(_ event: RawFSEvent) -> Bool   // consumes one-shot matches; recursive dir matches persist; TTL 2 s after op end
    public func expireStale()
}
public final class LocalFileMonitor: @unchecked Sendable {  // FSEventStream (file-level flags), root-scoped
    public init(root: URL, ignore: IgnoreFilter)
    public var events: AsyncStream<RawFSEvent> { get }     // post-filter
    public func start() throws; public func stop()
    public func synthesizeRescan(of url: URL, index: SyncDatabase, pathStore: PathStore)  // engine-doc §4 rescan: file→modified, dir→created+walk, missing→deleted (vs index)
}
```

FSEvents flag mapping notes (implementer): use
`kFSEventStreamCreateFlagFileEvents | ...NoDefer | ...WatchRoot`; a single
callback entry can carry combined flags (renamed+modified…) — map: `ItemRenamed`
pairs into `.moved` by matching consecutive renamed events with the same event id
(unpaired renamed → treat as created-or-deleted by checking disk existence);
`ItemCreated`/`Removed`/`Modified`/`InodeMetaMod` → respective kinds; root-changed
flag → surface as a special event the coordinator turns into the folder-missing
check. Always verify against current disk state when flags are ambiguous —
correctness comes from the cleaning stage + rescans, not perfect flag decoding.

- [x] TDD IgnoreFilter pure logic: one-shot match consumed; recursive dir ignore
  drops child events (moved: both src+dst must be children); non-matching passes;
  TTL expiry (inject clock).
- [x] LocalFileMonitor integration-style test in a temp dir: create/modify/delete
  → events arrive; op inside `ignoring` → no event; rename → single `.moved`
  (allow fallback pair created+deleted — assert via cleaned output of Task 5.2 to
  avoid flag-decoding flakiness).
- [x] Commit.
      *Live check done 2026-08-23 against the test account: local create, edit,
      move and delete all reached Dropbox within five seconds, and a 15 MiB file
      uploaded through a session with its sha256 intact.*

### Task 5.2: Event cleaning

**Files:** create `Engine/LocalEventCleaner.swift`; tests `Tests/.../LocalEventCleanerTests.swift`.

**Interfaces produced:**
`public enum LocalEventCleaner { static func clean(_ events: [RawFSEvent], isExcluded: (URL) -> Bool, requestRescan: (URL) -> Void) -> [RawFSEvent] }`
— implements engine-doc §5.3 verbatim (split moves → per-path collapse rules →
recombine moves unless a side is excluded → prune children of moved/deleted
dirs; use dictionaries/sets, target ≥20k events < 1 s).

- [x] TDD each §5.3 rule: created+deleted (temporary) → dropped + rescan
  requested; deleted+created → modified; type change → delete+create pair;
  n(created)>n(deleted) → single created; move with side-events → stays split;
  move to excluded path → split into delete (src) + nothing (dst excluded
  upstream later); dir move prunes matching child moves; dir delete prunes child
  deletes; 20k-event performance test (< 1 s). Commit.

### Task 5.3: Upload handlers

**Files:** create `Engine/UploadApplier.swift`; tests `Tests/.../UploadApplierTests.swift`.

Implements engine-doc §5.6 exactly, including the two pre-checks
(selective-sync conflict rename, normalization conflict rename — both use
`PathStore.conflictedCopyName` and fire `SyncEngineEvents.rescanRequested`,
which the coordinator routes to `LocalFileMonitor.synthesizeRescan`),
size-stability wait,
skip-if-identical remote check, write-mode selection, server-autorename
mirroring (§5.6 "conflicted copy" mirror: move local file to server-returned
name inside an ignore, drop old index row), move handling (dest-occupied
rev-guarded delete first, source-missing fallback→rescan, unicode-norm-only
rename skip, post-move recursive index refresh), deletion guards (type-mismatch
skips + untrack, parentRev-guarded delete, excluded-path skip, never delete when
remote changed since lastSync).

- [x] TDD minimum set (MockDropboxService + temp dir):
  new file uploads with `.add` + correct clientModified;
  modified file uploads with `.update(rev)`;
  content identical to remote → skipped, index refreshed;
  stale rev → server conflicted copy → local file renamed to match, both files
  in index after next download cycle (integration of 4+5 in Task 5.5);
  folder create when remote folder exists → skipped + index refreshed;
  local move → remote move, subtree index refreshed;
  move onto existing file → remote replaced (guarded delete then move);
  local delete of remotely-changed file → skipped, untracked;
  local delete happy path with parentRev;
  file at user-excluded path created → renamed "(selective sync conflict)";
  two local names differing only by case → second renamed "(case conflict)".
- [x] Commit per green cluster.

### Task 5.4: Upload cycle + catch-up scan

**Files:** modify `Engine/SyncEngine.swift`; create `Engine/CatchUpScanner.swift`;
tests `Tests/.../UploadCycleTests.swift`, `Tests/.../CatchUpScannerTests.swift`.

**Interfaces produced:**
`SyncEngine.uploadCycle(rawEvents: [RawFSEvent]) async throws` — clean → convert
(hash in parallel) → filter excluded → order per §5.5 (deletes ∥, dir-moves
sequential, rest by depth ∥ ≤6) → apply → history/notify hooks → set
localCursorTimestamp.
`CatchUpScanner.scan(root:database:pathStore:localCursor:) throws -> [RawFSEvent]`
— engine-doc §6 (mtime vs max(lastSync, localCursor); exact-casing existence for
deletions; root-presence guard **before** emitting deletions).

- [x] TDD catch-up: untracked file → created; tracked newer-mtime → modified;
  tracked missing → deleted; casing-drift counts as missing; root missing →
  throws fatal (no deletion storm); type change → pair.
- [x] TDD cycle ordering with a recording mock (deletes before creates; parents
  before children). Commit.

### Task 5.5: Two-way scenario suite (engine acceptance tests)

**Files:** create `Tests/.../ScenarioTests.swift` + `Tests/.../ScenarioHarness.swift`.

Harness: MockDropboxService (as FakeRemote) + temp root + real SyncDatabase +
SyncEngine; helpers `remoteWrite/localWrite/runDownloadCycle/runUploadCycle/
runCatchUp`, and assertion `assertConverged()` (local tree == remote tree ==
index; every file's hash consistent).

- [x] Scenarios (each a test): remote-only changes converge; local-only changes
  converge; **echo test** — downloadCycle's FS mutations produce zero upload
  events through the real IgnoreFilter + monitor wiring; both-sides-different
  edit → exactly one conflicted copy, both contents preserved; local edit +
  remote delete → file survives; remote edit + local delete → file restored;
  offline batch (catch-up) converges incl. deletes; move tree locally →
  single remote move (mock records ≤ 2 write calls); large file (12 MiB, mock
  asserts session path with 4 MiB chunks); excluded-name files never uploaded.
- [x] Commit.

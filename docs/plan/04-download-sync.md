# Phase 4 — Download Sync (Remote → Local)

**Goal:** Full initial indexing and steady-state download sync: longpoll,
delta listing, conflict resolution, atomic downloads. After this phase, a linked
account fully mirrors remote → local, including remote edits/deletes while
running.

**Reference:** engine-doc §4 (all subsections), §1.5 (cursors), §7 (transfers),
§8 (exclusions). Selective-sync filtering hooks exist from the start (a
`Set<String>` of excluded paths, empty until Phase 7).
**Definition of done:** scenario tests below green; manual: link a small test
account, watch `~/Dropbox` populate; edit/delete a file on dropbox.com and see
it applied locally within seconds.

### Task 4.1: SyncItemEvent model & remote-change cleaning

**Files:** create `Engine/SyncItemEvent.swift`, `Engine/RemoteChangeCleaner.swift`;
tests `Tests/.../RemoteChangeCleanerTests.swift`.

**Interfaces produced:**

```swift
public struct SyncItemEvent: Sendable, Equatable {    // unified local/remote change (cf. engine-doc §1.4 fields)
    public var direction: SyncDirection
    public var changeType: ChangeType                 // remote events: never .moved (api-notes §3)
    public var itemType: ItemType?                    // nil for remote deletions of unknown items
    public var dbxPath: String                        // cased; destination for moves
    public var dbxPathLower: String
    public var localURL: URL
    public var dbxPathFrom: String?; public var dbxPathFromLower: String?; public var localURLFrom: URL?
    public var rev: String?; public var contentHash: String?; public var symlinkTarget: String?
    public var dbxId: String?; public var size: Int64; public var changeTime: Date?
    public var changedBy: String?                     // account id (downloads)
}
public enum DownloadConflict: Sendable { case remoteNewer, conflict, identical, localNewerOrIdentical }  // §4.4
```

Constructors: `SyncItemEvent(remote: RemoteMetadata, index:, pathStore:)`
(direction .down; changeType added/modified by index presence, removed for
deleted; per engine-doc §1.4 notes) — async because of `correctCase`.

- [x] `RemoteChangeCleaner.clean(_ entries: [RemoteMetadata], index:) -> [RemoteMetadata]`
  per §4.2. TDD: multiple entries per path keep last; type change (index folder,
  last entry file) synthesizes deleted-before-file; single entries untouched;
  order by depth afterwards is caller's job.
- [x] Commit.

### Task 4.2: SyncEngine skeleton + download conflict table

**Files:** create `Engine/SyncEngine.swift`, `Engine/ConflictResolver.swift`,
`Engine/SyncErrors.swift`; tests `Tests/.../ConflictResolverTests.swift`.

**Interfaces produced:**

```swift
public struct SyncItemError: Error, Sendable, Equatable {   // per-path, recoverable (design §5)
    public var dbxPath: String; public var dbxPathLower: String
    public var direction: SyncDirection; public var title: String; public var message: String
}
public enum SyncFatalError: Error, Sendable, Equatable {
    case dropboxFolderMissing, notAuthorized, databaseCorrupted, unexpected(String)
}
public actor SyncEngine {
    public init(service: DropboxService, database: SyncDatabase, pathStore: PathStore,
                hasher: CachedContentHasher, fileOps: LocalFileOperations,
                excludedItems: @Sendable () -> Set<String>,
                events: SyncEngineEvents)             // callbacks: status, progress, activity, completed items
    public func downloadCycle() async throws          // §4: longpoll NOT included — coordinator drives it
    public func fetchRemoteItem(dbxPathLower: String) async throws   // §4 get_remote_item (used by selective sync + error retry)
    // Phase 5 adds: uploadCycle(rawEvents:), catchUpScan()
}
public struct SyncEngineEvents: Sendable {            // all optional closures
    public var statusText: @Sendable (String) -> Void
    public var itemStarted: @Sendable (SyncItemEvent) -> Void
    public var itemProgress: @Sendable (SyncItemEvent, Int64) -> Void
    public var itemCompleted: @Sendable (SyncItemEvent, SyncCompletion) -> Void
    public var rescanRequested: @Sendable (URL) -> Void   // feed back into Phase 5 event queue
}
public enum SyncCompletion: Sendable, Equatable { case done, skipped, conflictedCopy, failed(SyncItemError) }
```

`ConflictResolver.check(event:index:hasher:database:) -> DownloadConflict`
implements the §4.4 table **in its exact order** (rev equality → hash equality →
unresolved upload error → recursive-ctime unsynced check (§4.5) → deletion rule →
conflict).

- [x] TDD one test per table row, plus: folder rev `"folder"` equality; symlink
  target considered in hash equality; excluded names never count as unsynced
  changes in the recursive ctime walk; missing-locally + in-index counts as
  changed. Use temp dirs + seeded DB. Commit.

### Task 4.3: Local file operations & cache dir

**Files:** create `FileSystem/LocalFileOperations.swift`;
tests `Tests/.../LocalFileOperationsTests.swift`.

**Interfaces produced:**

```swift
public struct LocalFileOperations: Sendable {          // all mutations route through IgnoreFilter (Phase 5); until then a no-op ignore hook
    public init(root: URL, ignore: FileEventIgnoring)  // protocol with `func ignoring<T>(_ expected: [ExpectedFSEvent], _ body: () throws -> T) rethrows -> T`
    public var cacheDir: URL                           // "<root>/.auster.cache" (engine-doc §4.6, §8)
    public func newTempFile() throws -> URL
    public func cleanCacheDir()
    public func atomicMoveIntoPlace(from: URL, to: URL, preservePermissions: Bool) throws  // §4.6 step 9
    public func deleteItem(at: URL, requireExactCasing: Bool) throws                        // §4.8 casing guard
    public func moveItem(from: URL, to: URL) throws
    public func makeDirectory(at: URL) throws
    public func createSymlink(at: URL, target: String) throws
    public func setModificationDate(_ date: Date, at: URL) throws
    public func ensureRootPresent() throws             // §9 folder-missing guard (exact casing) → throws SyncFatalError.dropboxFolderMissing
}
public struct ExpectedFSEvent: Sendable, Equatable { public enum Kind { case created, deleted, modified, moved(to: URL) }; public let kind: Kind; public let url: URL; public let isDirectory: Bool; public let recursive: Bool }
```

- [x] TDD: atomic move replaces existing file and preserves its POSIX permissions
  when asked; exact-casing delete refuses `A.txt` when disk has `a.txt`;
  `ensureRootPresent` throws when root missing or casing drifted; cache dir
  auto-created and named `.auster.cache` (also add it to the excluded-names set —
  see Task 4.4). Commit.

### Task 4.4: Exclusions

**Files:** create `Engine/Exclusions.swift`; tests `Tests/.../ExclusionsTests.swift`.

**Interfaces produced:** `public enum Exclusions {
static func isExcludedName(_ pathOrName: String) -> Bool  // engine-doc §8 list + temp patterns + .auster.cache
static func isExcluded(byUser dbxPathLower: String, excluded: Set<String>) -> Bool  // path == or child of any excluded entry
}`

- [x] TDD: every name in the §8 list; `~$doc.docx`, `.~lock`, `~x.tmp` patterns;
  `Icon\r`; user exclusion child/exact matching (`"/a"` excludes `/a/b`, not
  `/ab`). Commit.

### Task 4.5: Applying remote events

**Files:** create `Engine/DownloadApplier.swift` (used by `SyncEngine`);
tests `Tests/.../DownloadApplierTests.swift` (uses `MockDropboxService` + temp dir).

Implements §4.6/§4.7/§4.8 exactly: case-change application first (§4 note in
§4.6 step 1 and the dedicated `_apply_case_change` behavior — rename local +
update index row), conflict check, parent-ensure (§4.3, lock-guarded), symlink
reproduction, temp-file download + re-check + conflicted-copy rename
(name format §4.4: `"<name> (<Owner>'s conflicted copy YYYY-MM-DD)"`), folder/file
type collisions, deletion with exact-casing guard, index + hash-cache updates,
mtime setting (min(clientModified, serverModified, now) — api-notes; engine §4.6
step 6).

- [x] TDD per behavior, minimum set:
  new remote file lands with right content/mtime/index row;
  identical content on disk → skipped, index updated (rev bumped);
  same rev → skipped, index untouched;
  locally-modified file + remote change → local renamed to conflicted copy
  (assert name format + rescanRequested fired), remote applied;
  remote delete vs locally-edited file → skipped (local survives);
  remote delete applies + prunes index subtree;
  remote folder over local file → file deleted, dir created;
  remote file over local dir → dir deleted recursively;
  symlink event creates symlink without download;
  casing-only remote rename → local rename, index cased path updated;
  parent-missing event → parent fetched and created first.
- [x] Commit after each green cluster.

### Task 4.6: Download cycle & cursors

**Files:** modify `Engine/SyncEngine.swift`; tests `Tests/.../DownloadCycleTests.swift`.

Implements §4.1 + engine-doc §3 relevant parts + §4.3 ordering inside
`downloadCycle()`: empty cursor → full `listFolder("", recursive: true)`
pagination with `didFinishIndexing`/`indexingCounter` resume bookkeeping (§1.5);
otherwise `listFolderContinue`. Per page: clean → sort by depth → deletions
(shallow-first) → folders (shallow-first) → files (parallel ≤ 6 via task group) →
persist cursor → next page. `.cursorReset` → clear cursor + full reindex.
Excluded (by name or by user) events dropped; remote deletion of an excluded item
removes it from the excluded set (§8).

- [x] TDD with MockDropboxService: initial index of nested tree (assert local
  tree + index count + cursor saved); interruption mid-pagination (cancel after
  page 1) resumes without re-downloading page-1 files (mock counts downloads);
  steady-state delta applies only changes; ordering (parent folders exist before
  children — seed mock to emit children first); cursor reset path; excluded
  subtree never touches disk.
- [ ] Manual verification with the real account (see phase header). Commit.

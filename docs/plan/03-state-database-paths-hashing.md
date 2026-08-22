# Phase 3 — Sync State: Database, Paths, Hashing

**Goal:** The persistence and path/hash primitives the engine is built on.

**Reference:** [research/maestral-sync-engine.md](../research/maestral-sync-engine.md)
§1 (schema), §9 (case/Unicode rules); dropbox-api-notes §4 (content hash).
**Definition of done:** all primitives TDD'd against temp dirs/DBs.

### Task 3.1: Database

**Files:** create `AusterCore/Sources/AusterCore/Database/SyncDatabase.swift`,
`Database/Records.swift`; tests `Tests/.../SyncDatabaseTests.swift`.

**Interfaces produced:**

```swift
public struct IndexEntry: Sendable, Equatable, Codable {   // engine-doc §1.1
    public var dbxPathLower: String     // PK
    public var dbxPathCased: String
    public var dbxId: String
    public var itemType: ItemType       // .file | .folder
    public var lastSync: Date?
    public var rev: String              // "folder" for folders
    public var contentHash: String?     // "folder" for folders
    public var symlinkTarget: String?
}
public enum ItemType: String, Sendable, Codable { case file, folder }
public struct SyncErrorEntry: Sendable, Equatable, Codable { // §1.3 — path keys, direction, title, message, type
    public var dbxPathLower: String; public var dbxPath: String
    public var direction: SyncDirection; public var title: String; public var message: String
}
public enum SyncDirection: String, Sendable, Codable { case up, down }
public struct HistoryEntry: Sendable, Equatable, Codable {  // §1.4
    public var id: Int64?; public var direction: SyncDirection; public var changeType: ChangeType
    public var itemType: ItemType; public var dbxPath: String; public var size: Int64; public var timestamp: Date
}
public enum ChangeType: String, Sendable, Codable { case added, removed, moved, modified }

public final class SyncDatabase: Sendable {   // GRDB DatabasePool wrapper
    public init(path: String) throws          // creates schema; on corruption: delete file, recreate, set needsReindex
    public private(set) var wasResetOnOpen: Bool
    // index
    public func indexEntry(forPathLower: String) throws -> IndexEntry?
    public func indexEntries(underPathLower: String) throws -> [IndexEntry]  // subtree, inclusive
    public func allIndexEntries() throws -> [IndexEntry]
    public func upsertIndexEntry(_ e: IndexEntry) throws
    public func removeIndexSubtree(pathLower: String) throws
    public func indexCount() throws -> Int
    // hash cache (§1.2): key inode; invalid when mtime differs
    public func cachedHash(inode: UInt64, mtime: Date) throws -> String?
    public func storeHash(inode: UInt64, localPath: String, hash: String?, mtime: Date) throws
    // sync errors
    public func upsertSyncError(_ e: SyncErrorEntry) throws
    public func clearSyncErrors(pathLower: String) throws
    public func clearSyncErrors(direction: SyncDirection) throws
    public func syncErrors() throws -> [SyncErrorEntry]
    // history
    public func appendHistory(_ e: HistoryEntry) throws
    public func recentHistory(limit: Int) throws -> [HistoryEntry]
    public func pruneHistory(olderThan: Date, keepAtMost: Int) throws   // 7 days / 1000
    // state KV (cursors, flags, pending downloads)
    public func stateString(_ key: StateKey) throws -> String?
    public func setState(_ key: StateKey, _ value: String?) throws
    public func pendingDownloads() throws -> [String]                  // persisted queue, §1.5
    public func addPendingDownload(_ pathLower: String) throws
    public func removePendingDownload(_ pathLower: String) throws
}
public enum StateKey: String { case remoteCursor, localCursorTimestamp, didFinishIndexing, indexingCounter, excludedItems /* JSON array */ }
```

- [ ] TDD: round-trips for each table; subtree queries match prefix semantics
  (`"/a"` matches `/a` and `/a/b`, not `/ab`); hash cache invalidation on mtime
  change; corruption recovery (write garbage file → init succeeds,
  `wasResetOnOpen == true`). Commit per table group.

### Task 3.2: PathStore

**Files:** create `FileSystem/PathStore.swift`; tests `Tests/.../PathStoreTests.swift`.

**Interfaces produced:**

```swift
public struct PathStore: Sendable {
    public init(dropboxRoot: URL, database: SyncDatabase, service: DropboxService)
    public static func normalize(_ dbxPath: String) -> String      // lowercase + NFC (engine-doc §9)
    public func toDbxPath(localURL: URL) throws -> String          // throws if outside root
    public func toLocalURL(dbxPathCased: String) -> URL
    public func correctCase(_ dbxPathBasenameCased: String) async throws -> String  // cache → index → parent metadata (§9)
    public static func isCaseSensitiveVolume(at: URL) -> Bool      // probe file trick
    public static func equalButForUnicodeNorm(_ a: String, _ b: String) -> Bool
    public static func conflictedCopyName(for localURL: URL, suffix: String) -> URL // "name (suffix)*.ext", appends (1),(2)… if taken
}
```

- [ ] TDD: normalization (case + NFD→NFC), round-trip local↔dbx, out-of-root
  throws, conflicted-copy naming (extension preserved, dotfiles, collision
  suffixes), case-sensitivity probe in a temp dir, `correctCase` resolution order
  (seed index → no service call; unknown parent → one metadata call, cached
  after). Commit.

### Task 3.3: CachedContentHasher

**Files:** create `FileSystem/CachedContentHasher.swift`;
tests `Tests/.../CachedContentHasherTests.swift`.
(The pure `ContentHasher` already exists from Phase 2 Task 2.3.)

**Interfaces produced:**

```swift
public struct CachedContentHasher: Sendable {                        // hash-cache-aware (engine-doc §1.2)
    public init(database: SyncDatabase)
    /// "folder" for directories, nil if nothing at path; caches by inode+mtime.
    public func localHash(at localURL: URL) throws -> String?
}
```

- [ ] TDD: second call with same mtime does not re-read (test via a file removed
  after first hash → still returns cached); mtime change → recompute; returns
  `"folder"` for dirs, nil for missing. Commit.

### Task 3.4: Config store

**Files:** create `State/AppConfig.swift`; tests `Tests/.../AppConfigTests.swift`.

**Interfaces produced:** `public struct AppConfig` (UserDefaults-backed, suite
injectable for tests): `dropboxFolderURL: URL?`, `excludedItems: Set<String>`
(mirrored to DB StateKey for engine access — DB is the source of truth, config
convenience for UI), `notificationsEnabled: Bool`, `notificationsSnoozedUntil:
Date?`, `updateCheckInterval: enum`, `isPaused: Bool` (persisted pause,
maestral-ux §9).

- [ ] TDD round-trips + defaults. Commit.

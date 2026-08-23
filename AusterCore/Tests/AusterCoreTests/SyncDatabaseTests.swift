import Foundation
import Testing

@testable import AusterCore

/// `SyncDatabase` is the only thing standing between a crash and a full
/// re-index, so every table is exercised through its public API against a real
/// on-disk SQLite file — an in-memory double would not catch the schema, the
/// prefix semantics of subtree queries, or corruption recovery, which is most of
/// what can actually go wrong here.
@Suite("SyncDatabase")
struct SyncDatabaseTests {

    // MARK: - Fixtures

    /// A database in a fresh temp directory, removed when `body` returns.
    ///
    /// The directory (not just the file) is removed because SQLite leaves `-wal`
    /// and `-shm` siblings behind.
    private func withDatabase<T>(_ body: (SyncDatabase, URL) throws -> T) throws -> T {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("auster-db-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let path = directory.appendingPathComponent("sync.db").path
        return try body(try SyncDatabase(path: path), directory)
    }

    private func entry(
        _ pathLower: String,
        cased: String? = nil,
        id: String = "id:1",
        type: ItemType = .file,
        lastSync: Date? = Date(timeIntervalSince1970: 1_000),
        rev: String = "rev1",
        hash: String? = "hash1",
        symlink: String? = nil
    ) -> IndexEntry {
        IndexEntry(
            dbxPathLower: pathLower,
            dbxPathCased: cased ?? pathLower,
            dbxId: id,
            itemType: type,
            lastSync: lastSync,
            rev: rev,
            contentHash: hash,
            symlinkTarget: symlink
        )
    }

    // MARK: - Index

    @Test("An index entry survives a round trip unchanged")
    func indexRoundTrip() throws {
        try withDatabase { db, _ in
            let original = entry("/photos/cat.jpg", cased: "/Photos/Cat.jpg", symlink: "/elsewhere")
            try db.upsertIndexEntry(original)

            try #expect(db.indexEntry(forPathLower: "/photos/cat.jpg") == original)
            try #expect(db.indexCount() == 1)
        }
    }

    @Test("A folder entry round trips with its sentinel rev and hash")
    func folderRoundTrip() throws {
        try withDatabase { db, _ in
            let folder = entry("/photos", cased: "/Photos", type: .folder, rev: "folder", hash: "folder")
            try db.upsertIndexEntry(folder)

            try #expect(db.indexEntry(forPathLower: "/photos") == folder)
        }
    }

    @Test("A missing path reads back as nil rather than an error")
    func indexMiss() throws {
        try withDatabase { db, _ in
            try #expect(db.indexEntry(forPathLower: "/nothing") == nil)
            try #expect(db.indexCount() == 0)
        }
    }

    @Test("Upserting the same path replaces the row instead of duplicating it")
    func indexUpsertReplaces() throws {
        try withDatabase { db, _ in
            try db.upsertIndexEntry(entry("/a.txt", rev: "rev1"))
            try db.upsertIndexEntry(entry("/a.txt", rev: "rev2", hash: "hash2"))

            try #expect(db.indexCount() == 1)
            try #expect(db.indexEntry(forPathLower: "/a.txt")?.rev == "rev2")
        }
    }

    @Test("A nil lastSync round trips as nil, not as the epoch")
    func indexNilLastSync() throws {
        try withDatabase { db, _ in
            try db.upsertIndexEntry(entry("/a.txt", lastSync: nil))

            try #expect(db.indexEntry(forPathLower: "/a.txt")?.lastSync == nil)
        }
    }

    @Test("A subtree query matches the folder and its descendants but not sibling prefixes")
    func indexSubtreePrefixSemantics() throws {
        try withDatabase { db, _ in
            for path in ["/a", "/a/b", "/a/b/c", "/ab", "/ab/c", "/b"] {
                try db.upsertIndexEntry(entry(path))
            }

            let subtree = try db.indexEntries(underPathLower: "/a").map(\.dbxPathLower).sorted()
            #expect(subtree == ["/a", "/a/b", "/a/b/c"])
        }
    }

    @Test("Wildcard characters in a path are matched literally, not as patterns")
    func indexSubtreeEscapesWildcards() throws {
        try withDatabase { db, _ in
            for path in ["/100%", "/100%/inside", "/100x/outside"] {
                try db.upsertIndexEntry(entry(path))
            }

            let subtree = try db.indexEntries(underPathLower: "/100%").map(\.dbxPathLower).sorted()
            #expect(subtree == ["/100%", "/100%/inside"])
        }
    }

    @Test("The root selects every entry")
    func indexSubtreeOfRoot() throws {
        try withDatabase { db, _ in
            for path in ["/a", "/a/b", "/c"] {
                try db.upsertIndexEntry(entry(path))
            }

            try #expect(db.indexEntries(underPathLower: "").count == 3)
            try #expect(db.indexEntries(underPathLower: "/").count == 3)
        }
    }

    @Test("Removing a subtree removes the folder and its descendants only")
    func indexRemoveSubtree() throws {
        try withDatabase { db, _ in
            for path in ["/a", "/a/b", "/a/b/c", "/ab", "/b"] {
                try db.upsertIndexEntry(entry(path))
            }

            try db.removeIndexSubtree(pathLower: "/a")

            try #expect(db.allIndexEntries().map(\.dbxPathLower).sorted() == ["/ab", "/b"])
        }
    }

    // MARK: - Hash cache

    @Test("A cached hash comes back for the same inode and mtime")
    func hashCacheHit() throws {
        try withDatabase { db, _ in
            let mtime = Date(timeIntervalSince1970: 1_700_000_000)
            try db.storeHash(inode: 42, localPath: "/tmp/a.txt", hash: "abc", mtime: mtime)

            try #expect(db.cachedHash(inode: 42, mtime: mtime) == "abc")
        }
    }

    @Test("A changed mtime invalidates the cached hash")
    func hashCacheInvalidatedByMtime() throws {
        try withDatabase { db, _ in
            let mtime = Date(timeIntervalSince1970: 1_700_000_000)
            try db.storeHash(inode: 42, localPath: "/tmp/a.txt", hash: "abc", mtime: mtime)

            try #expect(db.cachedHash(inode: 42, mtime: mtime.addingTimeInterval(1)) == nil)
        }
    }

    @Test("Sub-second mtime differences still invalidate the cached hash")
    func hashCacheInvalidatedBySubSecondMtime() throws {
        try withDatabase { db, _ in
            let mtime = Date(timeIntervalSince1970: 1_700_000_000)
            try db.storeHash(inode: 42, localPath: "/tmp/a.txt", hash: "abc", mtime: mtime)

            try #expect(db.cachedHash(inode: 42, mtime: mtime.addingTimeInterval(0.01)) == nil)
        }
    }

    @Test("An unknown inode has no cached hash")
    func hashCacheMiss() throws {
        try withDatabase { db, _ in
            try #expect(db.cachedHash(inode: 7, mtime: Date()) == nil)
        }
    }

    @Test("Storing a hash for a known inode replaces the previous entry")
    func hashCacheReplaces() throws {
        try withDatabase { db, _ in
            let first = Date(timeIntervalSince1970: 1_700_000_000)
            let second = first.addingTimeInterval(60)
            try db.storeHash(inode: 42, localPath: "/tmp/a.txt", hash: "abc", mtime: first)
            try db.storeHash(inode: 42, localPath: "/tmp/a.txt", hash: "def", mtime: second)

            try #expect(db.cachedHash(inode: 42, mtime: first) == nil)
            try #expect(db.cachedHash(inode: 42, mtime: second) == "def")
        }
    }

    @Test("Storing a nil hash forgets the inode instead of caching nothing")
    func hashCacheNilForgets() throws {
        try withDatabase { db, _ in
            let mtime = Date(timeIntervalSince1970: 1_700_000_000)
            try db.storeHash(inode: 42, localPath: "/tmp/a.txt", hash: "abc", mtime: mtime)
            try db.storeHash(inode: 42, localPath: "/tmp/a.txt", hash: nil, mtime: mtime)

            try #expect(db.cachedHash(inode: 42, mtime: mtime) == nil)
        }
    }

    @Test("Inodes above Int64.max survive the round trip")
    func hashCacheLargeInode() throws {
        try withDatabase { db, _ in
            let mtime = Date(timeIntervalSince1970: 1_700_000_000)
            let inode = UInt64.max - 1
            try db.storeHash(inode: inode, localPath: "/tmp/a.txt", hash: "abc", mtime: mtime)

            try #expect(db.cachedHash(inode: inode, mtime: mtime) == "abc")
        }
    }

    // MARK: - Sync errors

    private func syncError(
        _ pathLower: String,
        direction: SyncDirection = .up,
        title: String = "Could not upload file"
    ) -> SyncErrorEntry {
        SyncErrorEntry(
            dbxPathLower: pathLower,
            dbxPath: pathLower,
            direction: direction,
            title: title,
            message: "Dropbox is full."
        )
    }

    @Test("A sync error survives a round trip unchanged")
    func syncErrorRoundTrip() throws {
        try withDatabase { db, _ in
            let error = SyncErrorEntry(
                dbxPathLower: "/a/b.txt",
                dbxPath: "/A/B.txt",
                direction: .down,
                title: "Could not download file",
                message: "Auster cannot reach Dropbox."
            )
            try db.upsertSyncError(error)

            try #expect(db.syncErrors() == [error])
        }
    }

    @Test("A second error for the same path replaces the first")
    func syncErrorUpsertReplaces() throws {
        try withDatabase { db, _ in
            try db.upsertSyncError(syncError("/a.txt", title: "First"))
            try db.upsertSyncError(syncError("/a.txt", title: "Second"))

            try #expect(db.syncErrors().map(\.title) == ["Second"])
        }
    }

    @Test("Clearing by path clears that path's subtree and nothing else")
    func syncErrorClearByPath() throws {
        try withDatabase { db, _ in
            for path in ["/a", "/a/b.txt", "/ab.txt", "/c.txt"] {
                try db.upsertSyncError(syncError(path))
            }

            try db.clearSyncErrors(pathLower: "/a")

            try #expect(db.syncErrors().map(\.dbxPathLower).sorted() == ["/ab.txt", "/c.txt"])
        }
    }

    @Test("Clearing by direction leaves the other direction's errors alone")
    func syncErrorClearByDirection() throws {
        try withDatabase { db, _ in
            try db.upsertSyncError(syncError("/up.txt", direction: .up))
            try db.upsertSyncError(syncError("/down.txt", direction: .down))

            try db.clearSyncErrors(direction: .down)

            try #expect(db.syncErrors().map(\.dbxPathLower) == ["/up.txt"])
        }
    }

    // MARK: - History

    private func history(
        _ path: String,
        at timestamp: Date,
        direction: SyncDirection = .down,
        change: ChangeType = .added
    ) -> HistoryEntry {
        HistoryEntry(
            direction: direction,
            changeType: change,
            itemType: .file,
            dbxPath: path,
            size: 128,
            timestamp: timestamp
        )
    }

    @Test("A history entry round trips and gains an id")
    func historyRoundTrip() throws {
        try withDatabase { db, _ in
            let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
            try db.appendHistory(history("/A/B.txt", at: timestamp, direction: .up, change: .modified))

            let stored = try db.recentHistory(limit: 10)
            #expect(stored.count == 1)
            #expect(stored.first?.id != nil)
            #expect(stored.first?.dbxPath == "/A/B.txt")
            #expect(stored.first?.direction == .up)
            #expect(stored.first?.changeType == .modified)
            #expect(stored.first?.timestamp == timestamp)
        }
    }

    @Test("Recent history is newest first and honours the limit")
    func historyOrdering() throws {
        try withDatabase { db, _ in
            let base = Date(timeIntervalSince1970: 1_700_000_000)
            for offset in 0..<5 {
                try db.appendHistory(history("/\(offset).txt", at: base.addingTimeInterval(Double(offset))))
            }

            let recent = try db.recentHistory(limit: 3)
            #expect(recent.map(\.dbxPath) == ["/4.txt", "/3.txt", "/2.txt"])
        }
    }

    @Test("The same path can appear repeatedly — history is a log, not an index")
    func historyKeepsDuplicates() throws {
        try withDatabase { db, _ in
            let base = Date(timeIntervalSince1970: 1_700_000_000)
            try db.appendHistory(history("/a.txt", at: base, change: .added))
            try db.appendHistory(history("/a.txt", at: base.addingTimeInterval(1), change: .modified))

            try #expect(db.recentHistory(limit: 10).count == 2)
        }
    }

    @Test("Pruning drops entries older than the cutoff")
    func historyPrunesByAge() throws {
        try withDatabase { db, _ in
            let now = Date(timeIntervalSince1970: 1_700_000_000)
            let cutoff = now.addingTimeInterval(-7 * 24 * 3600)
            try db.appendHistory(history("/old.txt", at: cutoff.addingTimeInterval(-1)))
            try db.appendHistory(history("/new.txt", at: now))

            try db.pruneHistory(olderThan: cutoff, keepAtMost: 1_000)

            try #expect(db.recentHistory(limit: 10).map(\.dbxPath) == ["/new.txt"])
        }
    }

    @Test("Pruning also caps the total, keeping the newest entries")
    func historyPrunesByCount() throws {
        try withDatabase { db, _ in
            let base = Date(timeIntervalSince1970: 1_700_000_000)
            for offset in 0..<10 {
                try db.appendHistory(history("/\(offset).txt", at: base.addingTimeInterval(Double(offset))))
            }

            try db.pruneHistory(olderThan: base.addingTimeInterval(-1), keepAtMost: 3)

            try #expect(db.recentHistory(limit: 10).map(\.dbxPath) == ["/9.txt", "/8.txt", "/7.txt"])
        }
    }

    // MARK: - State

    @Test("A state value round trips")
    func stateRoundTrip() throws {
        try withDatabase { db, _ in
            try db.setState(.remoteCursor, "cursor-1")

            try #expect(db.stateString(.remoteCursor) == "cursor-1")
        }
    }

    @Test("An unset key reads back as nil")
    func stateUnsetKey() throws {
        try withDatabase { db, _ in
            try #expect(db.stateString(.didFinishIndexing) == nil)
        }
    }

    @Test("Setting a key twice replaces the value")
    func stateReplaces() throws {
        try withDatabase { db, _ in
            try db.setState(.indexingCounter, "1")
            try db.setState(.indexingCounter, "2")

            try #expect(db.stateString(.indexingCounter) == "2")
        }
    }

    @Test("Setting nil clears the key rather than storing an empty string")
    func stateNilClears() throws {
        try withDatabase { db, _ in
            try db.setState(.remoteCursor, "cursor-1")
            try db.setState(.remoteCursor, nil)

            try #expect(db.stateString(.remoteCursor) == nil)
        }
    }

    @Test("State keys are independent of one another")
    func stateKeysIndependent() throws {
        try withDatabase { db, _ in
            try db.setState(.remoteCursor, "cursor-1")
            try db.setState(.localCursorTimestamp, "1700000000")

            try #expect(db.stateString(.remoteCursor) == "cursor-1")
            try #expect(db.stateString(.localCursorTimestamp) == "1700000000")
        }
    }

    // MARK: - Pending downloads

    @Test("Pending downloads round trip and de-duplicate")
    func pendingDownloadsRoundTrip() throws {
        try withDatabase { db, _ in
            try db.addPendingDownload("/photos")
            try db.addPendingDownload("/docs")
            try db.addPendingDownload("/photos")

            try #expect(db.pendingDownloads().sorted() == ["/docs", "/photos"])
        }
    }

    @Test("Removing a pending download leaves the rest of the queue")
    func pendingDownloadsRemove() throws {
        try withDatabase { db, _ in
            try db.addPendingDownload("/photos")
            try db.addPendingDownload("/docs")

            try db.removePendingDownload("/photos")

            try #expect(db.pendingDownloads() == ["/docs"])
        }
    }

    @Test("Removing something that is not queued is not an error")
    func pendingDownloadsRemoveMissing() throws {
        try withDatabase { db, _ in
            try db.removePendingDownload("/nothing")

            try #expect(db.pendingDownloads().isEmpty)
        }
    }

    @Test("The queue survives closing and reopening the database")
    func pendingDownloadsPersist() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("auster-db-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("sync.db").path

        try SyncDatabase(path: path).addPendingDownload("/photos")

        let reopened = try SyncDatabase(path: path)
        #expect(reopened.wasResetOnOpen == false)
        try #expect(reopened.pendingDownloads() == ["/photos"])
    }

    // MARK: - Corruption recovery

    @Test("A corrupt file is thrown away and replaced with an empty database")
    func corruptionRecovery() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("auster-db-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("sync.db").path

        // A plausible-looking SQLite header followed by rubbish: enough that
        // opening succeeds and reading does not.
        var garbage = Data("SQLite format 3\u{0}".utf8)
        garbage.append(Data(repeating: 0xAB, count: 4_096))
        try garbage.write(to: URL(fileURLWithPath: path))

        let db = try SyncDatabase(path: path)

        #expect(db.wasResetOnOpen == true)
        try #expect(db.indexCount() == 0)
        // And the fresh database is fully usable.
        try db.upsertIndexEntry(entry("/a.txt"))
        try #expect(db.indexCount() == 1)
    }

    @Test("An existing healthy database is not reset")
    func healthyDatabaseIsNotReset() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("auster-db-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("sync.db").path

        try SyncDatabase(path: path).upsertIndexEntry(entry("/a.txt"))

        let reopened = try SyncDatabase(path: path)
        #expect(reopened.wasResetOnOpen == false)
        try #expect(reopened.indexCount() == 1)
    }
}

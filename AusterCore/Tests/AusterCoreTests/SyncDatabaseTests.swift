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
}

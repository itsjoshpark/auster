import Foundation
import Testing

@testable import AusterCore

/// Hashing is the engine's most expensive local operation, so the cache is what
/// keeps a re-scan proportional to the changes rather than to the whole folder
/// (engine-doc §1.2).
@Suite("CachedContentHasher")
struct CachedContentHasherTests {

    private func withHasher<T>(
        _ body: (CachedContentHasher, SyncDatabase, URL) throws -> T
    ) throws -> T {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("auster-hash-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let database = try SyncDatabase(path: directory.appendingPathComponent("sync.db").path)
        return try body(CachedContentHasher(database: database), database, directory)
    }

    private func write(_ contents: String, to url: URL) throws {
        try Data(contents.utf8).write(to: url)
    }

    @Test("A file hashes to the same value as the pure hasher")
    func hashesFileContents() throws {
        try withHasher { hasher, _, directory in
            let file = directory.appendingPathComponent("a.txt")
            try write("hello", to: file)

            try #expect(hasher.localHash(at: file) == ContentHasher.hash(data: Data("hello".utf8)))
        }
    }

    @Test("An empty file hashes rather than being treated as missing")
    func hashesEmptyFile() throws {
        try withHasher { hasher, _, directory in
            let file = directory.appendingPathComponent("empty.txt")
            try write("", to: file)

            try #expect(hasher.localHash(at: file) == ContentHasher.hash(data: Data()))
        }
    }

    @Test("A directory reports the folder sentinel, not a content hash")
    func folderSentinel() throws {
        try withHasher { hasher, _, directory in
            let folder = directory.appendingPathComponent("sub")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

            try #expect(hasher.localHash(at: folder) == ItemType.folderSentinel)
        }
    }

    @Test("Nothing at the path is nil, not an error")
    func missingPath() throws {
        try withHasher { hasher, _, directory in
            try #expect(hasher.localHash(at: directory.appendingPathComponent("gone.txt")) == nil)
        }
    }

    @Test("A second call answers from the cache without re-reading the file")
    func secondCallUsesCache() throws {
        try withHasher { hasher, _, directory in
            let file = directory.appendingPathComponent("a.txt")
            try write("hello", to: file)
            // Pinned to a whole second so that restoring it below reproduces
            // exactly the same value; the filesystem does not necessarily store
            // the sub-second part it was given.
            let mtime = Date(timeIntervalSince1970: 1_700_000_000)
            try FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: file.path)
            let first = try hasher.localHash(at: file)

            // The bytes change under the same inode, and the mtime is put back.
            // Re-reading the file would now produce a different hash, so getting
            // the old one back is proof that nothing was read.
            let handle = try FileHandle(forWritingTo: file)
            try handle.truncate(atOffset: 0)
            try handle.write(contentsOf: Data("goodbye".utf8))
            try handle.close()
            try FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: file.path)

            try #expect(hasher.localHash(at: file) == first)
            #expect(first == ContentHasher.hash(data: Data("hello".utf8)))
        }
    }

    @Test("Rewriting the file with new contents recomputes the hash")
    func mtimeChangeRecomputes() throws {
        try withHasher { hasher, _, directory in
            let file = directory.appendingPathComponent("a.txt")
            try write("hello", to: file)
            let first = try hasher.localHash(at: file)

            try write("goodbye", to: file)
            // Filesystem timestamps have limited resolution, so the mtime is
            // moved explicitly rather than being raced against.
            try FileManager.default.setAttributes(
                [.modificationDate: Date().addingTimeInterval(10)],
                ofItemAtPath: file.path
            )

            let second = try hasher.localHash(at: file)
            #expect(second == ContentHasher.hash(data: Data("goodbye".utf8)))
            #expect(second != first)
        }
    }

    @Test("Hashing populates the cache under the file's own inode")
    func populatesCache() throws {
        try withHasher { hasher, database, directory in
            let file = directory.appendingPathComponent("a.txt")
            try write("hello", to: file)
            let hash = try hasher.localHash(at: file)

            let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
            let inode = attributes[.systemFileNumber] as? UInt64
            let mtime = attributes[.modificationDate] as? Date
            #expect(inode != nil)
            try #expect(database.cachedHash(inode: #require(inode), mtime: #require(mtime)) == hash)
        }
    }

    @Test("A folder is not written into the hash cache")
    func foldersAreNotCached() throws {
        try withHasher { hasher, database, directory in
            let folder = directory.appendingPathComponent("sub")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            _ = try hasher.localHash(at: folder)

            let attributes = try FileManager.default.attributesOfItem(atPath: folder.path)
            let inode = try #require(attributes[.systemFileNumber] as? UInt64)
            let mtime = try #require(attributes[.modificationDate] as? Date)
            try #expect(database.cachedHash(inode: inode, mtime: mtime) == nil)
        }
    }

    @Test("A symlink is followed to whatever it points at")
    func followsSymlinkToFile() throws {
        try withHasher { hasher, _, directory in
            let target = directory.appendingPathComponent("target.txt")
            try write("hello", to: target)
            let link = directory.appendingPathComponent("link.txt")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

            try #expect(hasher.localHash(at: link) == ContentHasher.hash(data: Data("hello".utf8)))
        }
    }

    @Test("A symlink to nothing is nil rather than an error")
    func brokenSymlink() throws {
        try withHasher { hasher, _, directory in
            let link = directory.appendingPathComponent("link.txt")
            try FileManager.default.createSymbolicLink(
                at: link,
                withDestinationURL: directory.appendingPathComponent("gone.txt")
            )

            try #expect(hasher.localHash(at: link) == nil)
        }
    }
}

import Foundation
import Testing

@testable import AusterCore

/// Every local mutation the engine makes goes through this type, so its job is
/// to make the dangerous cases impossible: an interrupted download must never be
/// visible (D9.3), and a delete must never hit a lookalike (§4.8).
@Suite("LocalFileOperations")
struct LocalFileOperationsTests {

    /// Records what was declared to the ignore filter, so the tests can assert
    /// that mutations announce themselves (§5.2) before Phase 5 has a filter to
    /// announce them to.
    private final class RecordingIgnore: FileEventIgnoring, @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [ExpectedFSEvent] = []

        var declared: [ExpectedFSEvent] { lock.withLock { storage } }

        func ignoring<T>(_ expected: [ExpectedFSEvent], _ body: () throws -> T) rethrows -> T {
            lock.withLock { storage.append(contentsOf: expected) }
            return try body()
        }
    }

    private struct Harness {
        let container: URL
        let root: URL
        let ignore: RecordingIgnore
        let ops: LocalFileOperations
    }

    private func withHarness<T>(_ body: (Harness) throws -> T) throws -> T {
        let container = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("auster-fileops-\(UUID().uuidString)")
        let root = container.appendingPathComponent("Dropbox")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: container) }

        let ignore = RecordingIgnore()
        return try body(
            Harness(
                container: container,
                root: root,
                ignore: ignore,
                ops: LocalFileOperations(root: root, ignore: ignore)
            )
        )
    }

    private func write(_ contents: String, to url: URL) throws {
        try Data(contents.utf8).write(to: url)
    }

    private func read(_ url: URL) throws -> String {
        String(decoding: try Data(contentsOf: url), as: UTF8.self)
    }

    private func permissions(of url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0
    }

    // MARK: - Cache directory

    @Test("The cache directory is named .auster.cache inside the Dropbox folder")
    func cacheDirectoryLocation() throws {
        try withHarness { harness in
            #expect(harness.ops.cacheDir == harness.root.appendingPathComponent(".auster.cache"))
            // Staging inside the folder is what makes the move atomic, so it has
            // to be excluded from sync by name.
            #expect(Exclusions.isExcludedName(harness.ops.cacheDir.lastPathComponent))
        }
    }

    @Test("A temp file gets a unique path in an auto-created cache directory")
    func tempFileCreatesCacheDirectory() throws {
        try withHarness { harness in
            let first = try harness.ops.newTempFile()
            let second = try harness.ops.newTempFile()

            var isDirectory: ObjCBool = false
            #expect(
                FileManager.default.fileExists(atPath: harness.ops.cacheDir.path, isDirectory: &isDirectory)
            )
            #expect(isDirectory.boolValue)
            #expect(first != second)
            #expect(first.deletingLastPathComponent() == harness.ops.cacheDir)
        }
    }

    @Test("Cleaning the cache directory removes everything staged in it")
    func cleanCacheDirectory() throws {
        try withHarness { harness in
            let staged = try harness.ops.newTempFile()
            try write("partial", to: staged)

            harness.ops.cleanCacheDir()

            #expect(!FileManager.default.fileExists(atPath: staged.path))
        }
    }

    // MARK: - Atomic move

    @Test("An atomic move replaces an existing file")
    func atomicMoveReplaces() throws {
        try withHarness { harness in
            let destination = harness.root.appendingPathComponent("report.txt")
            try write("old", to: destination)
            let staged = try harness.ops.newTempFile()
            try write("new", to: staged)

            try harness.ops.atomicMoveIntoPlace(from: staged, to: destination, preservePermissions: false)

            #expect(try read(destination) == "new")
            #expect(!FileManager.default.fileExists(atPath: staged.path))
        }
    }

    @Test("An atomic move lands a file where nothing was")
    func atomicMoveCreates() throws {
        try withHarness { harness in
            let destination = harness.root.appendingPathComponent("new.txt")
            let staged = try harness.ops.newTempFile()
            try write("hello", to: staged)

            try harness.ops.atomicMoveIntoPlace(from: staged, to: destination, preservePermissions: true)

            #expect(try read(destination) == "hello")
        }
    }

    /// A content update should not silently reset a file the user made
    /// executable or read-only.
    @Test("An atomic move can carry over the replaced file's permissions")
    func atomicMovePreservesPermissions() throws {
        try withHarness { harness in
            let destination = harness.root.appendingPathComponent("script.sh")
            try write("old", to: destination)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destination.path)

            let staged = try harness.ops.newTempFile()
            try write("new", to: staged)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: staged.path)

            try harness.ops.atomicMoveIntoPlace(from: staged, to: destination, preservePermissions: true)

            #expect(try read(destination) == "new")
            #expect(try permissions(of: destination) == 0o755)
        }
    }

    @Test("An atomic move that is told not to preserve permissions keeps the staged file's own")
    func atomicMoveWithoutPreservingPermissions() throws {
        try withHarness { harness in
            let destination = harness.root.appendingPathComponent("script.sh")
            try write("old", to: destination)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destination.path)

            let staged = try harness.ops.newTempFile()
            try write("new", to: staged)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: staged.path)

            try harness.ops.atomicMoveIntoPlace(from: staged, to: destination, preservePermissions: false)

            #expect(try permissions(of: destination) == 0o600)
        }
    }

    @Test("An atomic move creates missing parent folders")
    func atomicMoveCreatesParents() throws {
        try withHarness { harness in
            let destination = harness.root
                .appendingPathComponent("a").appendingPathComponent("b").appendingPathComponent("c.txt")
            let staged = try harness.ops.newTempFile()
            try write("deep", to: staged)

            try harness.ops.atomicMoveIntoPlace(from: staged, to: destination, preservePermissions: false)

            #expect(try read(destination) == "deep")
        }
    }

    @Test("An atomic move declares the events it will cause")
    func atomicMoveDeclaresEvents() throws {
        try withHarness { harness in
            let destination = harness.root.appendingPathComponent("report.txt")
            let staged = try harness.ops.newTempFile()
            try write("new", to: staged)

            try harness.ops.atomicMoveIntoPlace(from: staged, to: destination, preservePermissions: false)

            #expect(harness.ignore.declared.contains { $0.url == destination && $0.kind == .created })
            #expect(harness.ignore.declared.contains { $0.url == destination && $0.kind == .modified })
        }
    }

    // MARK: - Deletion

    @Test("Deleting removes a file")
    func deleteFile() throws {
        try withHarness { harness in
            let target = harness.root.appendingPathComponent("gone.txt")
            try write("bye", to: target)

            try harness.ops.deleteItem(at: target, requireExactCasing: true)

            #expect(!FileManager.default.fileExists(atPath: target.path))
        }
    }

    @Test("Deleting removes a folder and everything in it")
    func deleteFolderRecursively() throws {
        try withHarness { harness in
            let folder = harness.root.appendingPathComponent("Photos")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try write("x", to: folder.appendingPathComponent("cat.jpg"))

            try harness.ops.deleteItem(at: folder, requireExactCasing: true)

            #expect(!FileManager.default.fileExists(atPath: folder.path))
        }
    }

    /// The whole point of the guard: on a case-insensitive volume `A.txt`
    /// "exists" when only `a.txt` is on disk, and deleting it would destroy a
    /// file the remote never asked about.
    @Test("An exact-casing delete refuses a differently-cased file")
    func deleteRefusesCaseMismatch() throws {
        try withHarness { harness in
            let onDisk = harness.root.appendingPathComponent("a.txt")
            try write("mine", to: onDisk)

            try harness.ops.deleteItem(
                at: harness.root.appendingPathComponent("A.txt"),
                requireExactCasing: true
            )

            #expect(try read(onDisk) == "mine")
        }
    }

    @Test("Without the casing guard a differently-cased file is deleted")
    func deleteWithoutCasingGuard() throws {
        try withHarness { harness in
            let onDisk = harness.root.appendingPathComponent("a.txt")
            try write("mine", to: onDisk)

            try harness.ops.deleteItem(
                at: harness.root.appendingPathComponent("A.txt"),
                requireExactCasing: false
            )

            #expect(!FileManager.default.fileExists(atPath: onDisk.path))
        }
    }

    @Test("Deleting something that is already gone succeeds")
    func deleteMissingIsSuccess() throws {
        try withHarness { harness in
            try harness.ops.deleteItem(
                at: harness.root.appendingPathComponent("never-existed.txt"),
                requireExactCasing: true
            )
        }
    }

    @Test("Deleting a folder declares a recursive ignore")
    func deleteDeclaresRecursiveIgnore() throws {
        try withHarness { harness in
            let folder = harness.root.appendingPathComponent("Photos")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

            try harness.ops.deleteItem(at: folder, requireExactCasing: true)

            let declared = try #require(harness.ignore.declared.first { $0.url == folder })
            #expect(declared.kind == .deleted)
            #expect(declared.isDirectory)
            #expect(declared.recursive)
        }
    }

    // MARK: - Move, mkdir, symlink, mtime

    @Test("Moving renames an item and creates the destination's parents")
    func moveItem() throws {
        try withHarness { harness in
            let source = harness.root.appendingPathComponent("before.txt")
            try write("same", to: source)
            let destination = harness.root.appendingPathComponent("Archive").appendingPathComponent("after.txt")

            try harness.ops.moveItem(from: source, to: destination)

            #expect(try read(destination) == "same")
            #expect(!FileManager.default.fileExists(atPath: source.path))
            #expect(harness.ignore.declared.contains { $0.kind == .moved(to: destination) })
        }
    }

    @Test("Making a directory is idempotent and creates intermediates")
    func makeDirectory() throws {
        try withHarness { harness in
            let target = harness.root.appendingPathComponent("a").appendingPathComponent("b")

            try harness.ops.makeDirectory(at: target)
            try harness.ops.makeDirectory(at: target)

            var isDirectory: ObjCBool = false
            #expect(FileManager.default.fileExists(atPath: target.path, isDirectory: &isDirectory))
            #expect(isDirectory.boolValue)
        }
    }

    @Test("A symlink is created pointing at its target")
    func createSymlink() throws {
        try withHarness { harness in
            let link = harness.root.appendingPathComponent("link")

            try harness.ops.createSymlink(at: link, target: "/elsewhere/target.txt")

            #expect(
                try FileManager.default.destinationOfSymbolicLink(atPath: link.path)
                    == "/elsewhere/target.txt"
            )
        }
    }

    @Test("Recreating a symlink retargets it")
    func recreateSymlink() throws {
        try withHarness { harness in
            let link = harness.root.appendingPathComponent("link")
            try harness.ops.createSymlink(at: link, target: "/one")

            try harness.ops.createSymlink(at: link, target: "/two")

            #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == "/two")
        }
    }

    @Test("Setting a modification date is readable back")
    func setModificationDate() throws {
        try withHarness { harness in
            let target = harness.root.appendingPathComponent("dated.txt")
            try write("x", to: target)
            let when = Date(timeIntervalSince1970: 1_000_000)

            try harness.ops.setModificationDate(when, at: target)

            let attributes = try FileManager.default.attributesOfItem(atPath: target.path)
            #expect(attributes[.modificationDate] as? Date == when)
        }
    }

    // MARK: - Root guard

    @Test("A present root passes the guard")
    func rootPresent() throws {
        try withHarness { harness in
            try harness.ops.ensureRootPresent()
        }
    }

    @Test("A missing root is a fatal folder-missing error")
    func rootMissing() throws {
        try withHarness { harness in
            try FileManager.default.removeItem(at: harness.root)

            #expect(throws: SyncFatalError.dropboxFolderMissing) {
                try harness.ops.ensureRootPresent()
            }
        }
    }

    /// A renamed folder must read as "missing", not as "the user deleted
    /// everything" — that distinction is what stops a rename becoming a mass
    /// remote delete (§9).
    @Test("A root whose casing drifted is treated as missing")
    func rootCasingDrifted() throws {
        try withHarness { harness in
            try FileManager.default.moveItem(
                at: harness.root,
                to: harness.container.appendingPathComponent("dropbox")
            )

            #expect(throws: SyncFatalError.dropboxFolderMissing) {
                try harness.ops.ensureRootPresent()
            }
        }
    }

    @Test("A file where the root should be is treated as missing")
    func rootIsAFile() throws {
        try withHarness { harness in
            try FileManager.default.removeItem(at: harness.root)
            try write("not a folder", to: harness.root)

            #expect(throws: SyncFatalError.dropboxFolderMissing) {
                try harness.ops.ensureRootPresent()
            }
        }
    }
}

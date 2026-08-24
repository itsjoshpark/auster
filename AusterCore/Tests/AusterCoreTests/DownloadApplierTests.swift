import Foundation
import Testing

@testable import AusterCore

/// Applying one remote change to the disk (engine-doc §4.6–§4.8), from the
/// disk's point of view. The conflict decisions themselves are pinned in
/// `ConflictResolverTests`.
@Suite("DownloadApplier")
struct DownloadApplierTests {

    /// Collects everything the applier reports, so tests can assert on the
    /// rescan requests a conflicted copy has to trigger.
    private final class Reporter: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [URL] = []

        var rescanned: [URL] { lock.withLock { storage } }

        var events: SyncEngineEvents {
            SyncEngineEvents(rescanRequested: { [self] url in lock.withLock { storage.append(url) } })
        }
    }

    private func modificationDate(of url: URL) throws -> Date {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return try #require(attributes[.modificationDate] as? Date)
    }

    // MARK: - New content

    @Test("A new remote file lands with its content, its mtime, and an index row")
    func newFileIsDownloaded() async throws {
        let fixture = try EngineFixture()
        let uploaded = Date(timeIntervalSince1970: 1_600_000_000)
        let remote = try fixture.service.seedFile(at: "/Report.txt", contents: "hello", clientModified: uploaded)

        let event = try await fixture.downloadEvent("/Report.txt")
        let completion = try await fixture.makeApplier().apply(event)

        #expect(completion == .done)
        #expect(try fixture.localContents("/Report.txt") == "hello")
        #expect(try modificationDate(of: fixture.local("/Report.txt")) == uploaded)

        let entry = try #require(try fixture.indexEntry("/Report.txt"))
        #expect(entry.dbxPathCased == "/Report.txt")
        #expect(entry.rev == remote.rev)
        #expect(entry.itemType == .file)
        #expect(entry.contentHash == ContentHasher.hash(data: Data("hello".utf8)))
        #expect(entry.lastSync != nil)
    }

    /// `client_modified` is whatever the uploading client claimed, and a clock
    /// that is wrong or ahead must not produce a local file dated in the future.
    @Test("A modification date from the future is clamped")
    func futureModificationDateIsClamped() async throws {
        let fixture = try EngineFixture()
        let future = Date().addingTimeInterval(86_400 * 30)
        try fixture.service.seedFile(at: "/Report.txt", contents: "hello", clientModified: future)

        let event = try await fixture.downloadEvent("/Report.txt")
        _ = try await fixture.makeApplier().apply(event)

        let mtime = try modificationDate(of: fixture.local("/Report.txt"))
        #expect(mtime < future)
        #expect(mtime <= Date().addingTimeInterval(1))
    }

    @Test("A new remote folder is created and indexed")
    func newFolderIsCreated() async throws {
        let fixture = try EngineFixture()
        fixture.service.seedFolder(at: "/Photos")

        let event = try await fixture.downloadEvent("/Photos")
        let completion = try await fixture.makeApplier().apply(event)

        #expect(completion == .done)
        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: fixture.local("/Photos").path, isDirectory: &isDirectory))
        #expect(isDirectory.boolValue)

        let entry = try #require(try fixture.indexEntry("/Photos"))
        #expect(entry.itemType == .folder)
        #expect(entry.rev == ItemType.folderSentinel)
    }

    // MARK: - Skips

    @Test("Content already on disk is not downloaded, but the index learns the new rev")
    func identicalContentSkipsTheTransfer() async throws {
        let fixture = try EngineFixture()
        try fixture.writeLocal("/Report.txt", "hello")
        try fixture.seedIndex("/Report.txt", rev: "stale-rev")
        let remote = try fixture.service.seedFile(at: "/Report.txt", contents: "hello")

        let event = try await fixture.downloadEvent("/Report.txt")
        let completion = try await fixture.makeApplier().apply(event)

        #expect(completion == .skipped)
        #expect(!fixture.service.recordedCalls.contains(.download))
        #expect(try fixture.indexEntry("/Report.txt")?.rev == remote.rev)
    }

    @Test("A revision the index already holds is skipped without touching the index")
    func knownRevisionIsSkippedEntirely() async throws {
        let fixture = try EngineFixture()
        let remote = try fixture.service.seedFile(at: "/Report.txt", contents: "hello")
        try fixture.writeLocal("/Report.txt", "edited by the user")
        let before = try fixture.seedIndex("/Report.txt", rev: remote.rev)

        let event = try await fixture.downloadEvent("/Report.txt")
        let completion = try await fixture.makeApplier().apply(event)

        #expect(completion == .skipped)
        #expect(try fixture.indexEntry("/Report.txt") == before)
        #expect(try fixture.localContents("/Report.txt") == "edited by the user")
    }

    // MARK: - Conflicts

    @Test("A locally edited file is preserved as a conflicted copy before the remote lands")
    func localEditBecomesConflictedCopy() async throws {
        let fixture = try EngineFixture()
        try fixture.seedIndex("/report.txt", rev: "stale-rev", lastSync: Date(timeIntervalSince1970: 1_000))
        try fixture.writeLocal("/report.txt", "the user's version")
        try fixture.service.seedFile(at: "/report.txt", contents: "the remote version")

        let reporter = Reporter()
        let event = try await fixture.downloadEvent("/report.txt")
        let completion = try await fixture.makeApplier(events: reporter.events).apply(event)

        #expect(completion == .conflictedCopy)
        #expect(try fixture.localContents("/report.txt") == "the remote version")

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        let expected = "report (Mock User's conflicted copy \(formatter.string(from: Date()))).txt"

        let copy = fixture.dropbox.appendingPathComponent(expected)
        #expect(String(decoding: try Data(contentsOf: copy), as: UTF8.self) == "the user's version")
        // The copy is a brand-new local file the watcher never saw appear, so it
        // has to be fed back in or it would never upload.
        #expect(reporter.rescanned.contains(copy))
    }

    @Test("Without an account name the conflicted copy drops the possessive")
    func conflictedCopyWithoutOwnerName() async throws {
        let fixture = try EngineFixture()
        try fixture.seedIndex("/report.txt", rev: "stale-rev", lastSync: Date(timeIntervalSince1970: 1_000))
        try fixture.writeLocal("/report.txt", "the user's version")
        try fixture.service.seedFile(at: "/report.txt", contents: "the remote version")

        let event = try await fixture.downloadEvent("/report.txt")
        _ = try await fixture.makeApplier(ownerName: nil).apply(event)

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        let expected = "report (conflicted copy \(formatter.string(from: Date()))).txt"

        #expect(FileManager.default.fileExists(atPath: fixture.dropbox.appendingPathComponent(expected).path))
    }

    // MARK: - Deletions

    @Test("A remote deletion removes the local item and prunes its index subtree")
    func deletionApplies() async throws {
        let fixture = try EngineFixture()
        let synced = Date().addingTimeInterval(3_600)
        try fixture.seedIndex("/Photos", type: .folder, lastSync: synced)
        try fixture.seedIndex("/Photos/cat.jpg", lastSync: synced)
        try fixture.writeLocal("/Photos/cat.jpg", "meow")

        fixture.service.seedFolder(at: "/Photos")
        try await fixture.service.delete(path: "/Photos", parentRev: nil)

        let event = try await fixture.downloadEvent("/Photos", includeDeleted: true)
        let completion = try await fixture.makeApplier().apply(event)

        #expect(completion == .done)
        #expect(!fixture.localExists("/Photos"))
        #expect(try fixture.indexEntry("/Photos") == nil)
        #expect(try fixture.indexEntry("/Photos/cat.jpg") == nil)
    }

    /// A remote delete must never win over work the user has not uploaded yet
    /// (decisions D9.1).
    @Test("A remote deletion is skipped when the local file has unsynced edits")
    func deletionLosesToLocalEdits() async throws {
        let fixture = try EngineFixture()
        try fixture.seedIndex("/notes.txt", lastSync: Date(timeIntervalSince1970: 1_000))
        try fixture.writeLocal("/notes.txt", "edited since the last sync")

        try fixture.service.seedFile(at: "/notes.txt", contents: "remote")
        try await fixture.service.delete(path: "/notes.txt", parentRev: nil)

        let event = try await fixture.downloadEvent("/notes.txt", includeDeleted: true)
        let completion = try await fixture.makeApplier().apply(event)

        #expect(completion == .skipped)
        #expect(try fixture.localContents("/notes.txt") == "edited since the last sync")
        #expect(try fixture.indexEntry("/notes.txt") != nil)
    }

    // MARK: - Type collisions

    @Test("A remote folder replaces a local file of the same name")
    func folderOverFile() async throws {
        let fixture = try EngineFixture()
        try fixture.seedIndex("/Thing", type: .file, lastSync: Date().addingTimeInterval(3_600))
        try fixture.writeLocal("/Thing", "used to be a file")
        fixture.service.seedFolder(at: "/Thing")

        let event = try await fixture.downloadEvent("/Thing")
        let completion = try await fixture.makeApplier().apply(event)

        #expect(completion == .done)
        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: fixture.local("/Thing").path, isDirectory: &isDirectory))
        #expect(isDirectory.boolValue)
        #expect(try fixture.indexEntry("/Thing")?.itemType == .folder)
    }

    @Test("A remote file replaces a local folder of the same name, contents and all")
    func fileOverFolder() async throws {
        let fixture = try EngineFixture()
        let synced = Date().addingTimeInterval(3_600)
        try fixture.seedIndex("/Thing", type: .folder, lastSync: synced)
        try fixture.seedIndex("/Thing/inside.txt", lastSync: synced)
        try fixture.writeLocal("/Thing/inside.txt", "buried")
        try fixture.service.seedFile(at: "/Thing", contents: "now a file")

        let event = try await fixture.downloadEvent("/Thing")
        let completion = try await fixture.makeApplier().apply(event)

        #expect(completion == .done)
        #expect(try fixture.localContents("/Thing") == "now a file")
        #expect(!fixture.localExists("/Thing/inside.txt"))
        #expect(try fixture.indexEntry("/Thing")?.itemType == .file)
    }

    // MARK: - Symlinks

    @Test("A remote symlink is reproduced without downloading anything")
    func symlinkIsRecreated() async throws {
        let fixture = try EngineFixture()
        fixture.service.seedSymlink(at: "/link", target: "/elsewhere/target.txt")

        let event = try await fixture.downloadEvent("/link")
        let completion = try await fixture.makeApplier().apply(event)

        #expect(completion == .done)
        #expect(
            try FileManager.default.destinationOfSymbolicLink(atPath: fixture.local("/link").path)
                == "/elsewhere/target.txt"
        )
        #expect(!fixture.service.recordedCalls.contains(.download))
        #expect(try fixture.indexEntry("/link")?.symlinkTarget == "/elsewhere/target.txt")
    }

    // MARK: - Casing

    /// A remote rename that only changes case is a real rename on disk, and the
    /// index has to follow it or every later event would look like a new file.
    @Test("A casing-only remote rename renames the local file and recases the index")
    func casingOnlyRename() async throws {
        let fixture = try EngineFixture()
        let original = try fixture.service.seedFile(at: "/report.txt", contents: "hello")
        try fixture.writeLocal("/report.txt", "hello")
        try fixture.seedIndex("/report.txt", rev: original.rev, hash: ContentHasher.hash(data: Data("hello".utf8)))

        _ = try await fixture.service.move(from: "/report.txt", to: "/Report.TXT", autorename: false)

        let event = try await fixture.downloadEvent("/Report.TXT")
        _ = try await fixture.makeApplier().apply(event)

        #expect(try fixture.indexEntry("/report.txt")?.dbxPathCased == "/Report.TXT")
        let names = try FileManager.default.contentsOfDirectory(atPath: fixture.dropbox.path)
        #expect(names.contains("Report.TXT"))
        #expect(!names.contains("report.txt"))
    }

    @Test("Recasing a folder recases the paths of everything indexed under it")
    func casingRenameOfFolderRecasesDescendants() async throws {
        let fixture = try EngineFixture()
        let synced = Date().addingTimeInterval(3_600)
        try fixture.seedIndex("/photos", type: .folder, lastSync: synced)
        try fixture.seedIndex("/photos/cat.jpg", lastSync: synced)
        try fixture.writeLocal("/photos/cat.jpg", "meow")
        fixture.service.seedFolder(at: "/Photos")

        let event = try await fixture.downloadEvent("/Photos")
        _ = try await fixture.makeApplier().apply(event)

        #expect(try fixture.indexEntry("/photos")?.dbxPathCased == "/Photos")
        #expect(try fixture.indexEntry("/photos/cat.jpg")?.dbxPathCased == "/Photos/cat.jpg")
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.dropbox.path).contains("Photos"))
    }

    // MARK: - Parents

    /// A delta page can mention a file before the folder that holds it, and the
    /// download must not fail because of the order Dropbox happened to choose.
    @Test("A file whose parent is missing has its parent fetched and created first")
    func missingParentIsCreated() async throws {
        let fixture = try EngineFixture()
        try fixture.service.seedFile(at: "/Work/2024/notes.txt", contents: "deep")

        let event = try await fixture.downloadEvent("/Work/2024/notes.txt")
        let completion = try await fixture.makeApplier().apply(event)

        #expect(completion == .done)
        #expect(try fixture.localContents("/Work/2024/notes.txt") == "deep")
        #expect(try fixture.indexEntry("/Work")?.itemType == .folder)
        #expect(try fixture.indexEntry("/Work/2024")?.itemType == .folder)
    }

    @Test("An existing parent is not recreated")
    func existingParentIsLeftAlone() async throws {
        let fixture = try EngineFixture()
        fixture.service.seedFolder(at: "/Work")
        try fixture.service.seedFile(at: "/Work/notes.txt", contents: "shallow")
        try fixture.makeLocalFolder("/Work")
        let parent = try fixture.seedIndex("/Work", type: .folder)

        let event = try await fixture.downloadEvent("/Work/notes.txt")
        _ = try await fixture.makeApplier().apply(event)

        #expect(try fixture.indexEntry("/Work") == parent)
        #expect(try fixture.localContents("/Work/notes.txt") == "shallow")
    }
}

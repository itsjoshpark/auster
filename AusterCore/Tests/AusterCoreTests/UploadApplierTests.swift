import Foundation
import Testing

@testable import AusterCore

/// Sending one local change to Dropbox (engine-doc §5.6).
///
/// The upload direction is where Auster can destroy data it does not own, so
/// most of these tests are about the handlers *declining* to act: a delete that
/// the server would have to guess about, a rename across a boundary we do not
/// sync, a name that would collide once Dropbox normalises it. The write mode
/// and the revision guard carry the rest of the safety story (decisions D9.1,
/// D9.5), so both are asserted on the wire rather than inferred.
@Suite("UploadApplier")
struct UploadApplierTests {

    /// Captures the rescan requests the pre-checks fire.
    private final class Reporter: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [URL] = []

        var rescanned: [URL] { lock.withLock { storage } }
        var events: SyncEngineEvents {
            SyncEngineEvents(rescanRequested: { [self] url in lock.withLock { storage.append(url) } })
        }
    }

    private func created(_ fixture: EngineFixture, _ path: String, isDirectory: Bool = false) -> RawFSEvent {
        RawFSEvent(kind: .created, url: fixture.local(path), isDirectory: isDirectory)
    }

    private func modified(_ fixture: EngineFixture, _ path: String) -> RawFSEvent {
        RawFSEvent(kind: .modified, url: fixture.local(path), isDirectory: false)
    }

    private func deleted(_ fixture: EngineFixture, _ path: String, isDirectory: Bool = false) -> RawFSEvent {
        RawFSEvent(kind: .deleted, url: fixture.local(path), isDirectory: isDirectory)
    }

    private func moved(
        _ fixture: EngineFixture,
        _ from: String,
        to destination: String,
        isDirectory: Bool = false
    ) -> RawFSEvent {
        RawFSEvent(
            kind: .moved(to: fixture.local(destination)),
            url: fixture.local(from),
            isDirectory: isDirectory
        )
    }

    private func names(in directory: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: directory.path)
    }

    // MARK: - New files

    @Test("A new file is uploaded in add mode with the file's own modification date")
    func newFileUsesAddMode() async throws {
        let fixture = try EngineFixture()
        let url = try fixture.writeLocal("/report.txt", "hello")
        let mtime = Date(timeIntervalSince1970: 1_600_000_000)
        try FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: url.path)

        let event = try fixture.uploadEvent(created(fixture, "/report.txt"))
        let completion = try await fixture.makeUploadApplier().apply(event)

        #expect(completion == .done)
        #expect(try String(decoding: fixture.service.contents(at: "/report.txt"), as: UTF8.self) == "hello")

        let upload = try #require(fixture.service.recordedUploads.first)
        #expect(upload.mode == .add)
        #expect(upload.clientModified == mtime)

        let entry = try #require(try fixture.indexEntry("/report.txt"))
        #expect(entry.itemType == .file)
        #expect(entry.contentHash == ContentHasher.hash(data: Data("hello".utf8)))
    }

    /// `.update(rev)` is what makes a lost update impossible: if the server has
    /// moved on, it parks our version beside theirs instead of replacing it.
    @Test("A modified file is uploaded against the revision we last saw")
    func modifiedFileUsesUpdateMode() async throws {
        let fixture = try EngineFixture()
        let remote = try fixture.service.seedFile(at: "/report.txt", contents: "old")
        try fixture.seedIndex("/report.txt", rev: remote.rev)
        try fixture.writeLocal("/report.txt", "new")

        let event = try fixture.uploadEvent(modified(fixture, "/report.txt"))
        _ = try await fixture.makeUploadApplier().apply(event)

        #expect(fixture.service.recordedUploads.first?.mode == .update(rev: remote.rev))
        #expect(try String(decoding: fixture.service.contents(at: "/report.txt"), as: UTF8.self) == "new")
    }

    /// Two clients syncing the same change, or a local move whose handler
    /// already put the bytes there — either way, re-sending them is waste.
    @Test("A file whose content already matches the remote is not uploaded")
    func identicalContentIsNotUploaded() async throws {
        let fixture = try EngineFixture()
        let remote = try fixture.service.seedFile(at: "/report.txt", contents: "same")
        try fixture.writeLocal("/report.txt", "same")

        let event = try fixture.uploadEvent(created(fixture, "/report.txt"))
        let completion = try await fixture.makeUploadApplier().apply(event)

        #expect(completion == .skipped)
        #expect(fixture.service.recordedUploads.isEmpty)
        // The index still has to learn about it, or every cycle would re-check.
        #expect(try fixture.indexEntry("/report.txt")?.rev == remote.rev)
    }

    /// When the server writes a conflicted copy, the local folder has to end up
    /// looking like the server — so the local file takes the server's name.
    @Test("A losing update is mirrored by renaming the local file to the server's name")
    func serverAutorenameIsMirroredLocally() async throws {
        let fixture = try EngineFixture()
        try fixture.service.seedFile(at: "/report.txt", contents: "someone else's version")
        try fixture.seedIndex("/report.txt", rev: "a-revision-the-server-has-moved-past")
        try fixture.writeLocal("/report.txt", "our version")

        let event = try fixture.uploadEvent(modified(fixture, "/report.txt"))
        let completion = try await fixture.makeUploadApplier().apply(event)

        #expect(completion == .conflictedCopy)
        let assigned = try #require(fixture.service.recordedUploads.first).path
        let remotePath = try #require(fixture.service.allEntries.map(\.pathDisplay).first { $0 != "/report.txt" })
        #expect(remotePath.contains("conflicted copy"))
        #expect(assigned == "/report.txt")

        // The local file now carries the name the server assigned.
        #expect(try names(in: fixture.dropbox).contains(where: { $0.contains("conflicted copy") }))
        #expect(try fixture.indexEntry("/report.txt") == nil)
    }

    // MARK: - Folders

    @Test("A new folder is created remotely and indexed")
    func newFolderIsCreated() async throws {
        let fixture = try EngineFixture()
        try fixture.makeLocalFolder("/Photos")

        let event = try fixture.uploadEvent(created(fixture, "/Photos", isDirectory: true))
        let completion = try await fixture.makeUploadApplier().apply(event)

        #expect(completion == .done)
        #expect(fixture.service.allEntries.contains { $0.pathLower == "/photos" })
        #expect(try fixture.indexEntry("/Photos")?.itemType == .folder)
    }

    /// Both sides having the folder is the desired end state, not a collision.
    @Test("A folder that already exists remotely is not a conflict")
    func existingRemoteFolderIsAdopted() async throws {
        let fixture = try EngineFixture()
        let remote = fixture.service.seedFolder(at: "/Photos")
        try fixture.makeLocalFolder("/Photos")

        let event = try fixture.uploadEvent(created(fixture, "/Photos", isDirectory: true))
        let completion = try await fixture.makeUploadApplier().apply(event)

        #expect(completion == .skipped)
        #expect(try fixture.indexEntry("/Photos")?.dbxId == remote.id)
    }

    // MARK: - Moves

    @Test("A local rename becomes a remote move")
    func localMoveBecomesRemoteMove() async throws {
        let fixture = try EngineFixture()
        let remote = try fixture.service.seedFile(at: "/before.txt", contents: "same")
        try fixture.seedIndex("/before.txt", rev: remote.rev)
        try fixture.writeLocal("/after.txt", "same")

        let event = try fixture.uploadEvent(moved(fixture, "/before.txt", to: "/after.txt"))
        let completion = try await fixture.makeUploadApplier().apply(event)

        #expect(completion == .done)
        #expect(fixture.service.recordedMoves.first?.from == "/before.txt")
        #expect(fixture.service.recordedMoves.first?.to == "/after.txt")
        #expect(try fixture.indexEntry("/before.txt") == nil)
        #expect(try fixture.indexEntry("/after.txt") != nil)
    }

    /// Moving a folder is one call that takes the subtree with it, so the index
    /// for every descendant has to follow without re-uploading anything.
    @Test("Moving a folder relocates its whole indexed subtree")
    func directoryMoveRefreshesSubtreeIndex() async throws {
        let fixture = try EngineFixture()
        fixture.service.seedFolder(at: "/A")
        try fixture.service.seedFile(at: "/A/cat.jpg", contents: "meow")
        try fixture.seedIndex("/A", type: .folder)
        try fixture.seedIndex("/A/cat.jpg")
        try fixture.makeLocalFolder("/B")
        try fixture.writeLocal("/B/cat.jpg", "meow")

        let event = try fixture.uploadEvent(moved(fixture, "/A", to: "/B", isDirectory: true))
        _ = try await fixture.makeUploadApplier().apply(event)

        #expect(try fixture.indexEntry("/A") == nil)
        #expect(try fixture.indexEntry("/A/cat.jpg") == nil)
        #expect(try fixture.indexEntry("/B")?.itemType == .folder)
        #expect(try fixture.indexEntry("/B/cat.jpg") != nil)
        #expect(fixture.service.recordedUploads.isEmpty)
    }

    /// Dropbox's move refuses an occupied destination, so whatever is in the way
    /// is removed first — under a revision guard, so an unseen remote edit is
    /// never the thing destroyed.
    @Test("A move onto an occupied path deletes the occupant under a revision guard first")
    func moveOntoExistingFileReplacesIt() async throws {
        let fixture = try EngineFixture()
        let source = try fixture.service.seedFile(at: "/before.txt", contents: "mine")
        let occupant = try fixture.service.seedFile(at: "/after.txt", contents: "theirs")
        try fixture.seedIndex("/before.txt", rev: source.rev)
        try fixture.seedIndex("/after.txt", rev: occupant.rev)
        try fixture.writeLocal("/after.txt", "mine")

        let event = try fixture.uploadEvent(moved(fixture, "/before.txt", to: "/after.txt"))
        _ = try await fixture.makeUploadApplier().apply(event)

        #expect(fixture.service.recordedDeletes.first?.path == "/after.txt")
        #expect(fixture.service.recordedDeletes.first?.parentRev == occupant.rev)
        #expect(try String(decoding: fixture.service.contents(at: "/after.txt"), as: UTF8.self) == "mine")
    }

    /// Dropbox normalises names to NFC; macOS often reports NFD. Treating that
    /// difference as a rename would have the two sides renaming forever.
    @Test("A rename that only changes Unicode normalization is not sent")
    func normalizationOnlyRenameIsSkipped() async throws {
        let fixture = try EngineFixture()
        let composed = "/caf\u{00E9}.txt"
        let decomposed = "/cafe\u{0301}.txt"
        let remote = try fixture.service.seedFile(at: composed, contents: "same")
        try fixture.seedIndex(composed, rev: remote.rev)
        try fixture.writeLocal(composed, "same")

        let event = try fixture.uploadEvent(moved(fixture, composed, to: decomposed))
        let completion = try await fixture.makeUploadApplier().apply(event)

        #expect(completion == .skipped)
        #expect(fixture.service.recordedMoves.isEmpty)
    }

    @Test("A move whose source is not on the remote falls back to a rescan")
    func moveWithMissingSourceRescans() async throws {
        let fixture = try EngineFixture()
        try fixture.writeLocal("/after.txt", "brand new")

        let reporter = Reporter()
        let event = try fixture.uploadEvent(moved(fixture, "/before.txt", to: "/after.txt"))
        let completion = try await fixture.makeUploadApplier(events: reporter.events).apply(event)

        #expect(completion == .skipped)
        #expect(reporter.rescanned == [fixture.local("/after.txt")])
    }

    // MARK: - Deletions

    @Test("A local deletion is sent with the revision we last synced")
    func deletionCarriesParentRev() async throws {
        let fixture = try EngineFixture()
        let remote = try fixture.service.seedFile(at: "/gone.txt", contents: "bye")
        try fixture.seedIndex("/gone.txt", rev: remote.rev)

        let event = try fixture.uploadEvent(deleted(fixture, "/gone.txt"))
        let completion = try await fixture.makeUploadApplier().apply(event)

        #expect(completion == .done)
        #expect(fixture.service.recordedDeletes.first?.parentRev == remote.rev)
        #expect(try fixture.indexEntry("/gone.txt") == nil)
    }

    /// The guard doing its job: someone else edited the file, so our delete is
    /// based on a version we never saw. The edit downloads on the next cycle.
    @Test("A deletion of a file the remote has since changed is refused and left alone")
    func deletionOfRemotelyChangedFileIsSkipped() async throws {
        let fixture = try EngineFixture()
        try fixture.service.seedFile(at: "/gone.txt", contents: "original")
        try fixture.seedIndex("/gone.txt", rev: "the-revision-we-last-saw")
        try fixture.service.seedFile(at: "/gone.txt", contents: "someone else edited this")

        let event = try fixture.uploadEvent(deleted(fixture, "/gone.txt"))
        let completion = try await fixture.makeUploadApplier().apply(event)

        #expect(completion == .skipped)
        #expect(
            try String(decoding: fixture.service.contents(at: "/gone.txt"), as: UTF8.self)
                == "someone else edited this")
    }

    /// The index says folder, the remote says file: we have never seen the
    /// version that is there now, so it is not ours to delete.
    @Test("A deletion is refused when the remote is a different kind of thing")
    func deletionWithTypeMismatchIsRefusedAndUntracked() async throws {
        let fixture = try EngineFixture()
        try fixture.service.seedFile(at: "/Thing", contents: "actually a file")
        try fixture.seedIndex("/Thing", type: .folder)

        let event = try fixture.uploadEvent(deleted(fixture, "/Thing", isDirectory: true))
        let completion = try await fixture.makeUploadApplier().apply(event)

        #expect(completion == .skipped)
        #expect(fixture.service.recordedDeletes.isEmpty)
        #expect(try fixture.indexEntry("/Thing") == nil)
    }

    @Test("A deletion of something already gone from the remote just clears the index")
    func deletionOfAlreadyGoneItem() async throws {
        let fixture = try EngineFixture()
        try fixture.seedIndex("/gone.txt")

        let event = try fixture.uploadEvent(deleted(fixture, "/gone.txt"))
        let completion = try await fixture.makeUploadApplier().apply(event)

        #expect(completion == .skipped)
        #expect(try fixture.indexEntry("/gone.txt") == nil)
    }

    @Test("A deletion inside deselected space is left alone")
    func deletionOfExcludedPathIsSkipped() async throws {
        let fixture = try EngineFixture()
        try fixture.service.seedFile(at: "/Private/secret.txt", contents: "secret")

        let event = try fixture.uploadEvent(deleted(fixture, "/Private/secret.txt"))
        let completion =
            try await fixture
            .makeUploadApplier(excludedItems: { ["/private"] })
            .apply(event)

        #expect(completion == .skipped)
        #expect(fixture.service.recordedDeletes.isEmpty)
    }

    // MARK: - Pre-checks

    /// Creating a file inside a folder the user deselected: syncing it would
    /// contradict the choice, deleting it would lose data, so it is renamed out
    /// of the way and uploaded under its new name.
    @Test("A file created in deselected space is renamed to a selective sync conflict")
    func selectiveSyncConflictRename() async throws {
        let fixture = try EngineFixture()
        try fixture.writeLocal("/Private/note.txt", "written by hand")

        let reporter = Reporter()
        let event = try fixture.uploadEvent(created(fixture, "/Private/note.txt"))
        let completion =
            try await fixture
            .makeUploadApplier(excludedItems: { ["/private"] }, events: reporter.events)
            .apply(event)

        #expect(completion == .conflictedCopy)
        let renamed = try names(in: fixture.local("/Private"))
        #expect(renamed.contains { $0.contains("selective sync conflict") })
        #expect(reporter.rescanned.count == 1)
        #expect(fixture.service.recordedUploads.isEmpty)
    }

    /// Dropbox paths are case-insensitive, so two local files whose names differ
    /// only in case would become one remote file and silently destroy one of
    /// them.
    ///
    /// The rule is tested as a pure function rather than end to end: producing
    /// the collision needs a case-sensitive volume, and macOS ships
    /// case-insensitive (and normalization-insensitive) by default, so the
    /// situation cannot be staged on most machines — including CI.
    @Test("A name colliding with a sibling only by case is a case conflict")
    func caseCollisionIsDetected() {
        #expect(
            UploadApplier.normalizationCollision(for: "report.txt", siblings: ["Report.txt", "other.txt"])
                == "case conflict"
        )
    }

    @Test("A name colliding with a sibling only by Unicode spelling is a unicode conflict")
    func unicodeCollisionIsDetected() {
        #expect(
            UploadApplier.normalizationCollision(
                for: "cafe\u{0301}.txt",
                siblings: ["caf\u{00E9}.txt"]
            ) == "unicode conflict"
        )
    }

    @Test("A name with no colliding sibling is not a conflict")
    func noCollision() {
        #expect(UploadApplier.normalizationCollision(for: "report.txt", siblings: ["notes.txt"]) == nil)
        // Its own entry in the listing is not a collision with itself.
        #expect(UploadApplier.normalizationCollision(for: "report.txt", siblings: ["report.txt"]) == nil)
    }

    /// The end-to-end rename, where the volume can actually hold both names.
    @Test(
        "A file whose name collides with a sibling once cased is renamed",
        .enabled(if: PathStore.isCaseSensitiveVolume(at: URL(fileURLWithPath: NSTemporaryDirectory())))
    )
    func caseConflictRename() async throws {
        let fixture = try EngineFixture()
        try fixture.writeLocal("/Report.txt", "first")
        try fixture.writeLocal("/report.txt", "second")
        try fixture.seedIndex("/Report.txt")

        let reporter = Reporter()
        let event = try fixture.uploadEvent(created(fixture, "/report.txt"))
        let completion = try await fixture.makeUploadApplier(events: reporter.events).apply(event)

        #expect(completion == .conflictedCopy)
        #expect(try names(in: fixture.dropbox).contains { $0.contains("case conflict") })
        #expect(reporter.rescanned.count == 1)
    }
}

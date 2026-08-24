import Foundation
import Testing

@testable import AusterCore

/// The local → remote half of a cycle, end to end (engine-doc §5.4–§5.5, §6).
/// Dropbox has no transaction, so the sequence of calls is the correctness
/// argument: deletions first, parents before children.
@Suite("UploadCycle")
struct UploadCycleTests {

    private func created(_ fixture: EngineFixture, _ path: String, isDirectory: Bool = false) -> RawFSEvent {
        RawFSEvent(kind: .created, url: fixture.local(path), isDirectory: isDirectory)
    }

    private func deleted(_ fixture: EngineFixture, _ path: String, isDirectory: Bool = false) -> RawFSEvent {
        RawFSEvent(kind: .deleted, url: fixture.local(path), isDirectory: isDirectory)
    }

    // MARK: - Basics

    @Test("A new local file reaches the remote and the index")
    func newFileIsUploaded() async throws {
        let fixture = try EngineFixture()
        try fixture.writeLocal("/report.txt", "hello")

        try await fixture.makeEngine().uploadCycle(rawEvents: [created(fixture, "/report.txt")])

        #expect(try String(decoding: fixture.service.contents(at: "/report.txt"), as: UTF8.self) == "hello")
        #expect(try fixture.indexEntry("/report.txt") != nil)
    }

    @Test("An empty batch does nothing and reaches no network")
    func emptyBatchIsANoOp() async throws {
        let fixture = try EngineFixture()

        try await fixture.makeEngine().uploadCycle(rawEvents: [])

        #expect(fixture.service.recordedCalls.isEmpty)
    }

    @Test("A completed cycle records when it finished")
    func cycleStampsTheLocalCursor() async throws {
        let fixture = try EngineFixture()
        try fixture.writeLocal("/a.txt", "a")

        try await fixture.makeEngine().uploadCycle(rawEvents: [created(fixture, "/a.txt")])

        #expect(try fixture.database.stateString(.localCursorTimestamp) != nil)
    }

    // MARK: - Filtering

    @Test("Names Auster never syncs are never uploaded")
    func excludedNamesAreDropped() async throws {
        let fixture = try EngineFixture()
        try fixture.writeLocal("/.DS_Store", "junk")
        try fixture.writeLocal("/real.txt", "real")

        try await fixture.makeEngine().uploadCycle(
            rawEvents: [created(fixture, "/.DS_Store"), created(fixture, "/real.txt")]
        )

        #expect(fixture.service.recordedUploads.map(\.path) == ["/real.txt"])
    }

    // MARK: - Ordering (§5.5)

    /// A delete and a create in the same batch can concern the same name, so the
    /// delete has to land first or the create would be the thing autorenamed.
    @Test("Deletions are sent before creations")
    func deletionsGoFirst() async throws {
        let fixture = try EngineFixture()
        let remote = try fixture.service.seedFile(at: "/old.txt", contents: "old")
        try fixture.seedIndex("/old.txt", rev: remote.rev)
        try fixture.writeLocal("/new.txt", "new")

        try await fixture.makeEngine().uploadCycle(
            rawEvents: [created(fixture, "/new.txt"), deleted(fixture, "/old.txt")]
        )

        let calls = fixture.service.recordedCalls
        let deleteAt = try #require(calls.firstIndex(of: .delete))
        let uploadAt = try #require(calls.firstIndex(of: .upload))
        #expect(deleteAt < uploadAt)
    }

    @Test("Parent folders are created before the folders inside them")
    func parentsGoBeforeChildren() async throws {
        let fixture = try EngineFixture()
        try fixture.makeLocalFolder("/A/B/C")

        try await fixture.makeEngine().uploadCycle(
            rawEvents: [
                created(fixture, "/A/B/C", isDirectory: true),
                created(fixture, "/A", isDirectory: true),
                created(fixture, "/A/B", isDirectory: true),
            ]
        )

        #expect(fixture.service.recordedFolderCreations == ["/A", "/A/B", "/A/B/C"])
    }

    @Test("A folder is created before the file that goes in it")
    func foldersGoBeforeTheirFiles() async throws {
        let fixture = try EngineFixture()
        try fixture.writeLocal("/Photos/cat.jpg", "meow")

        try await fixture.makeEngine().uploadCycle(
            rawEvents: [
                created(fixture, "/Photos/cat.jpg"),
                created(fixture, "/Photos", isDirectory: true),
            ]
        )

        let calls = fixture.service.recordedCalls
        let folderAt = try #require(calls.firstIndex(of: .createFolder))
        let uploadAt = try #require(calls.firstIndex(of: .upload))
        #expect(folderAt < uploadAt)
    }

    // MARK: - Errors

    /// One file Dropbox refuses must not abandon the rest of the batch. The two
    /// paths sit at different depths so the cycle sends them in sequence, which
    /// is what makes "the first one fails" deterministic.
    @Test("A single failing upload becomes a sync issue and the cycle continues")
    func perPathFailureIsRecorded() async throws {
        let fixture = try EngineFixture()
        try fixture.writeLocal("/a.txt", "a")
        try fixture.writeLocal("/Deep/b.txt", "b")
        fixture.service.failNext(.upload, with: .disallowedName(path: "/a.txt"))

        try await fixture.makeEngine().uploadCycle(
            rawEvents: [created(fixture, "/a.txt"), created(fixture, "/Deep/b.txt")]
        )

        let errors = try fixture.database.syncErrors()
        #expect(errors.count == 1)
        #expect(errors.first?.dbxPath == "/a.txt")
        #expect(errors.first?.direction == .up)
        #expect(fixture.service.allEntries.contains { $0.pathLower == "/deep/b.txt" })
    }

    @Test("A revoked token stops the cycle rather than failing each path")
    func revokedTokenIsFatal() async throws {
        let fixture = try EngineFixture()
        try fixture.writeLocal("/a.txt", "a")
        fixture.service.deauthorize()

        await #expect(throws: SyncFatalError.notAuthorized) {
            try await fixture.makeEngine().uploadCycle(rawEvents: [created(fixture, "/a.txt")])
        }
    }

    @Test("A missing Dropbox folder stops the cycle before anything is sent")
    func missingRootIsFatal() async throws {
        let fixture = try EngineFixture()
        let event = created(fixture, "/a.txt")
        try FileManager.default.removeItem(at: fixture.dropbox)

        await #expect(throws: SyncFatalError.dropboxFolderMissing) {
            try await fixture.makeEngine().uploadCycle(rawEvents: [event])
        }
        #expect(fixture.service.recordedCalls.isEmpty)
    }

    // MARK: - History

    @Test("Uploaded changes are recorded in the history log")
    func historyIsRecorded() async throws {
        let fixture = try EngineFixture()
        try fixture.writeLocal("/a.txt", "a")

        try await fixture.makeEngine().uploadCycle(rawEvents: [created(fixture, "/a.txt")])

        let history = try fixture.database.recentHistory(limit: 10)
        #expect(history.contains { $0.dbxPath == "/a.txt" && $0.direction == .up })
    }

    // MARK: - Catch-up

    /// The offline path: nothing watched these changes happen, so the scan has
    /// to find them and the same pipeline applies them.
    @Test("A catch-up scan uploads what changed while Auster was not running")
    func catchUpConverges() async throws {
        let fixture = try EngineFixture()
        let remote = try fixture.service.seedFile(at: "/gone.txt", contents: "bye")
        try fixture.seedIndex("/gone.txt", rev: remote.rev)
        try fixture.writeLocal("/added.txt", "while you were out")

        try await fixture.makeEngine().catchUpScan()

        #expect(
            try String(decoding: fixture.service.contents(at: "/added.txt"), as: UTF8.self)
                == "while you were out")
        #expect(!fixture.service.allEntries.contains { $0.pathLower == "/gone.txt" })
    }

    @Test("A catch-up scan with a missing Dropbox folder deletes nothing")
    func catchUpWithMissingRootIsFatal() async throws {
        let fixture = try EngineFixture()
        try fixture.service.seedFile(at: "/a.txt", contents: "a")
        try fixture.seedIndex("/a.txt")
        try FileManager.default.removeItem(at: fixture.dropbox)

        await #expect(throws: SyncFatalError.dropboxFolderMissing) {
            try await fixture.makeEngine().catchUpScan()
        }
        #expect(fixture.service.recordedDeletes.isEmpty)
    }
}

import Foundation
import Testing

@testable import AusterCore

/// The remote → local half of the engine, end to end against the in-memory
/// Dropbox (design §6): a cycle composed of the individual rules mirrors a real
/// account, including when interrupted, reset, or partly excluded.
@Suite("DownloadCycle")
struct DownloadCycleTests {

    private func downloadCount(_ fixture: EngineFixture) -> Int {
        fixture.service.recordedCalls.filter { $0 == .download }.count
    }

    // MARK: - Initial index

    @Test("A first cycle mirrors the whole remote and saves a cursor")
    func initialIndex() async throws {
        let fixture = try EngineFixture()
        fixture.service.seedFolder(at: "/Work")
        try fixture.service.seedFile(at: "/Work/notes.txt", contents: "notes")
        try fixture.service.seedFile(at: "/Work/2024/report.txt", contents: "report")
        try fixture.service.seedFile(at: "/top.txt", contents: "top")

        try await fixture.makeEngine().downloadCycle()

        #expect(try fixture.localContents("/Work/notes.txt") == "notes")
        #expect(try fixture.localContents("/Work/2024/report.txt") == "report")
        #expect(try fixture.localContents("/top.txt") == "top")

        // Four files and folders above, plus the auto-created /Work/2024.
        #expect(try fixture.database.indexCount() == 5)
        #expect(try fixture.database.stateString(.remoteCursor)?.isEmpty == false)
        #expect(try fixture.database.stateString(.didFinishIndexing) == "1")
    }

    @Test("An empty remote leaves an empty folder and still records a cursor")
    func emptyRemote() async throws {
        let fixture = try EngineFixture()

        try await fixture.makeEngine().downloadCycle()

        #expect(try fixture.database.indexCount() == 0)
        #expect(try fixture.database.stateString(.remoteCursor)?.isEmpty == false)
    }

    /// Dropbox does not promise parents before children, so the engine's own
    /// depth ordering has to be what guarantees it.
    @Test("Folders are created before the files inside them, whatever order the page arrives in")
    func orderingIsIndependentOfListingOrder() async throws {
        let fixture = try EngineFixture()
        try fixture.service.seedFile(at: "/a/b/c/deep.txt", contents: "deep")
        fixture.service.reversesListingOrder = true

        try await fixture.makeEngine().downloadCycle()

        #expect(try fixture.localContents("/a/b/c/deep.txt") == "deep")
        #expect(try fixture.indexEntry("/a/b")?.itemType == .folder)
    }

    // MARK: - Pagination & resume

    @Test("A paginated index applies every page")
    func paginatedIndex() async throws {
        let fixture = try EngineFixture()
        for index in 1...5 {
            try fixture.service.seedFile(at: "/file\(index).txt", contents: "body \(index)")
        }
        fixture.service.pageSize = 2

        try await fixture.makeEngine().downloadCycle()

        for index in 1...5 {
            #expect(try fixture.localContents("/file\(index).txt") == "body \(index)")
        }
    }

    /// Cursors are persisted per applied page precisely so this works
    /// (decisions D9.4): an interrupted first index resumes instead of paying
    /// for the whole download again.
    @Test("An index interrupted mid-pagination resumes without re-downloading")
    func interruptedIndexResumes() async throws {
        let fixture = try EngineFixture()
        for index in 1...4 {
            try fixture.service.seedFile(at: "/file\(index).txt", contents: "body \(index)")
        }
        fixture.service.pageSize = 2

        let engine = fixture.makeEngine()
        fixture.service.failNext(.listFolderContinue, with: .connection)

        await #expect(throws: DropboxServiceError.connection) {
            try await engine.downloadCycle()
        }
        let afterInterruption = downloadCount(fixture)
        #expect(afterInterruption == 2)
        #expect(try fixture.database.stateString(.didFinishIndexing) == "0")

        try await engine.downloadCycle()

        for index in 1...4 {
            #expect(try fixture.localContents("/file\(index).txt") == "body \(index)")
        }
        // Only the two files of the unfinished page were fetched the second time.
        #expect(downloadCount(fixture) == 4)
        #expect(try fixture.database.stateString(.didFinishIndexing) == "1")
    }

    // MARK: - Steady state

    @Test("A steady-state cycle applies only what changed")
    func deltaAppliesOnlyChanges() async throws {
        let fixture = try EngineFixture()
        try fixture.service.seedFile(at: "/a.txt", contents: "a")
        try fixture.service.seedFile(at: "/b.txt", contents: "b")

        let engine = fixture.makeEngine()
        try await engine.downloadCycle()
        let afterIndex = downloadCount(fixture)

        try fixture.service.seedFile(at: "/c.txt", contents: "c")
        try await engine.downloadCycle()

        #expect(try fixture.localContents("/c.txt") == "c")
        #expect(downloadCount(fixture) == afterIndex + 1)
    }

    @Test("A remote edit is applied to a file already on disk")
    func remoteEditApplies() async throws {
        let fixture = try EngineFixture()
        try fixture.service.seedFile(at: "/a.txt", contents: "first")

        let engine = fixture.makeEngine()
        try await engine.downloadCycle()

        try fixture.service.seedFile(at: "/a.txt", contents: "second")
        try await engine.downloadCycle()

        #expect(try fixture.localContents("/a.txt") == "second")
    }

    @Test("A remote deletion is applied to the local folder")
    func remoteDeletionApplies() async throws {
        let fixture = try EngineFixture()
        try fixture.service.seedFile(at: "/Work/notes.txt", contents: "notes")

        let engine = fixture.makeEngine()
        try await engine.downloadCycle()

        try await fixture.service.delete(path: "/Work", parentRev: nil)
        try await engine.downloadCycle()

        #expect(!fixture.localExists("/Work"))
        #expect(try fixture.indexEntry("/Work/notes.txt") == nil)
    }

    /// A remote move arrives as a tombstone plus a fresh entry (api-notes §3),
    /// and the deletion has to be applied before the creation or the new file
    /// would be removed again.
    @Test("A remote move lands as a delete of the old path and a create of the new")
    func remoteMoveApplies() async throws {
        let fixture = try EngineFixture()
        try fixture.service.seedFile(at: "/before.txt", contents: "same bytes")

        let engine = fixture.makeEngine()
        try await engine.downloadCycle()

        _ = try await fixture.service.move(from: "/before.txt", to: "/after.txt", autorename: false)
        try await engine.downloadCycle()

        #expect(!fixture.localExists("/before.txt"))
        #expect(try fixture.localContents("/after.txt") == "same bytes")
    }

    // MARK: - Cursor reset

    @Test("An invalidated cursor triggers a full re-index rather than a failure")
    func cursorResetReindexes() async throws {
        let fixture = try EngineFixture()
        try fixture.service.seedFile(at: "/a.txt", contents: "a")

        let engine = fixture.makeEngine()
        try await engine.downloadCycle()
        let firstCursor = try fixture.database.stateString(.remoteCursor)

        fixture.service.invalidateCursors()
        try fixture.service.seedFile(at: "/b.txt", contents: "b")

        try await engine.downloadCycle()

        #expect(try fixture.localContents("/a.txt") == "a")
        #expect(try fixture.localContents("/b.txt") == "b")
        let secondCursor = try fixture.database.stateString(.remoteCursor)
        #expect(secondCursor?.isEmpty == false)
        #expect(secondCursor != firstCursor)
    }

    // MARK: - Exclusions

    @Test("Names Auster never syncs never reach the disk")
    func alwaysExcludedNamesAreDropped() async throws {
        let fixture = try EngineFixture()
        try fixture.service.seedFile(at: "/Work/.DS_Store", contents: "junk")
        try fixture.service.seedFile(at: "/Work/real.txt", contents: "real")

        try await fixture.makeEngine().downloadCycle()

        #expect(!fixture.localExists("/Work/.DS_Store"))
        #expect(try fixture.indexEntry("/Work/.DS_Store") == nil)
        #expect(try fixture.localContents("/Work/real.txt") == "real")
    }

    @Test("A selectively excluded subtree never touches the disk")
    func userExcludedSubtreeIsSkipped() async throws {
        let fixture = try EngineFixture()
        try fixture.service.seedFile(at: "/Private/secret.txt", contents: "secret")
        try fixture.service.seedFile(at: "/Public/open.txt", contents: "open")

        try await fixture.makeEngine(excludedItems: { ["/private"] }).downloadCycle()

        #expect(!fixture.localExists("/Private"))
        #expect(try fixture.indexEntry("/Private/secret.txt") == nil)
        #expect(try fixture.localContents("/Public/open.txt") == "open")
    }

    /// Once the folder is gone from Dropbox there is nothing left to exclude,
    /// and keeping the entry would silently exclude a future folder of the same
    /// name (§8).
    @Test("A remote deletion of an excluded item drops it from the exclusion list")
    func deletingAnExcludedItemClearsTheExclusion() async throws {
        let fixture = try EngineFixture()
        try fixture.service.seedFile(at: "/Private/secret.txt", contents: "secret")
        try fixture.database.setState(.excludedItems, #"["/private"]"#)

        let engine = fixture.makeEngine(excludedItems: { ["/private"] })
        try await engine.downloadCycle()

        try await fixture.service.delete(path: "/Private", parentRev: nil)
        try await engine.downloadCycle()

        #expect(try fixture.database.stateString(.excludedItems) == "[]")
    }

    // MARK: - Per-path failures

    /// One unreadable file must not abandon the rest of the page; it becomes a
    /// sync issue and the cycle carries on (design §5).
    @Test("A single failing file is recorded as a sync issue without stopping the cycle")
    func perPathFailureIsRecorded() async throws {
        let fixture = try EngineFixture()
        try fixture.service.seedFile(at: "/a.txt", contents: "a")
        try fixture.service.seedFile(at: "/b.txt", contents: "b")
        fixture.service.failNext(.download, with: .restrictedContent(path: "/a.txt"))

        try await fixture.makeEngine().downloadCycle()

        let errors = try fixture.database.syncErrors()
        #expect(errors.count == 1)
        #expect(errors.first?.direction == .down)
        // The other file still landed.
        #expect(fixture.localExists("/a.txt") || fixture.localExists("/b.txt"))
    }

    @Test("A revoked token stops the cycle instead of becoming a per-path issue")
    func revokedTokenIsFatal() async throws {
        let fixture = try EngineFixture()
        try fixture.service.seedFile(at: "/a.txt", contents: "a")
        fixture.service.deauthorize()

        await #expect(throws: SyncFatalError.notAuthorized) {
            try await fixture.makeEngine().downloadCycle()
        }
    }

    @Test("A missing Dropbox folder stops the cycle before anything is listed")
    func missingRootIsFatal() async throws {
        let fixture = try EngineFixture()
        try FileManager.default.removeItem(at: fixture.dropbox)

        await #expect(throws: SyncFatalError.dropboxFolderMissing) {
            try await fixture.makeEngine().downloadCycle()
        }
        #expect(!fixture.service.recordedCalls.contains(.listFolder))
    }

    // MARK: - History and reporting

    @Test("Applied changes are recorded in the history log")
    func historyIsRecorded() async throws {
        let fixture = try EngineFixture()
        try fixture.service.seedFile(at: "/a.txt", contents: "a")

        try await fixture.makeEngine().downloadCycle()

        let history = try fixture.database.recentHistory(limit: 10)
        #expect(history.contains { $0.dbxPath == "/a.txt" && $0.direction == .down && $0.changeType == .added })
    }

    @Test("The cycle reports the items it completes")
    func completionsAreReported() async throws {
        let fixture = try EngineFixture()
        try fixture.service.seedFile(at: "/a.txt", contents: "a")

        let recorder = CompletionRecorder()
        try await fixture.makeEngine(events: recorder.events).downloadCycle()

        #expect(recorder.completed.contains { $0.0 == "/a.txt" && $0.1 == .done })
    }

    // MARK: - Ad-hoc fetch

    @Test("Fetching one remote item applies it without disturbing the cursor")
    func fetchRemoteItem() async throws {
        let fixture = try EngineFixture()
        try fixture.service.seedFile(at: "/a.txt", contents: "a")

        let engine = fixture.makeEngine()
        try await engine.downloadCycle()
        let cursor = try fixture.database.stateString(.remoteCursor)

        try fixture.service.seedFile(at: "/Later/deep.txt", contents: "deep")
        try await engine.fetchRemoteItem(dbxPathLower: "/later")

        #expect(try fixture.localContents("/Later/deep.txt") == "deep")
        #expect(try fixture.database.stateString(.remoteCursor) == cursor)
    }

    @Test("Fetching a single remote file applies just that file")
    func fetchRemoteFile() async throws {
        let fixture = try EngineFixture()
        try fixture.service.seedFile(at: "/a.txt", contents: "a")

        try await fixture.makeEngine().fetchRemoteItem(dbxPathLower: "/a.txt")

        #expect(try fixture.localContents("/a.txt") == "a")
    }
}

/// Captures `itemCompleted` callbacks from a cycle.
private final class CompletionRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [(String, SyncCompletion)] = []

    var completed: [(String, SyncCompletion)] { lock.withLock { storage } }

    var events: SyncEngineEvents {
        SyncEngineEvents(
            itemCompleted: { [self] event, completion in
                lock.withLock { storage.append((event.dbxPath, completion)) }
            }
        )
    }
}

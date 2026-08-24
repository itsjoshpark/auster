import Foundation
import Testing

@testable import AusterCore

/// The always-on machinery: the startup sequence, the two worker loops, and
/// what happens when any of it goes wrong (engine-doc §2, §3, §9). The
/// coordinator owns no sync logic, so what is tested is lifecycle.
@Suite("SyncCoordinator", .serialized)
struct SyncCoordinatorTests {

    /// Records what the notifier was told, so the funnel of engine-doc §2 can be
    /// asserted from outside.
    private final class RecordingNotifier: SyncNotifying, @unchecked Sendable {
        private let lock = NSLock()
        private var downloads: [[SyncItemEvent]] = []
        private var conflicts: [SyncItemEvent] = []
        private var itemErrors: [SyncItemError] = []
        private var fatals: [SyncFatalError] = []

        var downloadBatches: [[SyncItemEvent]] { lock.withLock { downloads } }
        var conflicted: [SyncItemEvent] { lock.withLock { conflicts } }
        var failedItems: [SyncItemError] { lock.withLock { itemErrors } }
        var fatalErrors: [SyncFatalError] { lock.withLock { fatals } }

        func notifyDownloadBatch(_ completed: [SyncItemEvent]) {
            lock.withLock { downloads.append(completed) }
        }
        func notifyConflict(_ event: SyncItemEvent) { lock.withLock { conflicts.append(event) } }
        func notifyItemError(_ error: SyncItemError) { lock.withLock { itemErrors.append(error) } }
        func notifyFatal(_ error: SyncFatalError) { lock.withLock { fatals.append(error) } }
    }

    /// The whole object graph, assembled the way the app assembles it.
    @MainActor
    private final class Fixture {
        let root: URL
        let dropbox: URL
        let service = MockDropboxService()
        let database: SyncDatabase
        let pathStore: PathStore
        let config: AppConfig
        let state = SyncState()
        let monitor: LocalFileMonitor
        let notifier = RecordingNotifier()
        let coordinator: SyncCoordinator
        private let suiteName: String

        init() throws {
            root = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("auster-coordinator-\(UUID().uuidString)")
            dropbox = root.appendingPathComponent("Dropbox", isDirectory: false)
            try FileManager.default.createDirectory(at: dropbox, withIntermediateDirectories: true)

            database = try SyncDatabase(path: root.appendingPathComponent("sync.db").path)
            pathStore = PathStore(dropboxRoot: dropbox, database: database, service: service)
            suiteName = "auster-coordinator-\(UUID().uuidString)"
            config = AppConfig(defaults: UserDefaults(suiteName: suiteName)!)

            let ignore = IgnoreFilter()
            monitor = LocalFileMonitor(root: dropbox, ignore: ignore)
            let fileOps = LocalFileOperations(root: dropbox, ignore: ignore)
            let collector = SyncEventCollector()

            let engine = SyncEngine(
                service: service,
                database: database,
                pathStore: pathStore,
                hasher: CachedContentHasher(database: database),
                fileOps: fileOps,
                excludedItems: { [] },
                events: SyncCoordinator.engineEvents(
                    state: state,
                    monitor: monitor,
                    database: database,
                    pathStore: pathStore,
                    collector: collector
                )
            )

            coordinator = SyncCoordinator(
                service: service,
                database: database,
                config: config,
                state: state,
                engine: engine,
                monitor: monitor,
                notifier: notifier,
                collector: collector,
                tuning: SyncCoordinator.Tuning(
                    longpollTimeout: 30,
                    settleAfterChanges: .milliseconds(10),
                    uploadDebounce: .milliseconds(50),
                    reconnectBackoff: .milliseconds(20),
                    loopFloor: .milliseconds(10)
                )
            )
        }

        deinit {
            removeTestDefaults(suiteName: suiteName)
            try? FileManager.default.removeItem(at: root)
        }

        nonisolated func local(_ dbxPath: String) -> URL {
            pathStore.toLocalURL(dbxPathCased: dbxPath)
        }

        nonisolated func localExists(_ dbxPath: String) -> Bool {
            FileManager.default.fileExists(atPath: local(dbxPath).path)
        }

        nonisolated func localContents(_ dbxPath: String) throws -> String {
            String(decoding: try Data(contentsOf: local(dbxPath)), as: UTF8.self)
        }
    }

    /// Polls a condition rather than sleeping a fixed time, so a fast machine is
    /// not punished and a slow one is not flaky.
    private func waitUntil(
        _ description: Comment,
        timeout: Duration = .seconds(5),
        _ condition: @Sendable () async -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("timed out waiting for \(description)")
    }

    // MARK: - Startup (§3)

    @Test("Starting runs the startup sequence in order and converges")
    func startupOrder() async throws {
        let fixture = try await Fixture()
        try fixture.service.seedFile(at: "/a.txt", contents: "hello")

        await fixture.coordinator.start()

        try await waitUntil("the first download cycle to land") {
            await MainActor.run { fixture.localExists("/a.txt") }
        }
        #expect(try await MainActor.run { try fixture.localContents("/a.txt") } == "hello")

        // The account is fetched before anything is listed: it is also the
        // authentication probe, and there is no point indexing an account we
        // cannot reach.
        let calls = fixture.service.recordedCalls
        let accountAt = try #require(calls.firstIndex(of: .currentAccount))
        let listAt = try #require(calls.firstIndex(of: .listFolder))
        #expect(accountAt < listAt)

        await MainActor.run {
            #expect(fixture.state.account?.email == "mock@example.com")
            #expect(fixture.state.usageText.contains("%"))
        }
        await fixture.coordinator.stopForQuit()
    }

    /// Remote changes land before the local scan runs, so the scan sees an index
    /// that already accounts for them (§3).
    @Test("The download cycle runs before the catch-up scan")
    func downloadBeforeCatchUp() async throws {
        let fixture = try await Fixture()
        try fixture.service.seedFile(at: "/remote.txt", contents: "remote")
        try Data("local".utf8).write(to: fixture.local("/local.txt"))

        await fixture.coordinator.start()

        try await waitUntil("both directions to settle") {
            fixture.service.allEntries.contains { $0.pathLower == "/local.txt" }
        }
        #expect(await MainActor.run { fixture.localExists("/remote.txt") })
        await fixture.coordinator.stopForQuit()
    }

    @Test("A path that failed to download last time is retried at startup")
    func downloadErrorsAreRetried() async throws {
        let fixture = try await Fixture()
        try fixture.service.seedFile(at: "/stuck.txt", contents: "recovered")
        try fixture.database.upsertSyncError(
            SyncErrorEntry(
                dbxPathLower: "/stuck.txt",
                dbxPath: "/stuck.txt",
                direction: .down,
                title: "Could not download file",
                message: "Auster cannot reach Dropbox."
            )
        )

        await fixture.coordinator.start()

        try await waitUntil("the retry to land") {
            await MainActor.run { fixture.localExists("/stuck.txt") }
        }
        await fixture.coordinator.stopForQuit()
    }

    @Test("The pending-downloads queue is drained at startup")
    func pendingDownloadsAreDrained() async throws {
        let fixture = try await Fixture()
        try fixture.service.seedFile(at: "/Later/deep.txt", contents: "deep")
        try fixture.database.addPendingDownload("/later")

        await fixture.coordinator.start()

        try await waitUntil("the queued folder to arrive") {
            await MainActor.run { fixture.localExists("/Later/deep.txt") }
        }
        #expect(try fixture.database.pendingDownloads().isEmpty)
        await fixture.coordinator.stopForQuit()
    }

    // MARK: - Steady state (§2)

    @Test("A remote change after startup is picked up by the longpoll loop")
    func longpollTriggersDownload() async throws {
        let fixture = try await Fixture()
        await fixture.coordinator.start()
        try await waitUntil("startup to finish") { await fixture.coordinator.isRunning }

        try fixture.service.seedFile(at: "/late.txt", contents: "late")

        try await waitUntil("the steady-state download") {
            await MainActor.run { fixture.localExists("/late.txt") }
        }
        await fixture.coordinator.stopForQuit()
    }

    @Test("A local change after startup is picked up by the upload loop")
    func watcherTriggersUpload() async throws {
        let fixture = try await Fixture()
        await fixture.coordinator.start()
        try await waitUntil("startup to finish") { await fixture.coordinator.isRunning }
        // The watcher needs a moment before it can see anything.
        try await Task.sleep(for: .milliseconds(400))

        try Data("typed by hand".utf8).write(to: fixture.local("/typed.txt"))

        try await waitUntil("the upload") {
            fixture.service.allEntries.contains { $0.pathLower == "/typed.txt" }
        }
        await fixture.coordinator.stopForQuit()
    }

    // MARK: - Connectivity (ux §9)

    /// A dropped connection is not a pause: the status says "Connecting…", the
    /// user's own pause flag is untouched, and sync resumes by itself.
    @Test("A connection failure shows as connecting and recovers on its own")
    func connectionErrorRecovers() async throws {
        let fixture = try await Fixture()
        fixture.service.failNext(.listFolder, with: .connection, times: 2)

        await fixture.coordinator.start()

        try await waitUntil("the connecting state") {
            await MainActor.run { fixture.state.status == .connecting }
        }
        #expect(await MainActor.run { fixture.config.isPaused == false })

        try fixture.service.seedFile(at: "/back.txt", contents: "back")
        try await waitUntil("recovery once the service is healthy") {
            await MainActor.run { fixture.localExists("/back.txt") }
        }
        await fixture.coordinator.stopForQuit()
    }

    // MARK: - Pause and resume (ux §9)

    @Test("Pausing stops the loops and is remembered")
    func pausePersists() async throws {
        let fixture = try await Fixture()
        await fixture.coordinator.start()
        try await waitUntil("startup to finish") { await fixture.coordinator.isRunning }

        await fixture.coordinator.pause()

        #expect(await fixture.coordinator.isRunning == false)
        #expect(await MainActor.run { fixture.config.isPaused })
        #expect(await MainActor.run { fixture.state.status == .paused })
    }

    @Test("A paused client does not start its loops")
    func startingWhilePausedStaysPaused() async throws {
        let fixture = try await Fixture()
        await MainActor.run { fixture.config.isPaused = true }
        try fixture.service.seedFile(at: "/a.txt", contents: "a")

        await fixture.coordinator.start()

        #expect(await fixture.coordinator.isRunning == false)
        #expect(await MainActor.run { fixture.localExists("/a.txt") == false })
    }

    @Test("Resuming replays the startup sequence and converges")
    func resumeReplaysStartup() async throws {
        let fixture = try await Fixture()
        await fixture.coordinator.start()
        try await waitUntil("startup to finish") { await fixture.coordinator.isRunning }
        await fixture.coordinator.pause()

        try fixture.service.seedFile(at: "/while-paused.txt", contents: "arrived while paused")
        await fixture.coordinator.resume()

        try await waitUntil("the missed change to arrive") {
            await MainActor.run { fixture.localExists("/while-paused.txt") }
        }
        #expect(await MainActor.run { fixture.config.isPaused == false })
        await fixture.coordinator.stopForQuit()
    }

    // MARK: - Quitting

    @Test("Quitting leaves nothing running")
    func quitIsClean() async throws {
        let fixture = try await Fixture()
        await fixture.coordinator.start()
        try await waitUntil("startup to finish") { await fixture.coordinator.isRunning }

        await fixture.coordinator.stopForQuit()

        #expect(await fixture.coordinator.isRunning == false)
    }

    @Test("Quitting twice is harmless")
    func quitIsIdempotent() async throws {
        let fixture = try await Fixture()
        await fixture.coordinator.start()
        await fixture.coordinator.stopForQuit()
        await fixture.coordinator.stopForQuit()

        #expect(await fixture.coordinator.isRunning == false)
    }

    // MARK: - Rebuild (§9)

    /// Everything the index holds is reconstructible, which is what makes this
    /// safe: differing contents come back as conflicted copies, never as losses.
    @Test("Rebuilding the index clears it and re-derives it from both sides")
    func rebuildIndexReconverges() async throws {
        let fixture = try await Fixture()
        try fixture.service.seedFile(at: "/a.txt", contents: "a")
        await fixture.coordinator.start()
        try await waitUntil("the first index") { (try? fixture.database.indexCount()) == 1 }

        await fixture.coordinator.rebuildIndex()

        try await waitUntil("the rebuilt index") { (try? fixture.database.indexCount()) == 1 }
        #expect(try fixture.database.stateString(.remoteCursor)?.isEmpty == false)
        #expect(await MainActor.run { fixture.localExists("/a.txt") })
        await fixture.coordinator.stopForQuit()
    }

    // MARK: - Fatal errors (§9)

    /// A missing folder must never be read as "the user deleted everything": it
    /// stops sync and surfaces, so the user can relocate or recreate it.
    @Test("A missing Dropbox folder stops sync and is reported")
    func missingFolderIsFatal() async throws {
        let fixture = try await Fixture()
        try FileManager.default.removeItem(at: fixture.dropbox)

        await fixture.coordinator.start()

        #expect(await MainActor.run { fixture.state.status == .fatalError(.dropboxFolderMissing) })
        #expect(fixture.notifier.fatalErrors == [.dropboxFolderMissing])
        #expect(await fixture.coordinator.isRunning == false)
        #expect(fixture.service.recordedCalls.isEmpty)
    }

    @Test("A revoked token stops sync and is reported")
    func revokedTokenIsFatal() async throws {
        let fixture = try await Fixture()
        fixture.service.deauthorize()

        await fixture.coordinator.start()

        #expect(await MainActor.run { fixture.state.status == .fatalError(.notAuthorized) })
        #expect(fixture.notifier.fatalErrors == [.notAuthorized])
        #expect(await fixture.coordinator.isRunning == false)
    }

    // MARK: - Notifications (§10)

    @Test("Downloaded changes are notified as one batch per cycle")
    func downloadsAreNotifiedInBatches() async throws {
        let fixture = try await Fixture()
        try fixture.service.seedFile(at: "/a.txt", contents: "a")
        try fixture.service.seedFile(at: "/b.txt", contents: "b")

        await fixture.coordinator.start()
        try await waitUntil("the cycle to be notified") { !fixture.notifier.downloadBatches.isEmpty }

        let batch = try #require(fixture.notifier.downloadBatches.first)
        #expect(batch.count == 2)
        #expect(batch.allSatisfy { $0.direction == .down })
        await fixture.coordinator.stopForQuit()
    }

    /// Uploads are the user's own changes; telling them about their own edits
    /// would be noise (§10).
    @Test("Uploaded changes are not notified")
    func uploadsAreNotNotified() async throws {
        let fixture = try await Fixture()
        try Data("mine".utf8).write(to: fixture.local("/mine.txt"))

        await fixture.coordinator.start()
        try await waitUntil("the upload") {
            fixture.service.allEntries.contains { $0.pathLower == "/mine.txt" }
        }

        #expect(fixture.notifier.downloadBatches.allSatisfy { $0.isEmpty })
        await fixture.coordinator.stopForQuit()
    }

    @Test("A per-path failure is reported and listed without stopping sync")
    func itemErrorsAreReported() async throws {
        let fixture = try await Fixture()
        try fixture.service.seedFile(at: "/bad.txt", contents: "bad")
        fixture.service.failNext(.download, with: .restrictedContent(path: "/bad.txt"))

        await fixture.coordinator.start()
        try await waitUntil("the issue to surface") { !fixture.notifier.failedItems.isEmpty }

        #expect(await MainActor.run { fixture.state.syncErrors.count == 1 })
        #expect(await fixture.coordinator.isRunning)
        await fixture.coordinator.stopForQuit()
    }
}

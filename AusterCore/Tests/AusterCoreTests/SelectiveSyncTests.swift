import Foundation
import Testing

@testable import AusterCore

/// Selective sync: the set algebra of what is excluded, and what changing the
/// selection does to the disk, the index and the download queue (engine-doc §8).
@Suite("Selective sync")
struct SelectiveSyncTests {

    // MARK: - Set algebra

    @Test("a requested selection is normalized and reduced to its minimal entries")
    func normalizationIsMinimal() {
        let normalized = SelectiveSync.normalized(["/Photos", "/photos/2024", "/Docs/", "/Docs/Tax"])

        #expect(normalized == ["/photos", "/docs"])
    }

    /// Excluding the root would mean excluding the account, which the tree UI
    /// must never be able to ask for (ux §5).
    @Test("the root can never be excluded")
    func rootIsNeverExcluded() {
        #expect(SelectiveSync.normalized(["/", "", "/a"]) == ["/a"])
    }

    @Test("the delta reports only what actually changed coverage")
    func deltaReportsCoverageChanges() {
        let delta = SelectiveSync.delta(current: ["/a"], requested: ["/a/b", "/c"])

        #expect(delta.excluded == ["/a/b", "/c"])
        // "/a/b" was already covered by "/a", so nothing new is excluded there.
        #expect(delta.newlyExcluded == ["/c"])
        // "/a" stops being excluded as a whole, so it has to be fetched again.
        #expect(delta.newlyIncluded == ["/a"])
    }

    @Test("widening an exclusion to the parent excludes the parent and includes nothing")
    func nestedExcludeThenInclude() {
        let widen = SelectiveSync.delta(current: ["/a/b"], requested: ["/a"])
        #expect(widen.excluded == ["/a"])
        #expect(widen.newlyExcluded == ["/a"])
        #expect(widen.newlyIncluded.isEmpty)

        let unchanged = SelectiveSync.delta(current: ["/a"], requested: ["/a", "/a/b"])
        #expect(unchanged.excluded == ["/a"])
        #expect(unchanged.newlyExcluded.isEmpty)
        #expect(unchanged.newlyIncluded.isEmpty)
    }

    // MARK: - Applying a selection

    @Test("excluding a folder deletes it locally, prunes the index and persists the set")
    func excludingRemovesLocalCopyAndIndex() async throws {
        let fixture = try await SelectiveSyncFixture()
        try fixture.service.seedFile(at: "/Photos/one.txt", contents: "one")
        try fixture.service.seedFile(at: "/Docs/two.txt", contents: "two")
        await fixture.startOnce()

        #expect(fixture.localExists("/Photos/one.txt"))

        await fixture.coordinator.setExcluded(items: ["/Photos"])

        #expect(!fixture.localExists("/Photos"))
        #expect(fixture.localExists("/Docs/two.txt"))
        #expect(try fixture.database.indexEntry(forPathLower: "/photos/one.txt") == nil)
        #expect(try fixture.database.excludedItems() == ["/photos"])
        #expect(await MainActor.run { fixture.config.excludedItems } == ["/photos"])
    }

    @Test("re-including a folder queues it and downloads it again")
    func includingQueuesAndDownloads() async throws {
        let fixture = try await SelectiveSyncFixture()
        try fixture.service.seedFile(at: "/Photos/one.txt", contents: "one")
        await fixture.startOnce()
        await fixture.coordinator.setExcluded(items: ["/Photos"])
        #expect(!fixture.localExists("/Photos"))

        await fixture.coordinator.setExcluded(items: [])

        #expect(try fixture.database.excludedItems().isEmpty)
        #expect(try fixture.database.pendingDownloads().isEmpty)
        #expect(try fixture.localContents("/Photos/one.txt") == "one")
    }

    /// The scenario the whole feature exists for: an excluded folder must be
    /// inert while excluded, and complete again once it is not.
    @Test("remote edits under an excluded folder are ignored until it is included again")
    func excludedSubtreeConvergesAfterInclusion() async throws {
        let fixture = try await SelectiveSyncFixture()
        try fixture.service.seedFile(at: "/Photos/one.txt", contents: "one")
        await fixture.startOnce()
        await fixture.coordinator.setExcluded(items: ["/Photos"])

        try fixture.service.seedFile(at: "/Photos/two.txt", contents: "two")
        try fixture.service.seedFile(at: "/Photos/one.txt", contents: "edited")
        try await fixture.engine.downloadCycle()

        #expect(!fixture.localExists("/Photos"))

        await fixture.coordinator.setExcluded(items: [])

        #expect(try fixture.localContents("/Photos/one.txt") == "edited")
        #expect(try fixture.localContents("/Photos/two.txt") == "two")
    }

    /// The queue is persistent precisely so an interruption between "the user
    /// asked" and "the bytes arrived" does not leave an empty folder that
    /// nothing retries.
    @Test("an interrupted inclusion resumes from the persisted queue on restart")
    func interruptedInclusionResumesOnRestart() async throws {
        let fixture = try await SelectiveSyncFixture()
        try fixture.service.seedFile(at: "/Photos/one.txt", contents: "one")
        await fixture.startOnce()
        await fixture.coordinator.setExcluded(items: ["/Photos"])

        fixture.service.failNext(.metadata, with: .connection, times: 1)
        await fixture.coordinator.setExcluded(items: [])

        #expect(try fixture.database.pendingDownloads() == ["/photos"])
        #expect(!fixture.localExists("/Photos/one.txt"))

        await fixture.startOnce()

        #expect(try fixture.database.pendingDownloads().isEmpty)
        #expect(try fixture.localContents("/Photos/one.txt") == "one")
    }
}

/// A coordinator over a real database and a mock remote, driven a cycle at a
/// time.
///
/// Deliberately stops the steady-state loops the moment startup is done: what
/// selective sync has to be pinned down about is *what changing the selection
/// does*, and a longpoll loop racing the assertions would only make that
/// harder to see.
@MainActor
final class SelectiveSyncFixture {

    let root: URL
    let dropbox: URL
    let service = MockDropboxService()
    let database: SyncDatabase
    let pathStore: PathStore
    let config: AppConfig
    let state = SyncState()
    let engine: SyncEngine
    let coordinator: SyncCoordinator
    private let suiteName: String

    init() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("auster-selective-\(UUID().uuidString)")
        dropbox = root.appendingPathComponent("Dropbox", isDirectory: false)
        try FileManager.default.createDirectory(at: dropbox, withIntermediateDirectories: true)

        database = try SyncDatabase(path: root.appendingPathComponent("sync.db").path)
        pathStore = PathStore(dropboxRoot: dropbox, database: database, service: service)
        suiteName = "auster-selective-\(UUID().uuidString)"
        config = AppConfig(defaults: UserDefaults(suiteName: suiteName)!)

        let ignore = IgnoreFilter()
        let monitor = LocalFileMonitor(root: dropbox, ignore: ignore)
        let fileOps = LocalFileOperations(root: dropbox, ignore: ignore)
        let collector = SyncEventCollector()

        engine = SyncEngine(
            service: service,
            database: database,
            pathStore: pathStore,
            hasher: CachedContentHasher(database: database),
            fileOps: fileOps,
            excludedItems: { [database] in (try? database.excludedItems()) ?? [] },
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
            notifier: SilentNotifier(),
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
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: root)
    }

    /// Runs the startup sequence, then puts the loops away again.
    func startOnce() async {
        await coordinator.start()
        await coordinator.stopForQuit()
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

/// A notifier that says nothing: these tests are about the filesystem and the
/// index, not about what the user was told.
private struct SilentNotifier: SyncNotifying {
    func notifyDownloadBatch(_ completed: [SyncItemEvent]) {}
    func notifyConflict(_ event: SyncItemEvent) {}
    func notifyItemError(_ error: SyncItemError) {}
    func notifyFatal(_ error: SyncFatalError) {}
}

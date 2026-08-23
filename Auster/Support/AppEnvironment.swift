import AusterCore
import Foundation
import Observation

/// The composition root: builds the engine's object graph once and owns it.
///
/// Assembly order is forced rather than chosen. The engine needs its callbacks
/// at construction; those callbacks need somewhere to put results and something
/// to feed rescans back into; and the coordinator, which owns all of that, needs
/// the engine. `SyncEventCollector` and `SyncCoordinator.engineEvents` exist to
/// break that cycle, and this is the one place the knot is tied.
///
/// Everything here is app-target glue. `AusterCore` holds the logic; this holds
/// the wiring and the lifetime.
@MainActor
@Observable
final class AppEnvironment {

    /// The only thing views read (design §2).
    let state = SyncState()

    let link: LinkController

    /// `nil` until an account and a folder exist — there is nothing to
    /// coordinate before then.
    private(set) var coordinator: SyncCoordinator?

    private var database: SyncDatabase?

    init(link: LinkController) {
        self.link = link
    }

    // MARK: - Lifecycle

    /// Restores the link, then starts sync if there is anything to sync.
    func start() async {
        await link.restore()

        guard link.isLinked else {
            state.setLinked(false)
            return
        }
        state.setLinked(true)

        guard let coordinator = buildCoordinator() else { return }
        self.coordinator = coordinator
        await coordinator.start()
    }

    func pause() async {
        await coordinator?.pause()
    }

    func resume() async {
        await coordinator?.resume()
    }

    func stopForQuit() async {
        await coordinator?.stopForQuit()
    }

    // MARK: - Selective sync

    /// A folder tree seeded with the selection the engine is currently using.
    ///
    /// Seeded from `AppConfig` rather than the database: the mirror exists for
    /// exactly this (implementation note N10), and the UI has no business
    /// opening the engine's tables.
    func makeFolderTreeModel() -> FolderTreeModel? {
        guard let service = link.service else { return nil }
        return FolderTreeModel(service: service, excluded: AppConfig().excludedItems)
    }

    func setExcluded(_ items: Set<String>) async {
        await coordinator?.setExcluded(items: items)
    }

    /// Unlinks and tears the graph down, returning the app to setup.
    func unlink() async {
        await coordinator?.stopForQuit()
        coordinator = nil
        database = nil
        await link.unlink()
        state.setLinked(false)
    }

    // MARK: - Assembly

    private func buildCoordinator() -> SyncCoordinator? {
        let config = AppConfig()

        // Phase 8's onboarding wizard chooses this; until then the default from
        // decisions D3 is assumed so the engine can be exercised.
        let dropbox = config.dropboxFolderURL ?? Self.defaultDropboxFolder
        guard let service = link.service else { return nil }

        do {
            try FileManager.default.createDirectory(at: dropbox, withIntermediateDirectories: true)
            let database = try SyncDatabase(path: Self.databasePath())
            self.database = database

            let pathStore = PathStore(dropboxRoot: dropbox, database: database, service: service)
            let ignore = IgnoreFilter()
            let monitor = LocalFileMonitor(root: dropbox, ignore: ignore)
            let fileOps = LocalFileOperations(root: dropbox, ignore: ignore)
            let collector = SyncEventCollector()

            let engine = SyncEngine(
                service: service,
                database: database,
                pathStore: pathStore,
                hasher: CachedContentHasher(database: database),
                fileOps: fileOps,
                // Read fresh on every use, so Phase 7 can change the selection
                // while a cycle is running.
                excludedItems: { (try? database.excludedItems()) ?? [] },
                events: SyncCoordinator.engineEvents(
                    state: state,
                    monitor: monitor,
                    database: database,
                    pathStore: pathStore,
                    collector: collector
                )
            )

            return SyncCoordinator(
                service: service,
                database: database,
                config: config,
                state: state,
                engine: engine,
                monitor: monitor,
                notifier: PlaceholderNotifier(),
                collector: collector,
                connection: ConnectionMonitor()
            )
        } catch {
            state.setFatalError(.unexpected(error.localizedDescription))
            return nil
        }
    }

    /// `~/Dropbox` (decisions D3).
    static var defaultDropboxFolder: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Dropbox", isDirectory: false)
    }

    /// The sync database, in Application Support rather than beside the user's
    /// files — it is Auster's state, not theirs.
    private static func databasePath() throws -> String {
        let directory = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        .appendingPathComponent("Auster", isDirectory: false)

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("sync.db", isDirectory: false).path
    }
}

/// Stands in until Phase 8 wires up `UserNotifications`.
///
/// Deliberately silent rather than logging: the notification *rules* of
/// engine-doc §10 live in the real implementation, and a half-built version
/// would be something to unlearn.
private struct PlaceholderNotifier: SyncNotifying {
    func notifyDownloadBatch(_ completed: [SyncItemEvent]) {}
    func notifyConflict(_ event: SyncItemEvent) {}
    func notifyItemError(_ error: SyncItemError) {}
    func notifyFatal(_ error: SyncFatalError) {}
}

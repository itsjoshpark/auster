import AppKit
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
/// the wiring, the lifetime, and the handful of AppKit gestures — reveal in
/// Finder, open a URL — that a menu item needs and `AusterCore` may not make.
@MainActor
@Observable
final class AppEnvironment {

    /// The only thing views read about sync (design §2).
    let state = SyncState()

    /// The only thing views read about preferences.
    let settings: AppSettings

    /// The Dropbox link, or `nil` in a build with no app key.
    let auth: AuthManager?

    /// The setup wizard, alive only while it is on screen.
    private(set) var onboarding: OnboardingModel?

    /// Sparkle arrives in Phase 10; until then this reports itself unavailable
    /// and the update controls say so.
    let updater = UpdaterController()

    /// `nil` until an account and a folder exist — there is nothing to
    /// coordinate before then.
    private(set) var coordinator: SyncCoordinator?

    /// Set while a long, user-initiated operation is running, so the menu can
    /// disable the controls that would start a second one.
    private(set) var isBusy = false

    private var database: SyncDatabase?

    init(auth: AuthManager?, settings: AppSettings = AppSettings()) {
        self.auth = auth
        self.settings = settings
    }

    /// Builds the environment the app runs on, from the app key the build
    /// carries.
    static func fromBundle() -> AppEnvironment {
        guard let appKey = AppKey.value else { return AppEnvironment(auth: nil) }
        return AppEnvironment(
            auth: AuthManager(
                store: KeychainDropboxLinkStore(
                    appKey: appKey,
                    presenter: AppKitAuthorizationPresenter()
                )
            )
        )
    }

    var isLinked: Bool { auth?.isLinked ?? false }

    private var service: (any DropboxService)? { auth?.service }

    // MARK: - Lifecycle

    /// Restores the link, then starts sync if there is anything to sync.
    func start() async {
        await auth?.restore()

        // Setup is not finished until there is both an account and somewhere to
        // put its files (ux §3); either one missing sends the user to the wizard.
        guard isLinked, settings.dropboxFolderURL != nil else {
            state.setLinked(false)
            return
        }
        state.setLinked(true)

        guard let coordinator = buildCoordinator() else { return }
        self.coordinator = coordinator
        await coordinator.start()
    }

    /// The wizard, built fresh each time it is shown.
    func beginOnboarding() -> OnboardingModel {
        let model = OnboardingModel(auth: auth) { [weak self] folder, excluded in
            await self?.finishSetup(dropboxFolder: folder, excludedItems: excluded)
        }
        onboarding = model
        return model
    }

    func endOnboarding() {
        onboarding = nil
    }

    /// Consumes an OAuth redirect, telling the wizard about it if one is open.
    func handleRedirect(_ urls: [URL]) async {
        guard let auth else { return }
        for url in urls {
            let outcome = await auth.handleRedirect(url: url)
            if let onboarding {
                onboarding.handle(outcome)
            } else if case .linked = outcome, coordinator == nil {
                // Relinked from Settings rather than from the wizard.
                await start()
            }
        }
    }

    /// Ends onboarding: remembers the choices and brings sync up.
    ///
    /// The selection is written through the coordinator *before* the first sync
    /// so the initial index already filters it — a folder the user deselected in
    /// the wizard should never arrive and then be deleted again.
    func finishSetup(dropboxFolder: URL, excludedItems: Set<String>) async {
        settings.dropboxFolderURL = dropboxFolder
        guard isLinked else { return }
        state.setLinked(true)

        guard let coordinator = buildCoordinator() else { return }
        self.coordinator = coordinator
        await coordinator.setExcluded(items: excludedItems)
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

    /// Throws the index away and derives it again from both sides (ux §2 item 13).
    func rebuildIndex() async {
        isBusy = true
        defer { isBusy = false }
        await coordinator?.rebuildIndex()
    }

    /// Unlinks and tears the graph down, returning the app to setup.
    ///
    /// The user's files are deliberately left alone: unlinking stops syncing
    /// them, it does not disown them (ux §4). Everything Auster derived — the
    /// index, the cursors, the preferences — goes, so a later relink starts from
    /// a clean sheet rather than from state describing a different account.
    func unlink() async {
        await coordinator?.stopForQuit()
        coordinator = nil
        database = nil
        await auth?.unlink()

        if let directory = try? Self.applicationSupportDirectory() {
            try? FileManager.default.removeItem(at: directory)
        }
        settings.dropboxFolderURL = nil
        state.setLinked(false)
        state.setAccount(nil)
    }

    // MARK: - Selective sync

    /// A folder tree seeded with the selection the engine is currently using.
    ///
    /// Seeded from `AppConfig` rather than the database: the mirror exists for
    /// exactly this (implementation note N10), and the UI has no business
    /// opening the engine's tables.
    func makeFolderTreeModel() -> FolderTreeModel? {
        guard let service else { return nil }
        return FolderTreeModel(service: service, excluded: settings.config.excludedItems)
    }

    func setExcluded(_ items: Set<String>) async {
        isBusy = true
        defer { isBusy = false }
        await coordinator?.setExcluded(items: items)
    }

    // MARK: - Gestures

    /// The local Dropbox folder, chosen or defaulted.
    var dropboxFolderURL: URL {
        settings.dropboxFolderURL ?? Self.defaultDropboxFolder
    }

    func openDropboxFolder() {
        let url = dropboxFolderURL
        // Creating it first, because a menu item that silently does nothing is
        // worse than one that puts back a folder the user moved.
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        NSWorkspace.shared.open(url)
    }

    func openDropboxWebsite() {
        NSWorkspace.shared.open(URL(string: "https://www.dropbox.com/home")!)
    }

    /// Selects an item in Finder rather than opening it — the "Show" action of a
    /// notification and of every recent-changes row (ux §7).
    func revealInFinder(dbxPath: String) {
        let relative = dbxPath.split(separator: "/", omittingEmptySubsequences: true)
        let url = relative.reduce(dropboxFolderURL) {
            $0.appendingPathComponent(String($1), isDirectory: false)
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            NSWorkspace.shared.open(url.deletingLastPathComponent())
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// The dropbox.com page for a path, for items that are no longer on disk.
    func openOnDropboxWebsite(dbxPath: String) {
        let escaped =
            dbxPath.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? dbxPath
        guard let url = URL(string: "https://www.dropbox.com/home" + escaped) else { return }
        NSWorkspace.shared.open(url)
    }

    static let deletedFilesURL = URL(string: "https://www.dropbox.com/deleted_files")!

    // MARK: - Assembly

    private func buildCoordinator() -> SyncCoordinator? {
        let config = settings.config
        let dropbox = dropboxFolderURL
        guard let service else { return nil }

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
                // Read fresh on every use, so the selective-sync tree can change
                // the selection while a cycle is running.
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

    /// Auster's own state, in Application Support rather than beside the user's
    /// files — it is Auster's, not theirs.
    private static func applicationSupportDirectory() throws -> URL {
        let directory = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        .appendingPathComponent("Auster", isDirectory: false)

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private static func databasePath() throws -> String {
        try applicationSupportDirectory()
            .appendingPathComponent("sync.db", isDirectory: false).path
    }
}

/// Stands in until Task 8.4 wires up `UserNotifications`.
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

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

    /// Sparkle, or a stand-in that reports itself unavailable where the build
    /// cannot update itself.
    let updater: UpdaterManager

    /// `nil` until an account and a folder exist — there is nothing to
    /// coordinate before then.
    private(set) var coordinator: SyncCoordinator?

    /// Set while a long, user-initiated operation is running, so the menu can
    /// disable the controls that would start a second one.
    private(set) var isBusy = false

    /// `true` once Dropbox has rejected the token: only a browser can fix that,
    /// so the menu carries the invitation rather than a modal (engine-doc §9).
    private(set) var needsRelink = false

    /// Guards against stacking dialogs: a fatal error that persists would
    /// otherwise raise a second alert behind the first.
    private var isRecovering = false

    private var sleepObservers: [any NSObjectProtocol] = []
    private var hasSlept = false

    /// Called when Auster no longer has what it needs to sync and the wizard has
    /// to come back — which today means the user unlinked from Settings.
    ///
    /// A callback rather than a direct call because the wizard is an AppKit
    /// window owned by the app delegate, and the environment has no business
    /// knowing that.
    var onNeedsSetup: (@MainActor () -> Void)?

    private var database: SyncDatabase?

    init(auth: AuthManager?, settings: AppSettings = AppSettings()) {
        self.auth = auth
        self.settings = settings
        updater = UpdaterManager(checkInterval: settings.updateCheckInterval)
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

        await restartSync()
    }

    /// Brings the engine up over the current folder, without re-checking the
    /// link. Used where the account is known good and only the folder changed.
    private func restartSync() async {
        adoptCoordinator()
        await coordinator?.start()
    }

    /// Builds the object graph over the current folder without starting it.
    ///
    /// Separate from `restartSync` because a rebuild does not want the startup
    /// sequence first: it is about to throw away everything that sequence would
    /// have produced.
    private func adoptCoordinator() {
        guard coordinator == nil else { return }
        coordinator = buildCoordinator()
    }

    // MARK: - Recovery (engine-doc §9)

    /// Watches the status for a fatal error, and offers whatever the recovery
    /// model says it should.
    ///
    /// `withObservationTracking` rather than a callback on `SyncState`: the
    /// state object's job is to describe sync, not to know that somebody wants
    /// to put a dialog on screen. The tracking is one-shot, so it re-arms itself
    /// each time it fires.
    func observeFatalErrors() {
        withObservationTracking {
            _ = state.status
        } onChange: { [weak self] in
            // `onChange` runs *before* the new value is in place, so the read
            // has to happen on the next turn of the main actor.
            Task { @MainActor in
                self?.observeFatalErrors()
                await self?.recoverIfNeeded()
            }
        }
    }

    /// Keeps Sparkle's automatic checks in step with the setting.
    ///
    /// The preference is the switch the user sees, so it has to be the one that
    /// decides; Sparkle keeps its own copy in the defaults and would otherwise
    /// go on using whatever it was told at launch. One-shot tracking, re-armed
    /// each time it fires, as with `observeFatalErrors`.
    func observeUpdateCheckInterval() {
        withObservationTracking {
            _ = settings.updateCheckInterval
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.observeUpdateCheckInterval()
                self.updater.apply(checkInterval: self.settings.updateCheckInterval)
            }
        }
    }

    private func recoverIfNeeded() async {
        guard case .fatalError(let error) = state.status, !isRecovering else { return }
        isRecovering = true
        defer { isRecovering = false }

        switch RecoveryModel.presentation(for: error) {
        case .folderMissingDialog:
            let choice = FatalErrorDialogs.askAboutMissingFolder(configuredFolder: dropboxFolderURL)
            await perform(RecoveryModel.plan(for: choice, configuredFolder: dropboxFolderURL))

        case .relinkPrompt:
            // No dialog: the menu says so, and the fix needs a browser.
            needsRelink = true

        case .automaticReindex:
            await perform([.rebuildIndex])

        case .message(let message):
            FatalErrorDialogs.report(message)
        }
    }

    /// Carries out a recovery plan, in the order the model gave it.
    private func perform(_ actions: [RecoveryModel.Action]) async {
        isBusy = true
        defer { isBusy = false }

        for action in actions {
            switch action {
            case .adoptFolder(let url):
                // The watcher and every path in the engine are built around one
                // root, so adopting a different one means a new object graph.
                await coordinator?.stopForQuit()
                coordinator = nil
                database = nil
                settings.dropboxFolderURL = url

            case .createFolder(let url):
                try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)

            case .rebuildIndex:
                state.clearFatalError()
                adoptCoordinator()
                await coordinator?.rebuildIndex()

            case .quit:
                NSApp.terminate(nil)
            }
        }
    }

    /// Sends the user back through the browser after a revoked token.
    func relink() {
        auth?.beginLink()
    }

    // MARK: - Sleep and wake (ux §9)

    /// Re-checks both sides after the machine wakes.
    ///
    /// Neither loop survives a sleep in any useful sense: the longpoll
    /// connection is dead, and FSEvents owes nothing about what other devices
    /// did in the meantime. Rather than wait for the longpoll to time out and
    /// retry — which can be a minute or more, on the one occasion the user is
    /// most likely to be looking — waking runs the same two cycles startup runs.
    ///
    /// `willSleep` is watched only so that a `didWake` without one is ignored.
    func observeSleepAndWake() {
        let center = NSWorkspace.shared.notificationCenter

        sleepObservers.append(
            center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) {
                [weak self] _ in
                MainActor.assumeIsolated { self?.hasSlept = true }
            }
        )
        sleepObservers.append(
            center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) {
                [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.hasSlept else { return }
                    self.hasSlept = false
                    Task { await self.coordinator?.syncNow() }
                }
            }
        )
    }

    /// Moves the Dropbox folder and points the engine at its new home (ux §4).
    ///
    /// Sync stops first and the object graph goes with it: `LocalFileMonitor`
    /// watches a path, and a watcher left running over a folder being moved
    /// would report the move as the user deleting everything.
    ///
    /// - Throws: `FolderMover.MoveError`, with sync put back where it was.
    func moveDropboxFolder(to destination: URL) async throws {
        isBusy = true
        defer { isBusy = false }

        await coordinator?.stopForQuit()
        coordinator = nil
        database = nil

        do {
            try FolderMover.move(from: dropboxFolderURL, to: destination)
        } catch {
            await restartSync()
            throw error
        }

        settings.dropboxFolderURL = destination
        await restartSync()
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
            } else if case .linked = outcome {
                // Relinked from Settings, or after a revoked token.
                needsRelink = false
                state.clearFatalError()
                if coordinator == nil {
                    await start()
                } else {
                    await coordinator?.resume()
                }
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
        onNeedsSetup?()
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

        let notifier = makeNotifier()

        do {
            try FileManager.default.createDirectory(at: dropbox, withIntermediateDirectories: true)
            let database = try SyncDatabase(path: Self.databasePath())
            self.database = database

            if database.wasResetOnOpen {
                // The file on disk was unusable and had to be recreated. Nothing
                // is lost — the index is derivable from both sides — but the
                // re-index that follows is long enough to be worth explaining
                // rather than leaving as unexplained activity (engine-doc §9).
                notifier.rebuildingIndex()
            }

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
                notifier: notifier,
                collector: collector,
                connection: ConnectionMonitor()
            )
        } catch {
            state.setFatalError(.unexpected(error.localizedDescription))
            return nil
        }
    }

    /// The notifier the coordinator talks to, over the composer's rules.
    ///
    /// Every input is read through a closure rather than captured: the account,
    /// the master switch and the snooze all change while sync is running, and a
    /// notifier built once at launch would go on using whatever they were then.
    private func makeNotifier() -> NotificationManager {
        let settings = settings
        let state = state
        return NotificationManager(
            composer: NotificationComposer(
                ownAccountId: { MainActor.assumeIsolated { state.account?.accountId } },
                changeNotificationsSuppressed: {
                    MainActor.assumeIsolated { !settings.notificationsEnabled || settings.isSnoozed }
                }
            ),
            reveal: { [weak self] path in self?.revealInFinder(dbxPath: path) }
        )
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

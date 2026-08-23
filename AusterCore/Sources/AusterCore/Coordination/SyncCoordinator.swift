import Foundation

/// How the user is told about what sync did (engine-doc §10). Phase 8 supplies
/// the `UserNotifications` implementation.
public protocol SyncNotifying: Sendable {

    /// One notification per download cycle, not per file.
    func notifyDownloadBatch(_ completed: [SyncItemEvent])

    /// Conflicts get their own notification each: a conflicted copy is something
    /// the user has to look at.
    func notifyConflict(_ event: SyncItemEvent)

    func notifyItemError(_ error: SyncItemError)
    func notifyFatal(_ error: SyncFatalError)
}

/// Owns the lifecycle: the startup sequence, the worker loops, and the funnel
/// that decides what each kind of failure means (engine-doc §2, §3, §9).
///
/// Deliberately holds no sync logic — every decision about files belongs to
/// `SyncEngine`. What lives here is *when*: when to look for remote changes,
/// when a batch of local ones has settled enough to send, when to stop, and when
/// something has gone wrong badly enough that continuing would be worse than
/// stopping.
public actor SyncCoordinator {

    /// The timings of the loops, injectable so tests do not have to wait out
    /// real ones.
    public struct Tuning: Sendable {

        /// Longpoll timeout in seconds; Dropbox requires 30–480 and adds up to
        /// 90 s of jitter on top (api-notes §2).
        public var longpollTimeout: Int

        /// Pause after longpoll reports changes, letting a multi-step server
        /// operation finish before we list it (§4.1).
        public var settleAfterChanges: Duration

        /// How quiet the watcher has to go before a batch is sent (§5.1).
        public var uploadDebounce: Duration

        /// How long to wait before retrying after a connection failure.
        public var reconnectBackoff: Duration

        /// A floor on each loop iteration. Real longpolling blocks for a minute
        /// or more, but a mock — or a server answering instantly — must not turn
        /// the loop into a spin.
        public var loopFloor: Duration

        public init(
            longpollTimeout: Int = 40,
            settleAfterChanges: Duration = .seconds(2),
            uploadDebounce: Duration = .seconds(1),
            reconnectBackoff: Duration = .seconds(5),
            loopFloor: Duration = .milliseconds(200)
        ) {
            self.longpollTimeout = longpollTimeout
            self.settleAfterChanges = settleAfterChanges
            self.uploadDebounce = uploadDebounce
            self.reconnectBackoff = reconnectBackoff
            self.loopFloor = loopFloor
        }
    }

    private let service: DropboxService
    private let database: SyncDatabase
    private let config: AppConfig
    private let state: SyncState
    private let engine: SyncEngine
    private let monitor: LocalFileMonitor
    private let notifier: SyncNotifying
    private let collector: SyncEventCollector
    private let connection: ConnectionMonitoring?
    private let tuning: Tuning

    private var loops: Task<Void, Never>?
    private var pending: [RawFSEvent] = []
    private var lastEventAt: ContinuousClock.Instant?

    public init(
        service: DropboxService,
        database: SyncDatabase,
        config: AppConfig,
        state: SyncState,
        engine: SyncEngine,
        monitor: LocalFileMonitor,
        notifier: SyncNotifying,
        collector: SyncEventCollector,
        connection: ConnectionMonitoring? = nil,
        tuning: Tuning = Tuning()
    ) {
        self.service = service
        self.database = database
        self.config = config
        self.state = state
        self.engine = engine
        self.monitor = monitor
        self.notifier = notifier
        self.collector = collector
        self.connection = connection
        self.tuning = tuning
    }

    /// Whether the steady-state loops are up.
    public var isRunning: Bool {
        loops != nil
    }

    // MARK: - Wiring

    /// The engine callbacks that keep `SyncState` and the notifier fed.
    ///
    /// A static factory because of a construction order that cannot be avoided:
    /// the engine needs its callbacks at init, the coordinator needs the engine,
    /// and the callbacks need somewhere to put results. The collector is that
    /// somewhere, and this is where the three are tied together.
    public static func engineEvents(
        state: SyncState,
        monitor: LocalFileMonitor,
        database: SyncDatabase,
        pathStore: PathStore,
        collector: SyncEventCollector
    ) -> SyncEngineEvents {
        SyncEngineEvents(
            statusText: { detail in
                Task { @MainActor in state.setSyncing(detail: detail) }
            },
            itemStarted: { event in
                Task { @MainActor in state.itemStarted(event) }
            },
            itemProgress: { event, completed in
                Task { @MainActor in state.itemProgress(event, completed: completed) }
            },
            itemCompleted: { event, completion in
                collector.record(event, completion)
                Task { @MainActor in state.itemCompleted(event) }
            },
            rescanRequested: { url in
                // The engine renamed something behind the watcher's back, inside
                // an ignore. Without this the new file would never be uploaded.
                monitor.synthesizeRescan(of: url, index: database, pathStore: pathStore)
            }
        )
    }

    // MARK: - Lifecycle

    /// Runs the startup sequence, then brings up the steady-state loops (§3).
    ///
    /// Never throws: everything that can go wrong here has a defined
    /// consequence, and the caller — a menu click, or app launch — has nothing
    /// useful to do with an error.
    public func start() async {
        guard loops == nil else { return }

        // The coordinator only exists for a linked account; the app builds it
        // nowhere else.
        await MainActor.run { state.setLinked(true) }

        let paused = await MainActor.run { config.isPaused }
        guard !paused else {
            await MainActor.run {
                state.setPaused(true)
                state.setIdle()
            }
            return
        }

        await MainActor.run {
            state.setPaused(false)
            state.clearFatalError()
        }
        connection?.start()

        guard await runStartupSequence() else { return }
        startLoops()
    }

    /// - Returns: whether it is safe to enter steady state.
    private func runStartupSequence() async -> Bool {
        do {
            // 1. The folder, before anything that could interpret its absence as
            //    a deletion (§9).
            try LocalFileOperations.ensurePresent(root: monitor.root)

            // 2. Account and usage, which is also the authentication probe.
            let account = try await service.currentAccount()
            let usage = try? await service.spaceUsage()
            await MainActor.run {
                state.setAccount(account)
                state.setUsage(usage)
                state.setConnected(true)
            }

            // 3. Paths that failed last time, fetched fresh.
            for error in try database.syncErrors() where error.direction == .down {
                try await engine.fetchRemoteItem(dbxPathLower: error.dbxPathLower)
            }

            // 4. Folders the user re-selected but that were never fetched.
            try await drainPendingDownloads()

            // 5 and 6. Remote first, so the local scan diffs against an index
            //    that already knows about it (§3).
            try await engine.downloadCycle()
            await finishCycle(notifyDownloads: true)
            try await engine.catchUpScan()
            await finishCycle(notifyDownloads: false)
            return true
        } catch {
            return await handle(error)
        }
    }

    private func startLoops() {
        try? monitor.start()
        loops = Task { [weak self] in
            await withTaskGroup(of: Void.self) { group in
                group.addTask { await self?.watchLocalChanges() }
                group.addTask { await self?.longpollLoop() }
                group.addTask { await self?.uploadLoop() }
                group.addTask { await self?.connectionLoop() }
            }
        }
    }

    /// Stops the loops, leaving the reason to the caller.
    private func stopLoops() async {
        loops?.cancel()
        loops = nil
        monitor.stop()
        connection?.stop()
        await MainActor.run { state.clearActivity() }
    }

    /// The user's own pause. Persisted, because it should survive a restart
    /// (ux §9).
    public func pause() async {
        await stopLoops()
        await MainActor.run {
            config.isPaused = true
            state.setPaused(true)
            state.setIdle()
        }
    }

    public func resume() async {
        await MainActor.run {
            config.isPaused = false
            state.setPaused(false)
        }
        await start()
    }

    public func stopForQuit() async {
        await stopLoops()
    }

    /// Throws the index away and derives it again from both sides (§9).
    ///
    /// Safe precisely because the index is not data: everything in it can be
    /// recomputed, and where the two sides disagree the rebuild produces
    /// conflicted copies rather than losses.
    public func rebuildIndex() async {
        await stopLoops()
        try? database.removeIndexSubtree(pathLower: "")
        try? database.setState(.remoteCursor, nil)
        try? database.setState(.localCursorTimestamp, nil)
        try? database.setState(.didFinishIndexing, nil)
        try? database.setState(.indexingCounter, nil)
        await start()
    }

    /// Applies a new selective-sync selection (engine-doc §8).
    ///
    /// The order is the whole safety argument. The selection is persisted
    /// *first*, so that an interruption anywhere after this point leaves the
    /// engine filtering by what the user asked for rather than by what it used
    /// to sync. Exclusions are then applied — local copies deleted, index
    /// subtrees pruned — and inclusions are only ever *queued*: the queue is a
    /// table, so a folder the user re-selected is fetched on the next start even
    /// if this one never gets that far.
    ///
    /// Never throws. A failure here means one folder did not finish changing
    /// state, which the funnel reports the same way it reports any other; the
    /// caller is a checkbox, and has nothing better to do with an error.
    public func setExcluded(items: Set<String>) async {
        let current = (try? database.excludedItems()) ?? []
        let delta = SelectiveSync.delta(current: current, requested: items)

        try? database.setExcludedItems(delta.excluded)
        await MainActor.run { config.excludedItems = delta.excluded }

        do {
            for path in delta.newlyExcluded {
                try await engine.removeExcluded(dbxPathLower: path)
            }
            // Queued before any of them is fetched, so an interruption partway
            // through resumes rather than silently leaving a folder empty
            // (engine-doc §1.5).
            for path in delta.newlyIncluded {
                try database.addPendingDownload(path)
            }
            try await drainPendingDownloads()
        } catch {
            await handle(error)
        }

        await refreshLists()
    }

    /// Fetches everything on the pending-downloads queue, taking each path off
    /// only once its bytes are on disk.
    private func drainPendingDownloads() async throws {
        for path in try database.pendingDownloads() {
            try await engine.fetchRemoteItem(dbxPathLower: path)
            try database.removePendingDownload(path)
        }
    }

    // MARK: - Loops (§2)

    /// Waits for remote changes and applies them.
    private func longpollLoop() async {
        while !Task.isCancelled {
            do {
                let cursor = try database.stateString(.remoteCursor) ?? ""
                if cursor.isEmpty {
                    // Nothing to longpoll against yet; index first.
                    try await engine.downloadCycle()
                    await finishCycle(notifyDownloads: true)
                } else {
                    let result = try await service.longpoll(
                        cursor: cursor,
                        timeout: tuning.longpollTimeout
                    )
                    if let backoff = result.backoff {
                        // The server asked us to wait; ignoring it is how a
                        // client gets rate limited (api-notes §5).
                        try await Task.sleep(for: .seconds(backoff + 5))
                    }
                    if result.changes {
                        // Multi-step server operations can still be in flight.
                        try await Task.sleep(for: tuning.settleAfterChanges)
                        try await engine.downloadCycle()
                        await finishCycle(notifyDownloads: true)
                        await refreshUsage()
                    }
                }
                await markOnline()
            } catch {
                guard await handleInLoop(error) else { return }
            }
            try? await Task.sleep(for: tuning.loopFloor)
        }
    }

    /// Feeds the watcher's events into the batch the upload loop drains.
    private func watchLocalChanges() async {
        for await event in monitor.events {
            if Task.isCancelled { return }
            enqueue(event)
        }
    }

    private func enqueue(_ event: RawFSEvent) {
        pending.append(event)
        lastEventAt = ContinuousClock.now
    }

    /// Sends a batch once the watcher has gone quiet (§5.1).
    ///
    /// The debounce matters more than it looks: an editor's atomic save arrives
    /// as several events milliseconds apart, and uploading after the first would
    /// send a file that is about to be replaced.
    private func uploadLoop() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: tuning.uploadDebounce)
            guard let batch = takeSettledBatch() else { continue }

            do {
                try await engine.uploadCycle(rawEvents: batch)
                await finishCycle(notifyDownloads: false)
                await markOnline()
            } catch {
                guard await handleInLoop(error) else { return }
            }
        }
    }

    /// The pending events, but only once nothing has arrived for a whole
    /// debounce interval.
    private func takeSettledBatch() -> [RawFSEvent]? {
        guard !pending.isEmpty, let lastEventAt else { return nil }
        guard ContinuousClock.now - lastEventAt >= tuning.uploadDebounce else { return nil }

        defer {
            pending.removeAll()
            self.lastEventAt = nil
        }
        return pending
    }

    /// Reacts to the network coming back, rather than waiting out a backoff.
    private func connectionLoop() async {
        guard let connection else { return }
        for await online in connection.isOnline {
            if Task.isCancelled { return }
            await MainActor.run { state.setConnected(online) }
        }
    }

    // MARK: - After a cycle

    /// Publishes what a cycle did: the lists the UI reads, and the notifications
    /// (§10).
    private func finishCycle(notifyDownloads: Bool) async {
        let completed = collector.drain()

        // Conflicts get their own notification whichever way they happened: a
        // conflicted copy is something the user has to look at.
        for item in completed where item.completion == .conflictedCopy {
            notifier.notifyConflict(item.event)
        }
        for item in completed {
            if case .failed(let error) = item.completion { notifier.notifyItemError(error) }
        }
        if notifyDownloads {
            // Only remote changes. Telling users about their own edits is noise.
            let downloads =
                completed
                .filter { $0.event.direction == .down && $0.completion == .done }
                .map(\.event)
            notifier.notifyDownloadBatch(downloads)
        }

        await refreshLists()
    }

    /// Republishes the lists the UI reads, and returns the status to rest.
    private func refreshLists() async {
        let history = (try? database.recentHistory(limit: 30)) ?? []
        let errors = (try? database.syncErrors()) ?? []
        await MainActor.run {
            state.setRecentChanges(history)
            state.setSyncErrors(errors)
            state.clearActivity()
            state.setIdle()
        }
    }

    private func refreshUsage() async {
        guard let usage = try? await service.spaceUsage() else { return }
        await MainActor.run { state.setUsage(usage) }
    }

    private func markOnline() async {
        await MainActor.run { state.setConnected(true) }
    }

    // MARK: - The error funnel (§2)

    /// Decides what a failure means.
    ///
    /// - Returns: whether it is safe to carry on. `false` means the loops have
    ///   been stopped and the reason surfaced.
    @discardableResult
    private func handle(_ error: Error) async -> Bool {
        if error is CancellationError { return false }

        if let fatal = error as? SyncFatalError {
            await stopLoops()
            await MainActor.run { state.setFatalError(fatal) }
            notifier.notifyFatal(fatal)
            return false
        }

        guard let serviceError = error as? DropboxServiceError else {
            // Nothing recognisable. Stopping is safer than looping on it.
            await stopLoops()
            let fatal = SyncFatalError.unexpected(error.localizedDescription)
            await MainActor.run { state.setFatalError(fatal) }
            notifier.notifyFatal(fatal)
            return false
        }

        switch serviceError {
        case .notAuthorized:
            return await handle(SyncFatalError.notAuthorized)

        case .connection:
            // Not a pause: the status says "Connecting…", the user's own pause
            // flag is untouched, and the loop retries by itself (ux §9).
            await MainActor.run { state.setConnected(false) }
            return true

        default:
            // Everything else concerns one path and the engine has already
            // recorded it as a sync issue.
            return true
        }
    }

    /// The funnel from inside a loop: a recoverable failure waits out a backoff
    /// rather than retrying immediately.
    private func handleInLoop(_ error: Error) async -> Bool {
        guard await handle(error) else { return false }
        do {
            try await Task.sleep(for: tuning.reconnectBackoff)
        } catch {
            return false
        }
        return true
    }
}

import Foundation

/// The sync algorithms of engine-doc §§3–9.
///
/// An actor because only one cycle may mutate the local folder and the index at
/// a time (design §3); parallelism lives *inside* a cycle, in the bounded task
/// group that runs file transfers. Nothing here decides *when* to sync — the
/// coordinator drives longpolling and scheduling, so a cycle is always something
/// somebody asked for and can cancel.
public actor SyncEngine {

    /// Concurrent transfers per direction (engine-doc §7).
    static let transferConcurrency = 6

    private let service: DropboxService
    private let database: SyncDatabase
    private let pathStore: PathStore
    private let hasher: CachedContentHasher
    private let fileOps: LocalFileOperations

    /// Read fresh on every use: Phase 7 lets the user change the selection while
    /// a cycle is running, and a captured snapshot would act on a stale one.
    private let excludedItems: @Sendable () -> Set<String>

    private let events: SyncEngineEvents

    /// The linked account's display name, for conflicted-copy naming. Resolved
    /// once per cycle rather than per item.
    private var ownerName: String?

    public init(
        service: DropboxService,
        database: SyncDatabase,
        pathStore: PathStore,
        hasher: CachedContentHasher,
        fileOps: LocalFileOperations,
        excludedItems: @escaping @Sendable () -> Set<String>,
        events: SyncEngineEvents
    ) {
        self.service = service
        self.database = database
        self.pathStore = pathStore
        self.hasher = hasher
        self.fileOps = fileOps
        self.excludedItems = excludedItems
        self.events = events
    }

    // MARK: - Download cycle (§4.1)

    /// Applies everything the remote has done since the saved cursor.
    ///
    /// With no cursor this is the first-run index of the whole Dropbox; with one
    /// it is a delta. Longpolling is deliberately *not* here: deciding when to
    /// ask is the coordinator's job, and this stays a single, cancellable unit of
    /// work.
    ///
    /// - Throws: `SyncFatalError` and connection failures, which stop sync.
    ///   Per-path failures are recorded as sync issues and never surface here.
    public func downloadCycle() async throws {
        try fileOps.ensureRootPresent()
        defer { fileOps.cleanCacheDir() }

        let applier = try await makeApplier()

        do {
            try await runDownloadPages(with: applier)
        } catch DropboxServiceError.cursorReset {
            // The cursor is void; everything has to be re-derived. Nothing local
            // is discarded — the re-index diffs against the index we still have,
            // so unchanged files are recognised rather than re-downloaded.
            try database.setState(.remoteCursor, nil)
            try database.setState(.didFinishIndexing, "0")
            try await runDownloadPages(with: applier)
        }
    }

    /// Pages through the listing, applying and then persisting each page.
    ///
    /// The cursor is written *after* its page is applied, never before: that
    /// ordering is what makes an interruption resumable instead of lossy
    /// (decisions D9.4).
    private func runDownloadPages(with applier: DownloadApplier) async throws {
        let savedCursor = try database.stateString(.remoteCursor) ?? ""
        var isIndexing = try database.stateString(.didFinishIndexing) != "1"

        var page: ListPage
        if savedCursor.isEmpty {
            isIndexing = true
            try database.setState(.didFinishIndexing, "0")
            try database.setState(.indexingCounter, "0")
            page = try await listRoot()
        } else {
            page = try await mapFatal { try await service.listFolderContinue(cursor: savedCursor) }
        }

        while true {
            try Task.checkCancellation()

            let applied = try await applyPage(page.entries, with: applier, indexing: isIndexing)
            try database.setState(.remoteCursor, page.cursor)

            if isIndexing {
                let total = (Int(try database.stateString(.indexingCounter) ?? "0") ?? 0) + applied
                try database.setState(.indexingCounter, String(total))
                events.statusText("Indexing \(total)…")
            }

            guard page.hasMore else { break }
            page = try await mapFatal { try await service.listFolderContinue(cursor: page.cursor) }
        }

        if isIndexing {
            try database.setState(.didFinishIndexing, "1")
        }
    }

    private func listRoot() async throws -> ListPage {
        try await mapFatal { try await service.listFolder(path: "", recursive: true) }
    }

    // MARK: - Applying a page (§4.2, §4.3)

    /// Cleans, filters, orders and applies one page.
    ///
    /// - Returns: how many events were applied, for the indexing counter.
    @discardableResult
    private func applyPage(
        _ entries: [RemoteMetadata],
        with applier: DownloadApplier,
        indexing: Bool
    ) async throws -> Int {
        let cleaned = try RemoteChangeCleaner.clean(entries, index: database)
        let admitted = try admissible(cleaned)
        guard !admitted.isEmpty else { return 0 }

        if !indexing { events.statusText("Syncing…") }

        var built: [SyncItemEvent] = []
        built.reserveCapacity(admitted.count)
        for entry in admitted {
            built.append(try await SyncItemEvent(remote: entry, index: database, pathStore: pathStore))
        }

        // Deletions and folders shallowest-first: removing a parent takes its
        // children with it, and creating one has to precede them.
        let deletions = built.filter { $0.changeType == .removed }.sorted(by: Self.shallowestFirst)
        let folders = built.filter { $0.changeType != .removed && $0.itemType == .folder }
            .sorted(by: Self.shallowestFirst)
        let files = built.filter { $0.changeType != .removed && $0.itemType != .folder }

        for event in deletions + folders {
            try Task.checkCancellation()
            try await applyOne(event, with: applier)
        }
        try await forEachConcurrently(files) { event in
            try await self.applyOne(event, with: applier)
        }

        return built.count
    }

    /// Runs transfers concurrently, bounded so a large batch cannot open a
    /// connection per item (engine-doc §7).
    ///
    /// A hand-rolled window rather than adding every task up front: a page can
    /// hold thousands of files, and starting them all would defeat the bound the
    /// semaphore exists to impose.
    private func forEachConcurrently(
        _ events: [SyncItemEvent],
        _ body: @escaping @Sendable (SyncItemEvent) async throws -> Void
    ) async throws {
        guard !events.isEmpty else { return }

        try await withThrowingTaskGroup(of: Void.self) { group in
            var next = 0
            let inFlight = min(Self.transferConcurrency, events.count)

            for _ in 0..<inFlight {
                let event = events[next]
                next += 1
                group.addTask { try await body(event) }
            }

            while try await group.next() != nil {
                guard next < events.count else { continue }
                try Task.checkCancellation()
                let event = events[next]
                next += 1
                group.addTask { try await body(event) }
            }
        }
    }

    private func applyOne(_ event: SyncItemEvent, with applier: DownloadApplier) async throws {
        try await record(event) { try await applier.apply(event) }
    }

    private func applyOne(_ event: SyncItemEvent, with applier: UploadApplier) async throws {
        try await record(event) { try await applier.apply(event) }
    }

    /// Runs one item's handler, turning anything that concerns only this path
    /// into a recorded sync issue (design §5).
    ///
    /// The distinction is what keeps a cycle useful: a file Dropbox will not
    /// name should not stop the other nine hundred, while a revoked token means
    /// every one of them would fail the same way.
    ///
    /// The local filesystem is on the per-path side of that line too, and that
    /// is easy to get wrong. A folder the user made read-only, a name the volume
    /// will not take, a disk that filled up between two files — each of those
    /// arrives as a `CocoaError` or a POSIX errno rather than as anything
    /// Dropbox-shaped, and letting one escape would stop all syncing and report
    /// a fatal error over a single file.
    private func record(
        _ event: SyncItemEvent,
        _ handler: () async throws -> SyncCompletion
    ) async throws {
        do {
            let completion = try await handler()
            try database.clearSyncErrors(pathLower: event.dbxPathLower)
            try recordHistory(for: event, completion: completion)
            events.itemCompleted(event, completion)
        } catch let error as DropboxServiceError {
            switch error {
            case .notAuthorized: throw SyncFatalError.notAuthorized
            case .connection, .cursorReset: throw error
            default: break
            }
            try recordFailure(of: event, message: error.localizedDescription)
        } catch let error as SyncFatalError {
            // The folder is gone, or the account is: nothing about this is
            // specific to one path.
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try recordFailure(of: event, message: error.localizedDescription)
        }
    }

    private func recordFailure(of event: SyncItemEvent, message: String) throws {
        let itemError = SyncItemError(
            dbxPath: event.dbxPath,
            dbxPathLower: event.dbxPathLower,
            direction: event.direction,
            title: Self.failureTitle(for: event),
            message: message
        )
        try database.upsertSyncError(itemError.entry)
        events.itemCompleted(event, .failed(itemError))
    }

    private static func failureTitle(for event: SyncItemEvent) -> String {
        let noun = event.itemType == .folder ? "folder" : "file"
        switch (event.direction, event.changeType) {
        case (_, .removed): return "Could not delete item"
        case (_, .moved): return "Could not move item"
        case (.down, _): return "Could not download \(noun)"
        case (.up, _): return "Could not upload \(noun)"
        }
    }

    private func recordHistory(for event: SyncItemEvent, completion: SyncCompletion) throws {
        // Only real changes are worth showing: a skip means the folder already
        // looked the way it looks now.
        guard completion == .done || completion == .conflictedCopy else { return }
        try database.appendHistory(
            HistoryEntry(
                direction: event.direction,
                changeType: event.changeType,
                itemType: event.itemType ?? .file,
                dbxPath: event.dbxPath,
                size: event.size,
                timestamp: event.changeTime ?? Date()
            )
        )
    }

    // MARK: - Upload cycle (§5.4, §5.5)

    /// Sends one batch of local changes to Dropbox.
    ///
    /// The batch arrives raw from the watcher — or synthesised by the catch-up
    /// scan, which is the same shape on purpose — and is cleaned into one intent
    /// per path before anything is hashed or sent (§5.3).
    ///
    /// - Throws: `SyncFatalError` and connection failures. Per-path failures are
    ///   recorded as sync issues.
    public func uploadCycle(rawEvents: [RawFSEvent]) async throws {
        guard !rawEvents.isEmpty else { return }
        try fileOps.ensureRootPresent()

        let excluded = excludedItems()
        let cleaned = LocalEventCleaner.clean(
            rawEvents,
            // Only for deciding whether a rename may be recombined into a move:
            // a rename across the selective-sync boundary is a deletion on one
            // side and nothing on the other, not a move (§5.3 rule 3).
            isExcluded: { url in
                guard let dbxPath = try? pathStore.toDbxPath(localURL: url) else { return false }
                return Exclusions.isExcluded(byUser: PathStore.normalize(dbxPath), excluded: excluded)
            },
            requestRescan: { events.rescanRequested($0) }
        )
        guard !cleaned.isEmpty else { return }

        let built = try await convert(cleaned)
        guard !built.isEmpty else { return }

        events.statusText("Syncing…")
        let applier = UploadApplier(
            service: service,
            database: database,
            pathStore: pathStore,
            hasher: hasher,
            fileOps: fileOps,
            events: events,
            excludedItems: excludedItems
        )
        try await applyUploads(built, with: applier)

        // Only now: this timestamp is the bar the next catch-up scan measures
        // mtimes against, and moving it before the work is done would hide
        // whatever the cycle failed to send (decisions D9.4).
        try database.setState(.localCursorTimestamp, String(Date().timeIntervalSince1970))
    }

    /// Runs the offline catch-up scan and applies whatever it finds (§6).
    public func catchUpScan() async throws {
        let cursor = (try database.stateString(.localCursorTimestamp)).flatMap(Double.init)
        let scanned = try CatchUpScanner.scan(
            root: fileOps.root,
            database: database,
            pathStore: pathStore,
            localCursor: cursor.map { Date(timeIntervalSince1970: $0) }
        )
        try await uploadCycle(rawEvents: scanned)
    }

    /// Turns cleaned filesystem events into sync events, hashing in parallel.
    ///
    /// Hashing is the expensive part of the upload direction and it is pure
    /// local work, so it happens for the whole batch up front rather than one
    /// file at a time between network calls.
    private func convert(_ cleaned: [RawFSEvent]) async throws -> [SyncItemEvent] {
        let admitted = cleaned.filter { !Exclusions.isExcludedName($0.url.lastPathComponent) }
        guard !admitted.isEmpty else { return [] }

        let database = database
        let pathStore = pathStore
        let hasher = hasher

        return try await withThrowingTaskGroup(of: (Int, SyncItemEvent?).self) { group in
            for (offset, raw) in admitted.enumerated() {
                group.addTask {
                    // A file that vanished between the event and the hash is not
                    // a cycle failure; the deletion event is already on its way.
                    let event = try? SyncItemEvent(
                        local: raw,
                        index: database,
                        pathStore: pathStore,
                        hasher: hasher
                    )
                    return (offset, event)
                }
            }

            var built = [SyncItemEvent?](repeating: nil, count: admitted.count)
            for try await (offset, event) in group { built[offset] = event }
            return built.compactMap(\.self)
        }
    }

    /// Applies a batch in the order of §5.5.
    ///
    /// Dropbox offers no transaction, so the sequence of calls *is* the
    /// correctness argument: deletions first because a creation may want the
    /// name, directory moves next and one at a time because each takes a whole
    /// subtree with it, then everything else shallowest-first so a parent always
    /// exists before its children are sent.
    private func applyUploads(_ built: [SyncItemEvent], with applier: UploadApplier) async throws {
        let deletions = built.filter { $0.changeType == .removed }
        let directoryMoves = built.filter { $0.changeType == .moved && $0.itemType == .folder }
        let rest = built.filter { $0.changeType != .removed && !($0.changeType == .moved && $0.itemType == .folder) }

        try await forEachConcurrently(deletions) { event in
            try await self.applyOne(event, with: applier)
        }

        for event in directoryMoves.sorted(by: Self.shallowestFirst) {
            try Task.checkCancellation()
            try await applyOne(event, with: applier)
        }

        for depth in Set(rest.map { Self.depth(of: $0.dbxPathLower) }).sorted() {
            try Task.checkCancellation()
            let level = rest.filter { Self.depth(of: $0.dbxPathLower) == depth }
            try await forEachConcurrently(level) { event in
                try await self.applyOne(event, with: applier)
            }
        }
    }

    // MARK: - Filtering (§8)

    /// Drops what Auster never syncs and what the user deselected.
    ///
    /// A deletion is the one thing an exclusion does not suppress: once the item
    /// is gone from Dropbox there is nothing left to exclude, and keeping the
    /// entry would silently swallow a future folder of the same name.
    private func admissible(_ entries: [RemoteMetadata]) throws -> [RemoteMetadata] {
        let excluded = excludedItems()
        var retracted: Set<String> = []

        let kept = entries.filter { entry in
            let pathLower = PathStore.normalize(entry.pathLower)
            if Exclusions.isExcludedName(pathLower) { return false }
            guard Exclusions.isExcluded(byUser: pathLower, excluded: excluded) else { return true }

            if entry.isDeleted { retracted.insert(pathLower) }
            return false
        }

        if !retracted.isEmpty { try retractExclusions(under: retracted) }
        return kept
    }

    /// Removes deleted paths, and everything beneath them, from the stored
    /// selective-sync set.
    ///
    /// The database is the source of truth for the selection (implementation
    /// note N10); the UI's mirror is Phase 7's to keep in step.
    private func retractExclusions(under retracted: Set<String>) throws {
        let stored = try database.excludedItems()
        let remaining = stored.filter { entry in
            !retracted.contains { entry == $0 || entry.hasPrefix($0 + "/") }
        }
        guard remaining.count != stored.count else { return }
        try database.setExcludedItems(remaining)
    }

    // MARK: - Single items (§4)

    /// Fetches one remote path and applies it, recursively for a folder.
    ///
    /// Used where a cycle is the wrong unit of work: retrying a path that failed
    /// last time, and Phase 7's "include this folder again", which has to fetch a
    /// subtree the cursor has long since moved past. The cursor is untouched — this
    /// is out-of-band, and advancing it would skip changes the next cycle owes us.
    public func fetchRemoteItem(dbxPathLower: String) async throws {
        try fileOps.ensureRootPresent()
        defer { fileOps.cleanCacheDir() }

        let applier = try await makeApplier()
        let pathLower = PathStore.normalize(dbxPathLower)

        guard let metadata = try await mapFatal({ try await service.metadata(path: pathLower, includeDeleted: true) })
        else {
            return
        }

        var entries = [metadata]
        if metadata.asFolder != nil {
            var page = try await mapFatal { try await service.listFolder(path: pathLower, recursive: true) }
            entries.append(contentsOf: page.entries)
            while page.hasMore {
                page = try await mapFatal { try await service.listFolderContinue(cursor: page.cursor) }
                entries.append(contentsOf: page.entries)
            }
        }

        try await applyPage(entries, with: applier, indexing: false)
    }

    // MARK: - Selective sync (§8)

    /// Takes a newly excluded subtree out of the local folder and the index.
    ///
    /// Runs on the engine rather than on the coordinator because it mutates the
    /// same two things a sync cycle does, and the engine's isolation is what
    /// stops the two from interleaving. The deletion is ignore-wrapped like
    /// every other local mutation (decisions D9.2), so removing a folder the
    /// user deselected is never mistaken for the user deleting it — which would
    /// delete it on Dropbox too.
    ///
    /// Order matters: the disk first, the index second. An index pruned ahead of
    /// a deletion that then fails would leave files the catch-up scan reads as
    /// brand new and uploads straight back.
    public func removeExcluded(dbxPathLower: String) async throws {
        try fileOps.ensureRootPresent()

        let pathLower = PathStore.normalize(dbxPathLower)
        let cased = try database.indexEntry(forPathLower: pathLower)?.dbxPathCased ?? pathLower

        // Not `requireExactCasing`: the path comes from the user's selection via
        // the index, not from a remote event, so there is no casing to disagree
        // with — and refusing the delete would leave the folder syncing.
        try fileOps.deleteItem(at: pathStore.toLocalURL(dbxPathCased: cased), requireExactCasing: false)

        try database.removeIndexSubtree(pathLower: pathLower)
        try database.clearSyncErrors(pathLower: pathLower)
    }

    // MARK: - Internals

    private func makeApplier() async throws -> DownloadApplier {
        if ownerName == nil {
            ownerName = try? await service.currentAccount().displayName
        }
        return DownloadApplier(
            service: service,
            database: database,
            pathStore: pathStore,
            hasher: hasher,
            fileOps: fileOps,
            events: events,
            ownerName: ownerName
        )
    }

    /// Turns the errors that end a session into `SyncFatalError`, leaving the
    /// rest for the per-path handler.
    private func mapFatal<T>(_ body: () async throws -> T) async throws -> T {
        do {
            return try await body()
        } catch DropboxServiceError.notAuthorized {
            throw SyncFatalError.notAuthorized
        }
    }

    private static func shallowestFirst(_ lhs: SyncItemEvent, _ rhs: SyncItemEvent) -> Bool {
        depth(of: lhs.dbxPathLower) < depth(of: rhs.dbxPathLower)
    }

    private static func depth(of pathLower: String) -> Int {
        pathLower.reduce(into: 0) { count, character in
            if character == "/" { count += 1 }
        }
    }
}

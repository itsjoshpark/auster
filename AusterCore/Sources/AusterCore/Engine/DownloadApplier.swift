import Foundation

/// Applies one remote change to the local folder (engine-doc §4.6–§4.8).
///
/// The order of operations is the algorithm: casing first, then the conflict
/// decision, then the parent, then the write — and the write itself is staged,
/// re-checked and moved atomically, because a download is the longest window in
/// the engine during which the user can change the very file being replaced.
/// Nothing here overwrites a local item it has not first accounted for
/// (decisions D9).
struct DownloadApplier: Sendable {

    let service: DropboxService
    let database: SyncDatabase
    let pathStore: PathStore
    let hasher: CachedContentHasher
    let fileOps: LocalFileOperations
    let events: SyncEngineEvents

    /// The linked account's display name, used in conflicted-copy names. `nil`
    /// drops the possessive rather than inventing an owner.
    let ownerName: String?

    /// Serializes parent creation. Files are applied in parallel, and without
    /// this two of them landing in the same new folder would race to make it.
    let parents: ParentFolderCreator

    init(
        service: DropboxService,
        database: SyncDatabase,
        pathStore: PathStore,
        hasher: CachedContentHasher,
        fileOps: LocalFileOperations,
        events: SyncEngineEvents,
        ownerName: String?
    ) {
        self.service = service
        self.database = database
        self.pathStore = pathStore
        self.hasher = hasher
        self.fileOps = fileOps
        self.events = events
        self.ownerName = ownerName
        self.parents = ParentFolderCreator(
            service: service,
            database: database,
            pathStore: pathStore,
            fileOps: fileOps
        )
    }

    /// Applies `event`, reporting what happened.
    ///
    /// - Throws: only what cannot be attributed to this one path — a lost
    ///   connection, a missing Dropbox folder. Per-path failures are the
    ///   caller's to record.
    @discardableResult
    func apply(_ event: SyncItemEvent) async throws -> SyncCompletion {
        // 1. Casing first (§4.6 step 1). Everything after this assumes the local
        //    item is spelled the way the remote spells it, including the
        //    exact-casing delete guard.
        try applyCaseChange(for: event)

        let index = try database.indexEntry(forPathLower: event.dbxPathLower)
        let decision = try ConflictResolver.check(
            event: event,
            index: index,
            hasher: hasher,
            database: database
        )

        switch decision {
        case .localNewerOrIdentical:
            return .skipped

        case .identical:
            // The bytes are already here under an older revision; recording the
            // new one is what stops the next cycle asking again.
            try upsertIndex(for: event, contentHash: event.contentHash, index: index)
            return .skipped

        case .conflict:
            try preserveAsConflictedCopy(at: event.localURL)

        case .remoteNewer:
            break
        }

        events.itemStarted(event)
        try await applyResolved(event, index: index)
        return decision == .conflict ? .conflictedCopy : .done
    }

    /// The write itself, once the decision to write has been made.
    private func applyResolved(_ event: SyncItemEvent, index: IndexEntry?) async throws {
        if event.changeType == .removed {
            try applyDeletion(event)
            return
        }

        try await parents.ensureParent(ofCased: event.dbxPath)

        if event.itemType == .folder {
            try applyFolder(event)
        } else {
            try await applyFile(event, index: index)
        }
    }

    // MARK: - Casing (§4.6 step 1)

    /// Renames the local item when the remote has recased it.
    ///
    /// A pure Unicode-normalization difference is *not* a rename: macOS and
    /// Dropbox disagree about composition for the same name, and acting on that
    /// would rename the file back and forth forever (§9).
    private func applyCaseChange(for event: SyncItemEvent) throws {
        guard let index = try database.indexEntry(forPathLower: event.dbxPathLower) else { return }
        let previous = index.dbxPathCased
        guard previous != event.dbxPath, !PathStore.equalButForUnicodeNorm(previous, event.dbxPath) else {
            return
        }

        let source = pathStore.toLocalURL(dbxPathCased: previous)
        if FileManager.default.fileExists(atPath: source.path) {
            try fileOps.moveItem(from: source, to: event.localURL)
        }

        // The whole subtree's cased paths hang off this one, so they move with
        // it — otherwise every child would look like a new item next cycle.
        for entry in try database.indexEntries(underPathLower: index.dbxPathLower) {
            guard entry.dbxPathCased.hasPrefix(previous) else { continue }
            var moved = entry
            moved.dbxPathCased = event.dbxPath + String(entry.dbxPathCased.dropFirst(previous.count))
            try database.upsertIndexEntry(moved)
        }
    }

    // MARK: - Conflicted copies (§4.4)

    /// Moves the local item aside under a Dropbox-style conflicted-copy name and
    /// asks for it to be rescanned, so it uploads as a new file.
    ///
    /// Nothing is destroyed here: that is the entire point of the rename.
    private func preserveAsConflictedCopy(at localURL: URL) throws {
        guard FileManager.default.fileExists(atPath: localURL.path) else { return }

        let copy = PathStore.conflictedCopyName(for: localURL, suffix: Self.conflictedCopySuffix(owner: ownerName))
        try fileOps.moveItem(from: localURL, to: copy)
        events.rescanRequested(copy)
    }

    /// `"<Owner>'s conflicted copy YYYY-MM-DD"`, or the ownerless form.
    static func conflictedCopySuffix(owner: String?, on date: Date = Date()) -> String {
        // The local zone, not UTC: the date belongs to the user's day, and
        // `.iso8601` defaults to GMT.
        let format = Date.ISO8601FormatStyle(dateSeparator: .dash, timeZone: .current)
        let day = date.formatted(format.year().month().day())

        guard let owner, !owner.isEmpty else { return "conflicted copy \(day)" }
        return "\(owner)'s conflicted copy \(day)"
    }

    // MARK: - Folders (§4.7)

    private func applyFolder(_ event: SyncItemEvent) throws {
        // A file sitting where the folder goes has already survived the conflict
        // check, so it is either identical-in-name-only or already preserved.
        if isRegularItem(at: event.localURL, directory: false) {
            try fileOps.deleteItem(at: event.localURL, requireExactCasing: false)
        }
        try fileOps.makeDirectory(at: event.localURL)
        try upsertIndex(for: event, contentHash: ItemType.folderSentinel, index: nil)
    }

    // MARK: - Files (§4.6)

    private func applyFile(_ event: SyncItemEvent, index: IndexEntry?) async throws {
        if let target = event.symlinkTarget {
            // A symlink's content is its target's, and that syncs separately —
            // there is nothing to transfer (§4.6 step 4).
            if isRegularItem(at: event.localURL, directory: true) {
                try fileOps.deleteItem(at: event.localURL, requireExactCasing: false)
            }
            try fileOps.createSymlink(at: event.localURL, target: target)
            try upsertIndex(for: event, contentHash: event.contentHash, index: index)
            return
        }

        guard let rev = event.rev else {
            throw SyncFatalError.unexpected("A remote file event for \(event.dbxPath) carried no revision.")
        }

        let staged = try fileOps.newTempFile()
        // The staging file lives in the cache dir; leaving it behind on any exit
        // would slowly fill the user's Dropbox folder with orphans.
        defer { try? FileManager.default.removeItem(at: staged) }

        let downloaded = try await service.download(rev: rev, to: staged) { bytes in
            events.itemProgress(event, bytes)
        }

        // Stamp the staged file, not the final one: the move is the moment the
        // file becomes visible, and it should already be correct by then.
        try fileOps.setModificationDate(Self.localModificationDate(for: downloaded), at: staged)

        // 7. The download had a window; the user may have used it.
        let current = try database.indexEntry(forPathLower: event.dbxPathLower)
        let recheck = try ConflictResolver.check(
            event: event,
            index: current,
            hasher: hasher,
            database: database
        )
        if recheck == .conflict {
            try preserveAsConflictedCopy(at: event.localURL)
        }

        // 8. A folder in the way has to go before a file can take the path.
        if isRegularItem(at: event.localURL, directory: true) {
            try fileOps.deleteItem(at: event.localURL, requireExactCasing: false)
        }

        // 9. Only a content update inherits the old file's mode: a *different*
        //    Dropbox item arriving at this path is a new file, not a new version.
        try fileOps.atomicMoveIntoPlace(
            from: staged,
            to: event.localURL,
            preservePermissions: index?.dbxId == event.dbxId
        )

        try upsertIndex(for: event, contentHash: downloaded.contentHash ?? event.contentHash, index: index)
        cacheHash(downloaded.contentHash ?? event.contentHash, at: event.localURL)
    }

    /// `min(clientModified, serverModified, now)` (§4.6 step 6).
    ///
    /// `client_modified` is whatever the uploading client claimed, so it is
    /// clamped: a wrong clock somewhere else must not date the user's file in
    /// the future.
    static func localModificationDate(for file: RemoteFile, now: Date = Date()) -> Date {
        min(file.clientModified, file.serverModified, now)
    }

    // MARK: - Deletions (§4.8)

    private func applyDeletion(_ event: SyncItemEvent) throws {
        // Exact casing: on a case-insensitive volume a delete of `A.txt` would
        // otherwise take the user's `a.txt` with it.
        try fileOps.deleteItem(at: event.localURL, requireExactCasing: true)
        // Dropbox reports no tombstones for the children of a deleted folder
        // (api-notes §3), so the index is the only record of what went with it.
        try database.removeIndexSubtree(pathLower: event.dbxPathLower)
    }

    // MARK: - Index & hash cache

    private func upsertIndex(for event: SyncItemEvent, contentHash: String?, index: IndexEntry?) throws {
        try database.upsertIndexEntry(
            IndexEntry(
                dbxPathLower: event.dbxPathLower,
                dbxPathCased: event.dbxPath,
                dbxId: event.dbxId ?? index?.dbxId ?? "",
                itemType: event.itemType ?? .file,
                lastSync: Date(),
                rev: event.rev ?? ItemType.folderSentinel,
                contentHash: contentHash,
                symlinkTarget: event.symlinkTarget
            )
        )
    }

    /// Records the hash we already know for the file just written, so the next
    /// scan does not read it back to learn what we were told.
    private func cacheHash(_ hash: String?, at localURL: URL) {
        guard let hash,
            let attributes = try? FileManager.default.attributesOfItem(atPath: localURL.path),
            let inode = attributes[.systemFileNumber] as? UInt64,
            let mtime = attributes[.modificationDate] as? Date
        else {
            return
        }
        try? database.storeHash(inode: inode, localPath: localURL.path, hash: hash, mtime: mtime)
    }

    // MARK: - Probes

    /// Whether a real item of the given kind sits at `url`. Symlinks count as
    /// files, never as the directories they may point at.
    private func isRegularItem(at url: URL, directory: Bool) -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
            let type = attributes[.type] as? FileAttributeType
        else {
            return false
        }
        return directory ? type == .typeDirectory : type != .typeDirectory
    }
}

/// Creates the folders an incoming item needs, one at a time (engine-doc §4.3).
///
/// An actor because file events are applied in parallel: two downloads into the
/// same not-yet-created folder would otherwise both decide to create it, and one
/// of them would fail.
actor ParentFolderCreator {

    private let service: DropboxService
    private let database: SyncDatabase
    private let pathStore: PathStore
    private let fileOps: LocalFileOperations

    init(service: DropboxService, database: SyncDatabase, pathStore: PathStore, fileOps: LocalFileOperations) {
        self.service = service
        self.database = database
        self.pathStore = pathStore
        self.fileOps = fileOps
    }

    /// Ensures every ancestor of `dbxPathCased` exists locally and is indexed.
    func ensureParent(ofCased dbxPathCased: String) async throws {
        var components = dbxPathCased.split(separator: "/", omittingEmptySubsequences: true)
        guard components.count > 1 else { return }
        components.removeLast()

        var cased = ""
        for component in components {
            cased += "/" + component
            try await ensure(cased: cased)
        }
    }

    private func ensure(cased: String) async throws {
        let pathLower = PathStore.normalize(cased)
        let localURL = pathStore.toLocalURL(dbxPathCased: cased)
        let indexed = try database.indexEntry(forPathLower: pathLower)

        if indexed?.itemType == .folder, isDirectory(localURL) { return }

        try fileOps.makeDirectory(at: localURL)
        guard indexed == nil else { return }

        // Only an entry backed by real metadata gets an index row: a folder we
        // had to invent is one the remote will describe properly in its own
        // event, and a row with a made-up id would defeat that.
        guard let folder = try await service.metadata(path: pathLower, includeDeleted: false)?.asFolder else {
            return
        }
        try database.upsertIndexEntry(
            IndexEntry(
                dbxPathLower: pathLower,
                dbxPathCased: cased,
                dbxId: folder.id,
                itemType: .folder,
                lastSync: Date(),
                rev: ItemType.folderSentinel,
                contentHash: ItemType.folderSentinel,
                symlinkTarget: nil
            )
        )
    }

    private func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        return exists && isDirectory.boolValue
    }
}

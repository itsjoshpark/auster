import Foundation

/// Sends one local change to Dropbox (engine-doc §5.6). Much of this file is
/// about declining to act, since a wrong delete removes the authoritative copy.
/// Modified files upload with `.update(rev)`, deletes carry `parentRev` (D9).
struct UploadApplier: Sendable {

    let service: DropboxService
    let database: SyncDatabase
    let pathStore: PathStore
    let hasher: CachedContentHasher
    let fileOps: LocalFileOperations
    let events: SyncEngineEvents
    let excludedItems: @Sendable () -> Set<String>

    /// How long to wait between size samples when checking that a file has
    /// finished being written. Zero in tests, where nothing is mid-write.
    var stabilityPollInterval: Duration = .milliseconds(200)

    /// How many samples before giving up and uploading anyway. A file being
    /// appended to forever must not block the queue behind it.
    static let stabilityAttempts = 10

    /// Applies `event`, reporting what happened. Returns `.skipped` whenever the
    /// remote already says what we wanted it to, or a guard refused to act.
    @discardableResult
    func apply(_ event: SyncItemEvent) async throws -> SyncCompletion {
        if event.changeType == .removed {
            return try await applyDeletion(event)
        }

        // Both pre-checks rename the local item rather than upload it, so they
        // run before anything reaches the network.
        if let renamed = try preCheckRename(event) {
            events.rescanRequested(renamed)
            return .conflictedCopy
        }

        events.itemStarted(event)

        if event.changeType == .moved {
            return try await applyMove(event)
        }
        if event.itemType == .folder {
            return try await applyFolderCreation(event)
        }
        return try await applyFileWrite(event)
    }

    // MARK: - Pre-checks (§5.6)

    /// Moves the local item aside when its path cannot be uploaded as it stands.
    ///
    /// - Returns: the item's new location, or `nil` when the path was fine.
    private func preCheckRename(_ event: SyncItemEvent) throws -> URL? {
        guard event.changeType == .added || event.changeType == .moved else { return nil }

        if Exclusions.isExcluded(byUser: event.dbxPathLower, excluded: excludedItems()) {
            // Syncing it would contradict the user's selection; deleting it
            // would lose their work. Renaming does neither.
            return try rename(event.localURL, suffix: "selective sync conflict")
        }

        let siblings =
            (try? FileManager.default.contentsOfDirectory(
                atPath: event.localURL.deletingLastPathComponent().path
            )) ?? []
        guard
            let collision = Self.normalizationCollision(
                for: event.localURL.lastPathComponent,
                siblings: siblings
            )
        else {
            return nil
        }
        return try rename(event.localURL, suffix: collision)
    }

    /// Whether a sibling would occupy the same Dropbox path once normalised, and
    /// what to call the collision. Takes the sibling list rather than reading the
    /// directory, so the rule stays testable on a case-insensitive volume.
    static func normalizationCollision(for name: String, siblings: [String]) -> String? {
        let normalized = PathStore.normalize(name)

        for sibling in siblings where PathStore.normalize(sibling) == normalized {
            // Byte comparison, not `!=`: Swift's `String` equality is canonical
            // equivalence, so the NFD and NFC spellings of one name — exactly
            // the collision being looked for — compare as the same string.
            guard !sibling.utf8.elementsEqual(name.utf8) else { continue }
            // Equal once composed means the bytes differ only in how the same
            // characters are spelled; otherwise the difference is case.
            return PathStore.equalButForUnicodeNorm(sibling, name) ? "unicode conflict" : "case conflict"
        }
        return nil
    }

    private func rename(_ localURL: URL, suffix: String) throws -> URL {
        let destination = PathStore.conflictedCopyName(for: localURL, suffix: suffix)
        try fileOps.moveItem(from: localURL, to: destination)
        return destination
    }

    // MARK: - Files (§5.6 "File created/modified")

    private func applyFileWrite(_ event: SyncItemEvent) async throws -> SyncCompletion {
        try await waitForStableSize(at: event.localURL)

        let remote = try await service.metadata(path: event.dbxPathLower, includeDeleted: false)

        // Someone already put these exact bytes there — a second client syncing
        // the same change, or our own move handler a moment ago.
        if let remoteFile = remote?.asFile,
            remoteFile.symlinkTarget == event.symlinkTarget,
            let localHash = try hasher.localHash(at: event.localURL),
            remoteFile.contentHash == localHash
        {
            try indexFile(remoteFile, at: event.dbxPath, symlinkTarget: event.symlinkTarget)
            return .skipped
        }

        let uploaded = try await service.upload(
            from: event.localURL,
            to: event.dbxPath,
            mode: writeMode(for: event),
            autorename: true,
            clientModified: event.changeTime ?? Date()
        ) { bytes in
            events.itemProgress(event, bytes)
        }

        // The server put it somewhere else: that is a conflicted copy, and the
        // local folder has to end up looking like the remote.
        guard uploaded.pathLower == event.dbxPathLower else {
            return try mirrorServerRename(of: event, to: uploaded)
        }

        try indexFile(uploaded, at: event.dbxPath, symlinkTarget: event.symlinkTarget)
        return .done
    }

    /// The write mode is the whole safety argument for an upload (api-notes §2).
    private func writeMode(for event: SyncItemEvent) -> WriteMode {
        guard let rev = event.rev else {
            // Never synced: let the server autorename rather than overwrite
            // something we have not accounted for.
            return .add
        }
        // The index says this path held a folder, so there is no revision to
        // guard against and replacing it is the intent.
        guard rev != ItemType.folderSentinel else { return .overwrite }
        return .update(rev: rev)
    }

    /// Renames the local file to the name the server assigned it.
    private func mirrorServerRename(of event: SyncItemEvent, to uploaded: RemoteFile) throws -> SyncCompletion {
        let destination = event.localURL.deletingLastPathComponent()
            .appendingPathComponent(uploaded.name, isDirectory: false)
        try fileOps.moveItem(from: event.localURL, to: destination)

        // The old path is not ours any more; whatever is there now belongs to
        // whoever won, and the next download cycle will bring it.
        try database.removeIndexSubtree(pathLower: event.dbxPathLower)
        try indexFile(uploaded, at: uploaded.pathDisplay, symlinkTarget: event.symlinkTarget)
        events.rescanRequested(destination)
        return .conflictedCopy
    }

    /// Waits until two consecutive size samples agree. An editor writing a large
    /// file produces an event long before it has finished, and uploading then
    /// would commit a truncated version.
    private func waitForStableSize(at localURL: URL) async throws {
        var previous = fileSize(at: localURL)
        for _ in 0..<Self.stabilityAttempts {
            try await Task.sleep(for: stabilityPollInterval)
            let current = fileSize(at: localURL)
            if current == previous { return }
            previous = current
        }
    }

    private func fileSize(at localURL: URL) -> Int64 {
        let attributes = try? FileManager.default.attributesOfItem(atPath: localURL.path)
        return (attributes?[.size] as? NSNumber)?.int64Value ?? 0
    }

    // MARK: - Folders (§5.6 "Folder created")

    private func applyFolderCreation(_ event: SyncItemEvent) async throws -> SyncCompletion {
        // Both sides already having the folder is the end state we want, not a
        // collision — so it is checked for before anything is created.
        if let existing = try await service.metadata(path: event.dbxPathLower, includeDeleted: false)?
            .asFolder
        {
            try indexFolder(existing, at: event.dbxPath)
            return .skipped
        }

        let created = try await service.createFolder(path: event.dbxPath, autorename: true)
        guard created.pathLower == event.dbxPathLower else {
            // A file was in the way and the server renamed us around it.
            let destination = event.localURL.deletingLastPathComponent()
                .appendingPathComponent(created.name, isDirectory: false)
            try fileOps.moveItem(from: event.localURL, to: destination)
            try indexFolder(created, at: created.pathDisplay)
            events.rescanRequested(destination)
            return .conflictedCopy
        }

        try indexFolder(created, at: event.dbxPath)
        return .done
    }

    // MARK: - Moves (§5.6 "Item moved")

    private func applyMove(_ event: SyncItemEvent) async throws -> SyncCompletion {
        guard let from = event.dbxPathFrom, let fromLower = event.dbxPathFromLower else {
            return .skipped
        }

        // Dropbox stores NFC and macOS often reports NFD. Sending this as a move
        // would have the two sides renaming the file at each other forever.
        if PathStore.equalButForUnicodeNorm(from, event.dbxPath) {
            return .skipped
        }

        guard try await service.metadata(path: fromLower, includeDeleted: false) != nil else {
            // Nothing to move. Whatever is at the destination is new as far as
            // Dropbox is concerned, so it goes back through as a creation.
            events.rescanRequested(event.localURL)
            return .skipped
        }

        try await clearMoveDestination(event)

        let moved: RemoteMetadata
        do {
            moved = try await service.move(from: from, to: event.dbxPath, autorename: true)
        } catch DropboxServiceError.notFound {
            events.rescanRequested(event.localURL)
            return .skipped
        }

        try database.removeIndexSubtree(pathLower: fromLower)
        try await indexMoved(moved, event: event)
        return .done
    }

    /// Removes whatever occupies the move's destination, since Dropbox's move
    /// refuses to overwrite. Guarded by `parentRev` and best-effort: if the
    /// server declines, the move autorenames instead, which is safe (D9.5).
    private func clearMoveDestination(_ event: SyncItemEvent) async throws {
        guard let occupant = try database.indexEntry(forPathLower: event.dbxPathLower) else { return }
        do {
            try await service.delete(
                path: occupant.dbxPathCased,
                parentRev: occupant.itemType == .file ? occupant.rev : nil
            )
            try database.removeIndexSubtree(pathLower: event.dbxPathLower)
        } catch DropboxServiceError.notFound {
        } catch DropboxServiceError.conflict {
            // The occupant changed since we last saw it; leave it for the
            // download side to reconcile.
        }
    }

    /// Re-indexes what the move produced. A folder move relocates a whole subtree
    /// in one call, so every descendant's index row is rebuilt from the remote
    /// rather than guessed at.
    private func indexMoved(_ moved: RemoteMetadata, event: SyncItemEvent) async throws {
        if let file = moved.asFile {
            try indexFile(file, at: file.pathDisplay, symlinkTarget: event.symlinkTarget)
            return
        }
        guard let folder = moved.asFolder else { return }
        try indexFolder(folder, at: folder.pathDisplay)

        var page = try await service.listFolder(path: folder.pathLower, recursive: true)
        while true {
            for entry in page.entries {
                switch entry {
                case .file(let file):
                    try indexFile(file, at: file.pathDisplay, symlinkTarget: file.symlinkTarget)
                case .folder(let child):
                    try indexFolder(child, at: child.pathDisplay)
                case .deleted(let tombstone):
                    try database.removeIndexSubtree(pathLower: tombstone.pathLower)
                }
            }
            guard page.hasMore else { break }
            page = try await service.listFolderContinue(cursor: page.cursor)
        }
    }

    // MARK: - Deletions (§5.6 "Item deleted")

    private func applyDeletion(_ event: SyncItemEvent) async throws -> SyncCompletion {
        // The user's selection says we do not manage this path; acting on it
        // would delete something on Dropbox they never asked us to touch.
        guard !Exclusions.isExcluded(byUser: event.dbxPathLower, excluded: excludedItems()) else {
            return .skipped
        }

        let indexed = try database.indexEntry(forPathLower: event.dbxPathLower)
        guard let remote = try await service.metadata(path: event.dbxPathLower, includeDeleted: false) else {
            // Already gone. The index is the only thing left to tidy.
            try database.removeIndexSubtree(pathLower: event.dbxPathLower)
            return .skipped
        }

        // The remote is not the kind of thing we think we are deleting, which
        // means we have never seen the version that is there now.
        let remoteType: ItemType = remote.asFolder == nil ? .file : .folder
        if let indexed, indexed.itemType != remoteType {
            try database.removeIndexSubtree(pathLower: event.dbxPathLower)
            return .skipped
        }

        do {
            try await service.delete(
                path: remote.pathDisplay,
                parentRev: remoteType == .file ? indexed?.rev : nil
            )
        } catch DropboxServiceError.conflict {
            // The guard fired: the remote moved on since our last sync. Leave it
            // — the change downloads on the next cycle and the user decides.
            return .skipped
        } catch DropboxServiceError.notFound {
            try database.removeIndexSubtree(pathLower: event.dbxPathLower)
            return .skipped
        }

        try database.removeIndexSubtree(pathLower: event.dbxPathLower)
        return .done
    }

    // MARK: - Index

    private func indexFile(_ file: RemoteFile, at cased: String, symlinkTarget: String?) throws {
        try database.upsertIndexEntry(
            IndexEntry(
                dbxPathLower: PathStore.normalize(file.pathLower),
                dbxPathCased: cased,
                dbxId: file.id,
                itemType: .file,
                lastSync: Date(),
                rev: file.rev,
                contentHash: file.contentHash,
                symlinkTarget: symlinkTarget
            )
        )
    }

    private func indexFolder(_ folder: RemoteFolder, at cased: String) throws {
        try database.upsertIndexEntry(
            IndexEntry(
                dbxPathLower: PathStore.normalize(folder.pathLower),
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
}

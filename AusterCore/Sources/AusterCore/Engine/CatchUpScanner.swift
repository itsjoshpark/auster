import Foundation

/// Works out what changed while Auster was not watching (engine-doc §6).
///
/// A full walk of the local folder, diffed against the index. Moves cannot be
/// recovered this way — nothing recorded where anything went — so a rename
/// surfaces as a deletion plus a creation. That is not as lossy as it sounds:
/// the upload handler's content-equality check (§5.6) recognises the bytes
/// already on the remote and skips the transfer.
///
/// The deletions are the dangerous half. Everything the index knows but the disk
/// does not looks like the user deleting it, and a Dropbox folder that was
/// renamed or unmounted looks exactly like the user deleting *everything*. So
/// the root guard runs first and throws, rather than returning a scan that would
/// wipe the account (§9).
public enum CatchUpScanner {

    /// `localCursor` is when the last upload cycle completed; together with each
    /// item's own `last_sync` it forms the bar an mtime has to clear.
    ///
    /// - Returns: synthetic events describing the difference, ready for the same
    ///   clean → convert → apply pipeline a live batch goes through.
    /// - Throws: `SyncFatalError.dropboxFolderMissing` when the folder is gone.
    public static func scan(
        root: URL,
        database: SyncDatabase,
        pathStore: PathStore,
        localCursor: Date?
    ) throws -> [RawFSEvent] {
        // Before anything else, and before any deletion can be produced.
        try LocalFileOperations.ensurePresent(root: root)

        // Anything written after the walk began is still in flight; FSEvents
        // will report it once it settles, and reading it now risks a torn file.
        let startedAt = Date()

        var events: [RawFSEvent] = []
        var seenCasedPaths: Set<String> = []

        try walk(root: root, pathStore: pathStore) { url, isDirectory, dbxPath in
            seenCasedPaths.insert(dbxPath)
            let entry = try database.indexEntry(forPathLower: PathStore.normalize(dbxPath))

            guard let entry else {
                events.append(RawFSEvent(kind: .created, url: url, isDirectory: isDirectory))
                return
            }

            // Same path, different spelling: the user recased it. The index row
            // will report itself missing below, and this is its replacement.
            guard entry.dbxPathCased.utf8.elementsEqual(dbxPath.utf8) else {
                events.append(RawFSEvent(kind: .created, url: url, isDirectory: isDirectory))
                return
            }

            if (entry.itemType == .folder) != isDirectory {
                // "Modified" cannot say that a file became a folder.
                events.append(RawFSEvent(kind: .deleted, url: url, isDirectory: !isDirectory))
                events.append(RawFSEvent(kind: .created, url: url, isDirectory: isDirectory))
                return
            }

            // Folders have no content of their own to be modified by.
            guard !isDirectory, let mtime = modificationDate(of: url) else { return }
            let bar = [entry.lastSync, localCursor].compactMap(\.self).max() ?? .distantPast
            if mtime > bar, mtime < startedAt {
                events.append(RawFSEvent(kind: .modified, url: url, isDirectory: false))
            }
        }

        // Whatever the walk did not meet. Membership is on the *cased* path, so
        // a recasing counts as gone even on a volume that would happily answer
        // to either spelling.
        for entry in try database.allIndexEntries() where !seenCasedPaths.contains(entry.dbxPathCased) {
            events.append(
                RawFSEvent(
                    kind: .deleted,
                    url: pathStore.toLocalURL(dbxPathCased: entry.dbxPathCased),
                    isDirectory: entry.itemType == .folder
                )
            )
        }

        return events
    }

    /// Walks everything under `root` that Auster syncs, depth first.
    private static func walk(
        root: URL,
        pathStore: PathStore,
        visit: (URL, Bool, String) throws -> Void
    ) throws {
        var pending = [root]

        while let directory = pending.popLast() {
            for child in DirectoryListing.children(of: directory) {
                // Skips junk, editor scratch files, and the engine's own staging
                // directory — which lives inside the folder being walked.
                guard !Exclusions.isExcludedName(child.url.lastPathComponent) else { continue }
                guard let dbxPath = try? pathStore.toDbxPath(localURL: child.url) else { continue }

                try visit(child.url, child.isDirectory, dbxPath)
                if child.isDirectory { pending.append(child.url) }
            }
        }
    }

    private static func modificationDate(of url: URL) -> Date? {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return attributes?[.modificationDate] as? Date
    }
}

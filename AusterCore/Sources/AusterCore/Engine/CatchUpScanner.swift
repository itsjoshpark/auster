import Foundation

/// Works out what changed while Auster was not watching (engine-doc §6): a full
/// walk diffed against the index, where a rename surfaces as a delete plus a
/// create. The root guard runs first, or a moved folder would wipe the account.
public enum CatchUpScanner {

    /// `localCursor` is when the last upload cycle completed; with each item's
    /// `last_sync` it is the bar an mtime has to clear. Returns synthetic events;
    /// throws `SyncFatalError.dropboxFolderMissing` when the folder is gone.
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

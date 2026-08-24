import Foundation

/// What to do with an incoming remote change (engine-doc §4.4).
public enum DownloadConflict: Sendable, Equatable {

    /// Apply the remote change: local has nothing unaccounted for.
    case remoteNewer

    /// Both sides moved on. Rename the local item to a conflicted copy, then
    /// apply the remote change at the original path — never overwrite (D9.1).
    case conflict

    /// The bytes are already on disk. Skip the transfer, but record the new
    /// revision so the next cycle does not ask again.
    case identical

    /// Local is the same or ahead. Skip entirely, and leave the index alone.
    case localNewerOrIdentical
}

/// The §4.4 decision table. The rules run cheap-to-expensive and safe-to-risky:
/// revision equality answers most events without the disk, content equality the
/// rest without the network, and only survivors ask about local edits.
public enum ConflictResolver {

    /// Decides what an incoming remote event may do to the local item. `index` is
    /// the row for the event's path (`nil` when the engine has never synced it);
    /// `database` is consulted only for outstanding upload errors.
    public static func check(
        event: SyncItemEvent,
        index: IndexEntry?,
        hasher: CachedContentHasher,
        database: SyncDatabase
    ) throws -> DownloadConflict {

        // 1. We already have this revision. Local is identical or has moved on
        //    since; either way the download would tell us nothing new.
        if let rev = event.rev, let index, index.rev == rev {
            return .localNewerOrIdentical
        }

        // 2. The bytes are already here under a different revision — a common
        //    outcome of the very first index over a folder the user already had.
        if let remoteHash = event.contentHash,
            event.symlinkTarget == symlinkTarget(at: event.localURL),
            try hasher.localHash(at: event.localURL) == remoteHash
        {
            return .identical
        }

        // 3. A local change is still waiting to be uploaded. The disk may look
        //    settled, but the version of record is not — so this is a conflict
        //    before we ever ask about timestamps.
        if try hasUnresolvedUploadError(event.dbxPathLower, database: database) {
            return .conflict
        }

        // 4. Nothing local is unaccounted for, so the remote is authoritative.
        let unsynced = try hasUnsyncedChanges(
            at: event.localURL,
            dbxPathLower: event.dbxPathLower,
            index: index,
            database: database
        )
        if !unsynced { return .remoteNewer }

        // 5. Local edits beat a remote deletion: a delete cannot be turned into
        //    a conflicted copy, and discarding the edits is not an option.
        if event.changeType == .removed {
            return .localNewerOrIdentical
        }

        // 6. Both sides changed.
        return .conflict
    }

    // MARK: - Rule 3

    private static func hasUnresolvedUploadError(
        _ dbxPathLower: String,
        database: SyncDatabase
    ) throws -> Bool {
        try database.syncErrors().contains {
            $0.direction == .up && $0.dbxPathLower == dbxPathLower
        }
    }

    // MARK: - Rule 4 (engine-doc §4.5)

    /// Whether the local item holds changes the index has not accounted for.
    ///
    /// ctime rather than mtime: it also moves for a rename or a permission
    /// change, both of which are real changes the remote does not know about.
    /// (The catch-up scan of §6 uses mtime instead, because moving a folder
    /// across volumes bumps every ctime under it at once.)
    ///
    /// A folder's own ctime is deliberately *not* consulted — it changes
    /// whenever a child is added or removed, which the recursive walk already
    /// notices, and consulting it would make almost every folder look dirty.
    static func hasUnsyncedChanges(
        at localURL: URL,
        dbxPathLower: String,
        index: IndexEntry?,
        database: SyncDatabase
    ) throws -> Bool {
        guard let status = statusOf(localURL) else {
            // Gone from disk. If the index expected it, the user deleted it, and
            // that deletion is itself an unsynced change.
            return index != nil
        }

        guard status.isDirectory else {
            // Never synced, so nothing on disk is accounted for.
            guard let index else { return true }
            return status.ctime > (index.lastSync ?? .distantPast)
        }

        // One query for the whole subtree, then a walk that touches only memory:
        // a folder deletion can span thousands of rows, and asking the database
        // per level would make the walk quadratic in the depth of the tree.
        let subtree = try database.indexEntries(underPathLower: dbxPathLower)
        return folderHasUnsyncedChanges(
            at: localURL,
            dbxPathLower: dbxPathLower,
            index: IndexSubtree(entries: subtree)
        )
    }

    /// The index rows under one folder, arranged for the walk: by path, and
    /// grouped by parent so "what does the index expect in here?" is a lookup
    /// rather than a scan.
    private struct IndexSubtree {
        var byPath: [String: IndexEntry] = [:]
        var childrenByParent: [String: Set<String>] = [:]

        init(entries: [IndexEntry]) {
            for entry in entries {
                byPath[entry.dbxPathLower] = entry
                guard let slash = entry.dbxPathLower.lastIndex(of: "/") else { continue }
                let parent = String(entry.dbxPathLower[entry.dbxPathLower.startIndex..<slash])
                childrenByParent[parent, default: []].insert(entry.dbxPathLower)
            }
        }
    }

    private static func folderHasUnsyncedChanges(
        at localURL: URL,
        dbxPathLower: String,
        index: IndexSubtree
    ) -> Bool {
        var seenPathsLower: Set<String> = []

        for child in DirectoryListing.children(of: localURL).map(\.url) {
            let name = child.lastPathComponent
            guard !Exclusions.isExcludedName(name) else { continue }

            let childPathLower = PathStore.normalize(dbxPathLower + "/" + name)
            seenPathsLower.insert(childPathLower)

            // Vanished between the listing and the stat; the next cycle sees it.
            guard let status = statusOf(child) else { continue }

            if status.isDirectory {
                if folderHasUnsyncedChanges(at: child, dbxPathLower: childPathLower, index: index) {
                    return true
                }
            } else {
                guard let entry = index.byPath[childPathLower] else { return true }
                if status.ctime > (entry.lastSync ?? .distantPast) { return true }
            }
        }

        // Children the index expects but the disk no longer has. The walk above
        // cannot see these — there is nothing there to walk.
        let expected = index.childrenByParent[dbxPathLower] ?? []
        return !expected.isSubset(of: seenPathsLower)
    }

    // MARK: - Filesystem probes

    private struct LocalStatus {
        var isDirectory: Bool
        var ctime: Date
    }

    /// `lstat`, not `FileManager`: ctime is the whole point here and
    /// `attributesOfItem` does not report it. Symlinks are not followed — a link
    /// is an item in its own right.
    private static func statusOf(_ url: URL) -> LocalStatus? {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return nil }
        return LocalStatus(
            isDirectory: (info.st_mode & S_IFMT) == S_IFDIR,
            ctime: Date(
                timeIntervalSince1970: Double(info.st_ctimespec.tv_sec)
                    + Double(info.st_ctimespec.tv_nsec) / 1_000_000_000
            )
        )
    }

    private static func symlinkTarget(at url: URL) -> String? {
        try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)
    }

}

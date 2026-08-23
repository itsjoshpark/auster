import Foundation

/// Collapses a page of Dropbox changes to at most one event per path
/// (engine-doc §4.2).
///
/// Dropbox only promises that applying a delta's entries *in order* reproduces
/// server state, and a busy page can carry a dozen writes to the same file.
/// Applying every one of them would download the same path repeatedly, so only
/// the last survives — with one exception, which is the whole reason this is not
/// a one-line `Dictionary(_:uniquingKeysWith:)`: if the surviving entry is a
/// different *kind* of thing than the index has, the old item has to be deleted
/// first, or the new one would find a directory (or a file) in its way.
public enum RemoteChangeCleaner {

    /// - Returns: the surviving entries, in the order of each path's last
    ///   occurrence, with synthetic tombstones inserted ahead of type changes.
    ///   Ordering by depth is the caller's job (§4.3).
    public static func clean(_ entries: [RemoteMetadata], index: SyncDatabase) throws -> [RemoteMetadata] {
        // Two passes rather than one: the winner for each path has to be known
        // before any of them are emitted, and the emission order has to follow
        // where those winners appeared.
        var lastIndexForPath: [String: Int] = [:]
        for (offset, entry) in entries.enumerated() {
            lastIndexForPath[PathStore.normalize(entry.pathLower)] = offset
        }

        var cleaned: [RemoteMetadata] = []
        cleaned.reserveCapacity(entries.count)

        for (offset, entry) in entries.enumerated() {
            let pathLower = PathStore.normalize(entry.pathLower)
            guard lastIndexForPath[pathLower] == offset else { continue }

            if let tombstone = try syntheticDeletion(before: entry, pathLower: pathLower, index: index) {
                cleaned.append(tombstone)
            }
            cleaned.append(entry)
        }

        return cleaned
    }

    /// The tombstone that has to precede `entry`, or `nil` when the index agrees
    /// with it about what lives at that path.
    ///
    /// The tombstone describes the item the *index* knows, casing included: that
    /// casing is what the local delete checks itself against before removing
    /// anything (§4.8).
    private static func syntheticDeletion(
        before entry: RemoteMetadata,
        pathLower: String,
        index: SyncDatabase
    ) throws -> RemoteMetadata? {
        // A tombstone already removes whatever is there, whatever its type.
        guard !entry.isDeleted else { return nil }
        guard let existing = try index.indexEntry(forPathLower: pathLower) else { return nil }

        let incomingType: ItemType = entry.asFolder == nil ? .file : .folder
        guard existing.itemType != incomingType else { return nil }

        let name = String(existing.dbxPathCased.split(separator: "/").last ?? "")
        return .deleted(
            RemoteDeleted(
                name: name,
                pathLower: existing.dbxPathLower,
                pathDisplay: existing.dbxPathCased
            )
        )
    }
}

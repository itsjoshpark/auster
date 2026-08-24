import Foundation

/// Collapses a page of Dropbox changes to at most one event per path
/// (engine-doc §4.2). Only the last write to a path survives — unless it is a
/// different kind of thing than the index has, which needs a delete first.
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
    /// about what lives at that path. It describes the item the index knows,
    /// casing included, which the local delete checks itself against (§4.8).
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

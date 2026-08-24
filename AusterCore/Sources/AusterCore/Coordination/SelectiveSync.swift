import Foundation

/// The set algebra behind selective sync (engine-doc §8). Kept apart from the
/// machinery that acts on it: the arithmetic is pure and exhaustively testable,
/// while `SyncCoordinator` owns the consequences for the user's files.
public enum SelectiveSync {

    /// What changing the selection implies.
    public struct Delta: Sendable, Equatable {

        /// The selection to persist: normalized and minimal.
        public var excluded: Set<String>

        /// Paths that were syncing and now must not be — delete locally, prune
        /// from the index.
        public var newlyExcluded: [String]

        /// Paths that were excluded and now must sync — enqueue for download.
        public var newlyIncluded: [String]

        public init(excluded: Set<String>, newlyExcluded: [String], newlyIncluded: [String]) {
            self.excluded = excluded
            self.newlyExcluded = newlyExcluded
            self.newlyIncluded = newlyIncluded
        }

        /// Whether anything has to happen at all.
        public var isEmpty: Bool {
            newlyExcluded.isEmpty && newlyIncluded.isEmpty
        }
    }

    /// The canonical form of a requested selection: normalized paths, no root,
    /// and no entry already covered by another. Minimality bounds the set the
    /// exclusion check scans, and makes the delta below well-defined.
    public static func normalized(_ items: Set<String>) -> Set<String> {
        // The root is not a path the user may exclude (ux §5): excluding it
        // would mean excluding the account, which is what unlinking is for.
        let candidates = Set(
            items
                .map(PathStore.normalize)
                .map(trimmingTrailingSlash)
                .filter { $0 != "" && $0 != "/" }
        )

        return candidates.filter { path in
            !candidates.contains { other in other != path && path.hasPrefix(other + "/") }
        }
    }

    /// What has to change to get from `current` to `requested`. Both sides are
    /// canonicalized first, so the delta is between meanings rather than
    /// spellings: excluding an already-excluded folder is a no-op.
    public static func delta(current: Set<String>, requested: Set<String>) -> Delta {
        let before = normalized(current)
        let after = normalized(requested)

        // "Newly excluded" is about coverage, not membership: a path that was
        // already inside an excluded folder is not newly anything.
        let newlyExcluded =
            after
            .filter { !Exclusions.isExcluded(byUser: $0, excluded: before) }
            .sorted()

        // And symmetrically: an entry that survives in the new selection — or
        // is covered by a broader one — has nothing to fetch.
        let newlyIncluded =
            before
            .filter { !Exclusions.isExcluded(byUser: $0, excluded: after) }
            .sorted()

        return Delta(excluded: after, newlyExcluded: newlyExcluded, newlyIncluded: newlyIncluded)
    }

    private static func trimmingTrailingSlash(_ path: String) -> String {
        guard path.count > 1, path.hasSuffix("/") else { return path }
        return String(path.dropLast())
    }
}

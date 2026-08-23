import Foundation

/// The set algebra behind selective sync (engine-doc §8).
///
/// Kept apart from the machinery that acts on it because the two fail in
/// different ways: getting the arithmetic wrong silently syncs the wrong
/// folders, while getting the *application* wrong touches the user's files. The
/// arithmetic is pure, total, and exhaustively testable; `SyncCoordinator` owns
/// the consequences.
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
    /// and no entry already covered by another.
    ///
    /// Minimality is not cosmetic. `Exclusions.isExcluded(byUser:excluded:)`
    /// scans the whole set for every path the engine considers, and a set that
    /// accumulated every descendant the user ever unchecked would grow without
    /// bound. It also makes the delta below well-defined: two selections that
    /// exclude the same files have the same canonical form.
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

    /// What has to change to get from `current` to `requested`.
    ///
    /// Both sides are canonicalized first, so a delta is computed between
    /// meanings rather than between spellings — asking to exclude a folder that
    /// is already inside an excluded one is correctly a no-op.
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

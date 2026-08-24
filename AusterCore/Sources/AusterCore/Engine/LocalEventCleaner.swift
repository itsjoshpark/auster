import Foundation

/// Collapses a raw FSEvents batch into one intent per path (engine-doc §5.3).
/// Replaying an editor's atomic save literally would delete the user's file and
/// upload a new one, losing its revision history for what was only an edit.
public enum LocalEventCleaner {

    /// `events` is the raw batch in delivery order; `isExcluded` stops a rename
    /// across the sync boundary being recombined; `requestRescan` is called for a
    /// path whose events cancelled out. At most one event per path comes back.
    public static func clean(
        _ events: [RawFSEvent],
        isExcluded: (URL) -> Bool,
        requestRescan: (URL) -> Void
    ) -> [RawFSEvent] {
        let split = splitMoves(events)
        let collapsed = collapsePerPath(split.events, requestRescan: requestRescan)
        let recombined = recombineMoves(collapsed, pairs: split.pairs, isExcluded: isExcluded)
        return pruneChildren(recombined)
    }

    // MARK: - 1. Split moves

    private struct SplitResult {
        var events: [RawFSEvent]
        /// Source key → destination key, for the moves that were split.
        var pairs: [String: String]
    }

    /// A move is two facts about two paths, and the collapse works one path at a
    /// time — so it is taken apart first and put back together in stage 3.
    private static func splitMoves(_ events: [RawFSEvent]) -> SplitResult {
        var result = SplitResult(events: [], pairs: [:])
        result.events.reserveCapacity(events.count * 2)

        for event in events {
            guard case .moved(let destination) = event.kind else {
                result.events.append(event)
                continue
            }
            result.events.append(RawFSEvent(kind: .deleted, url: event.url, isDirectory: event.isDirectory))
            result.events.append(
                RawFSEvent(kind: .created, url: destination, isDirectory: event.isDirectory)
            )
            result.pairs[key(event.url)] = key(destination)
        }
        return result
    }

    // MARK: - 2. Collapse per path

    private struct PathHistory {
        var url: URL
        var events: [RawFSEvent] = []
        var creations = 0
        var deletions = 0
    }

    /// One path's outcome, plus how many raw events produced it — which is what
    /// decides whether a split move may be put back together.
    private struct CollapsedPath {
        var key: String
        var rawCount: Int
        var events: [RawFSEvent]
    }

    private static func collapsePerPath(
        _ events: [RawFSEvent],
        requestRescan: (URL) -> Void
    ) -> [CollapsedPath] {
        var histories: [String: PathHistory] = [:]
        // Output order follows each path's first appearance, so a batch that was
        // already sensible stays in the order it arrived.
        var order: [String] = []

        for event in events {
            let pathKey = key(event.url)
            if histories[pathKey] == nil {
                histories[pathKey] = PathHistory(url: event.url)
                order.append(pathKey)
            }
            histories[pathKey]!.events.append(event)
            switch event.kind {
            case .created: histories[pathKey]!.creations += 1
            case .deleted: histories[pathKey]!.deletions += 1
            case .modified, .moved: break
            }
        }

        return order.compactMap { pathKey in
            let history = histories[pathKey]!
            let collapsed = collapse(history, requestRescan: requestRescan)
            guard !collapsed.isEmpty else { return nil }
            return CollapsedPath(key: pathKey, rawCount: history.events.count, events: collapsed)
        }
    }

    private static func collapse(_ history: PathHistory, requestRescan: (URL) -> Void) -> [RawFSEvent] {
        guard let first = history.events.first, let last = history.events.last else { return [] }

        if history.creations > history.deletions {
            return [RawFSEvent(kind: .created, url: history.url, isDirectory: last.isDirectory)]
        }
        if history.deletions > history.creations {
            // The type it *was* is what has to be deleted, not whatever briefly
            // replaced it.
            return [RawFSEvent(kind: .deleted, url: history.url, isDirectory: first.isDirectory)]
        }

        // Balanced. Which came first decides whether the item ended up back
        // where it started, or never really existed.
        guard history.creations == 0 || first.kind == .deleted else {
            // Created and removed within one batch: scratch. Except macOS can
            // deliver an atomic save's events out of order, so the path is read
            // from disk rather than believed.
            requestRescan(history.url)
            return []
        }

        guard first.isDirectory == last.isDirectory else {
            // A file became a folder or the reverse; "modified" cannot say that.
            return [
                RawFSEvent(kind: .deleted, url: history.url, isDirectory: first.isDirectory),
                RawFSEvent(kind: .created, url: history.url, isDirectory: last.isDirectory),
            ]
        }
        return [RawFSEvent(kind: .modified, url: history.url, isDirectory: last.isDirectory)]
    }

    // MARK: - 3. Recombine moves

    /// Puts a split move back together, but only when both halves came through
    /// the collapse untouched. Anything else means the batch held more than a
    /// rename, and the two halves are genuinely a deletion and a creation.
    private static func recombineMoves(
        _ collapsed: [CollapsedPath],
        pairs: [String: String],
        isExcluded: (URL) -> Bool
    ) -> [RawFSEvent] {
        var byKey: [String: CollapsedPath] = [:]
        for entry in collapsed { byKey[entry.key] = entry }

        var merged: [String: RawFSEvent] = [:]
        var dropped: Set<String> = []

        for (sourceKey, destinationKey) in pairs {
            // `rawCount == 1` is the real test: the only event on this path was
            // the half of the move we ourselves split off. Anything else means
            // the batch held more than a rename.
            guard let source = byKey[sourceKey], source.rawCount == 1,
                source.events.count == 1, source.events[0].kind == .deleted,
                let destination = byKey[destinationKey], destination.rawCount == 1,
                destination.events.count == 1, destination.events[0].kind == .created,
                !isExcluded(source.events[0].url), !isExcluded(destination.events[0].url)
            else {
                continue
            }
            merged[sourceKey] = RawFSEvent(
                kind: .moved(to: destination.events[0].url),
                url: source.events[0].url,
                isDirectory: source.events[0].isDirectory
            )
            dropped.insert(destinationKey)
        }

        return collapsed.flatMap { entry -> [RawFSEvent] in
            if dropped.contains(entry.key) { return [] }
            if let move = merged[entry.key] { return [move] }
            return entry.events
        }
    }

    // MARK: - 4. Prune children

    /// Drops the events a moved or deleted directory already accounts for.
    /// Moving or deleting a folder is one remote call that takes its whole
    /// subtree with it; leaving the children in would make thousands that fail.
    private static func pruneChildren(_ events: [RawFSEvent]) -> [RawFSEvent] {
        var movedDirectories: [[String]: [String]] = [:]
        var deletedDirectories: Set<[String]> = []

        for event in events where event.isDirectory {
            switch event.kind {
            case .moved(let destination):
                movedDirectories[components(event.url)] = components(destination)
            case .deleted:
                deletedDirectories.insert(components(event.url))
            case .created, .modified:
                break
            }
        }
        guard !movedDirectories.isEmpty || !deletedDirectories.isEmpty else { return events }

        return events.filter { event in
            !isAccountedFor(
                event,
                movedDirectories: movedDirectories,
                deletedDirectories: deletedDirectories
            )
        }
    }

    private static func isAccountedFor(
        _ event: RawFSEvent,
        movedDirectories: [[String]: [String]],
        deletedDirectories: Set<[String]>
    ) -> Bool {
        let path = components(event.url)

        switch event.kind {
        case .deleted:
            return ancestors(of: path).contains { deletedDirectories.contains($0) }

        case .moved(let destination):
            let destinationPath = components(destination)
            return ancestors(of: path).contains { ancestor in
                guard let movedTo = movedDirectories[ancestor] else { return false }
                // Only if the child landed where the parent's move would have
                // put it; a child moved elsewhere mid-operation is its own event.
                let relative = path.dropFirst(ancestor.count)
                return destinationPath == movedTo + relative
            }

        case .created, .modified:
            return false
        }
    }

    /// Every strict ancestor of a path, as component arrays.
    private static func ancestors(of path: [String]) -> [[String]] {
        guard path.count > 1 else { return [] }
        return (1..<path.count).map { Array(path.prefix($0)) }
    }

    // MARK: - Keys

    /// Component arrays rather than strings, so `A` never matches `AB`.
    private static func components(_ url: URL) -> [String] {
        url.standardizedFileURL.pathComponents
    }

    private static func key(_ url: URL) -> String {
        url.standardizedFileURL.path
    }
}

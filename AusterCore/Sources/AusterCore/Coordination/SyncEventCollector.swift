import Foundation
import Synchronization

/// Gathers what a cycle completed, so it can be reported once at the end
/// (engine-doc §10). The shared box that lets the engine accumulate items and
/// the coordinator — built after it — hand them over when the cycle finishes.
public final class SyncEventCollector: Sendable {

    private struct Storage {
        var completed: [(event: SyncItemEvent, completion: SyncCompletion)] = []
    }

    private let storage = Mutex(Storage())

    public init() {}

    public func record(_ event: SyncItemEvent, _ completion: SyncCompletion) {
        storage.withLock { $0.completed.append((event, completion)) }
    }

    /// Takes everything gathered so far and empties the box.
    func drain() -> [(event: SyncItemEvent, completion: SyncCompletion)] {
        // Named rather than `$0`: a shorthand argument is not in scope inside
        // the nested closure a `defer` body is, and compilers disagree about
        // whether to say so.
        storage.withLock { storage in
            defer { storage.completed.removeAll() }
            return storage.completed
        }
    }
}

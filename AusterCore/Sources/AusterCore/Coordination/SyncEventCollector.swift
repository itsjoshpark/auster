import Foundation
import Synchronization

/// Gathers what a cycle completed, so it can be reported once at the end
/// (engine-doc §10).
///
/// Notifications are batched per cycle — "Ada changed 12 files", not twelve
/// notifications — which means something has to accumulate items while the cycle
/// runs and hand them over when it finishes. The engine cannot: it does not know
/// where a cycle's boundaries are relative to the user's attention, and its
/// callbacks are fire-and-forget. The coordinator does, but it is built *after*
/// the engine, which already needs its callbacks. This is the shared box that
/// lets both exist.
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

import Foundation

/// How one item's sync ended.
public enum SyncCompletion: Sendable, Equatable {

    /// Applied.
    case done

    /// Nothing to do: the item was already in the state the far side asked for,
    /// or local was ahead and won.
    case skipped

    /// Applied, but the local version was preserved beside it under a
    /// conflicted-copy name first (§4.4).
    case conflictedCopy

    /// This path failed; the rest of the cycle carried on.
    case failed(SyncItemError)
}

/// What the engine tells the outside world while it works (engine-doc §10).
///
/// Callbacks rather than a stream because they are fire-and-forget status
/// reporting: nothing the engine does depends on anyone listening, and a
/// coordinator that falls behind must never be able to stall a transfer. Every
/// closure defaults to a no-op, so a test or a headless cycle can ignore all of
/// them.
public struct SyncEngineEvents: Sendable {

    /// The status line: `"Syncing…"`, `"Indexing 1,204…"`, `"Up to date"`.
    public var statusText: @Sendable (String) -> Void

    public var itemStarted: @Sendable (SyncItemEvent) -> Void

    /// Cumulative bytes transferred for an in-flight item.
    public var itemProgress: @Sendable (SyncItemEvent, Int64) -> Void

    public var itemCompleted: @Sendable (SyncItemEvent, SyncCompletion) -> Void

    /// A local path the engine changed behind the upload watcher's back — a
    /// conflicted copy — and which therefore has to be re-examined as if the
    /// user had created it (Phase 5 feeds this into the event queue).
    public var rescanRequested: @Sendable (URL) -> Void

    public init(
        statusText: @escaping @Sendable (String) -> Void = { _ in },
        itemStarted: @escaping @Sendable (SyncItemEvent) -> Void = { _ in },
        itemProgress: @escaping @Sendable (SyncItemEvent, Int64) -> Void = { _, _ in },
        itemCompleted: @escaping @Sendable (SyncItemEvent, SyncCompletion) -> Void = { _, _ in },
        rescanRequested: @escaping @Sendable (URL) -> Void = { _ in }
    ) {
        self.statusText = statusText
        self.itemStarted = itemStarted
        self.itemProgress = itemProgress
        self.itemCompleted = itemCompleted
        self.rescanRequested = rescanRequested
    }
}

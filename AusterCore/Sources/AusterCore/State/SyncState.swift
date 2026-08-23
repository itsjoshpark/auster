import Foundation
import Observation

/// One in-flight transfer, for the activity list (engine-doc §10).
public struct ActivityItem: Identifiable, Sendable, Equatable {

    /// The normalized Dropbox path — one row per item, however often it is
    /// reported.
    public var id: String

    public var dbxPath: String
    public var direction: SyncDirection
    public var completed: Int64
    public var total: Int64

    public init(id: String, dbxPath: String, direction: SyncDirection, completed: Int64, total: Int64) {
        self.id = id
        self.dbxPath = dbxPath
        self.direction = direction
        self.completed = completed
        self.total = total
    }

    /// How far along, in `0...1`. Zero for an item of unknown size, so a
    /// progress bar reads empty rather than full.
    public var fraction: Double {
        guard total > 0 else { return 0 }
        return min(1, Double(completed) / Double(total))
    }
}

/// Everything the interface reads, and the only thing it reads (design §2).
///
/// `status` is derived rather than stored. The coordinator knows several
/// independent facts — whether an account is linked, whether something failed
/// fatally, whether the user paused, whether the network is there, whether a
/// transfer is running — and each arrives from a different place at a different
/// time. Storing a single status would mean every one of those call sites had to
/// know the priority of all the others; deriving it means the priority is
/// written down once, here.
@MainActor
@Observable
public final class SyncState {

    public enum Status: Equatable {
        case needsSetup
        case connecting
        case idle
        case syncing(detail: String)
        case paused
        case fatalError(SyncFatalError)
    }

    // MARK: - Derived

    /// What Auster is doing, in the order that matters to the user.
    ///
    /// Needing setup comes first because nothing else means anything without an
    /// account. A pause outranks both syncing and connecting because it is the
    /// thing the user did and the thing they can undo — reporting "Connecting…"
    /// to someone who deliberately paused would suggest it is about to start
    /// again.
    public var status: Status {
        if !isLinked { return .needsSetup }
        if let fatalError { return .fatalError(fatalError) }
        if isPaused { return .paused }
        if let syncingDetail { return .syncing(detail: syncingDetail) }
        if !isConnected { return .connecting }
        return .idle
    }

    /// The space readout, e.g. `"12.3% of 2 TB used"`.
    public private(set) var usageText = "Usage unknown"

    // MARK: - Stored

    /// The linked account's profile, once it has been fetched. Distinct from
    /// `isLinked`: a linked account that is offline has no profile yet.
    public private(set) var account: AccountInfo?
    public private(set) var activity: [ActivityItem] = []
    public private(set) var recentChanges: [HistoryEntry] = []
    public private(set) var syncErrors: [SyncErrorEntry] = []

    private var isLinked = false
    private var fatalError: SyncFatalError?
    private var isPaused = false
    private var isConnected = true
    private var syncingDetail: String?

    public init() {}

    // MARK: - Status inputs

    /// Whether credentials exist at all.
    ///
    /// Deliberately separate from `account`: the profile can only be fetched
    /// online, and treating its absence as "not linked" would send a linked user
    /// who happens to be offline back through the setup wizard.
    public func setLinked(_ linked: Bool) {
        isLinked = linked
        if !linked { account = nil }
    }

    /// The fetched profile. Receiving one implies the account is linked; losing
    /// it does not imply the opposite — only `setLinked(false)` does.
    public func setAccount(_ account: AccountInfo?) {
        self.account = account
        if account != nil { isLinked = true }
    }

    public func setFatalError(_ error: SyncFatalError) {
        fatalError = error
    }

    public func clearFatalError() {
        fatalError = nil
    }

    /// The user's own pause, which persists across launches (ux §9).
    public func setPaused(_ paused: Bool) {
        isPaused = paused
    }

    /// Reachability. A disconnection reads as "Connecting…", never as a pause —
    /// the difference is whether Auster will resume on its own (ux §9).
    public func setConnected(_ connected: Bool) {
        isConnected = connected
    }

    public func setSyncing(detail: String) {
        syncingDetail = detail
    }

    public func setIdle() {
        syncingDetail = nil
    }

    // MARK: - Activity

    public func itemStarted(_ event: SyncItemEvent) {
        upsertActivity(event) { $0.total = event.size }
    }

    public func itemProgress(_ event: SyncItemEvent, completed: Int64) {
        upsertActivity(event) { $0.completed = completed }
    }

    public func itemCompleted(_ event: SyncItemEvent) {
        activity.removeAll { $0.id == event.dbxPathLower }
    }

    public func clearActivity() {
        activity.removeAll()
    }

    /// Updates the row for an item, adding it if it is not being tracked yet.
    ///
    /// Progress can arrive without a start — an ad-hoc fetch does not announce
    /// itself — and dropping it would leave a running transfer invisible.
    private func upsertActivity(_ event: SyncItemEvent, _ update: (inout ActivityItem) -> Void) {
        if let index = activity.firstIndex(where: { $0.id == event.dbxPathLower }) {
            update(&activity[index])
            return
        }
        var item = ActivityItem(
            id: event.dbxPathLower,
            dbxPath: event.dbxPath,
            direction: event.direction,
            completed: 0,
            total: event.size
        )
        update(&item)
        activity.append(item)
    }

    // MARK: - Lists

    public func setUsage(_ usage: SpaceUsage?) {
        guard let usage, usage.allocated > 0 else {
            // Dropbox reports an unlimited allocation as zero, and "100% used"
            // would be both alarming and false.
            usageText = "Usage unknown"
            return
        }
        let percent = String(format: "%.1f%%", usage.fraction * 100)
        let total = ByteCountFormatter.string(fromByteCount: usage.allocated, countStyle: .file)
        usageText = "\(percent) of \(total) used"
    }

    public func setRecentChanges(_ changes: [HistoryEntry]) {
        recentChanges = changes
    }

    public func setSyncErrors(_ errors: [SyncErrorEntry]) {
        syncErrors = errors
    }
}

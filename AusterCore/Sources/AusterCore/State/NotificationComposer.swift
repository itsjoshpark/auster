import Foundation

/// One notification, decided but not yet delivered.
public struct SyncNotification: Sendable, Equatable {

    /// What the notification's button does.
    public enum Action: Sendable, Equatable {

        /// Nothing to show — a fatal error is about Auster, not about a file.
        case none

        /// Select the item in Finder.
        case revealInFinder(dbxPath: String)

        /// Open a page, for items that are no longer on disk.
        case openURL(URL)
    }

    public var title: String
    public var body: String
    public var action: Action

    public init(title: String, body: String = "", action: Action = .none) {
        self.title = title
        self.body = body
        self.action = action
    }
}

/// Decides what the user is told about a sync cycle (engine-doc §10, ux §8).
///
/// Pure, and separate from the thing that posts notifications, because the hard
/// part is the judgement rather than the delivery. Three rules shape all of it:
///
/// - Only *remote* changes are announced. A user who just saved a file does not
///   need to be told they saved a file — and by construction this only ever
///   receives download batches and conflicts.
/// - A cycle is one notification, not one per file. Thirty files arriving is one
///   event to the person watching.
/// - A snooze is about noise. It silences changes and conflicts, never a failure:
///   something that is not syncing is not noise.
public struct NotificationComposer: Sendable {

    /// Where Dropbox keeps things that have been deleted (ux §8).
    public static let deletedFilesURL = URL(string: "https://www.dropbox.com/deleted_files")!

    private let ownAccountId: @Sendable () -> String?
    private let displayName: @Sendable (String) -> String?
    private let changeNotificationsSuppressed: @Sendable () -> Bool

    /// - Parameters:
    ///   - ownAccountId: the linked account, so its own edits read as "You".
    ///   - displayName: names for other people's account ids, from whatever
    ///     cache the caller keeps. Returning `nil` is fine — the notification
    ///     then says "Someone", which is true and costs no network call.
    ///   - changeNotificationsSuppressed: the snooze and the master switch,
    ///     read fresh so a snooze that starts mid-cycle still takes effect.
    public init(
        ownAccountId: @escaping @Sendable () -> String?,
        displayName: @escaping @Sendable (String) -> String? = { _ in nil },
        changeNotificationsSuppressed: @escaping @Sendable () -> Bool = { false }
    ) {
        self.ownAccountId = ownAccountId
        self.displayName = displayName
        self.changeNotificationsSuppressed = changeNotificationsSuppressed
    }

    // MARK: - Changes

    /// One notification for everything a download cycle applied.
    public func downloadBatch(_ events: [SyncItemEvent]) -> SyncNotification? {
        guard !events.isEmpty, !changeNotificationsSuppressed() else { return nil }

        if events.count == 1, let event = events.first {
            return SyncNotification(
                title: "\(actor(of: event)) \(Self.verb(event.changeType)) \(Self.name(of: event.dbxPath))",
                body: Self.parent(of: event.dbxPath),
                action: action(for: event)
            )
        }
        return batch(events)
    }

    private func batch(_ events: [SyncItemEvent]) -> SyncNotification {
        let noun = events.allSatisfy { $0.itemType == .file } ? "files" : "items"

        // Counted by *identity*, not by the name it resolves to: two people
        // Auster has no name for are still two people, and "Someone changed 2
        // files" would say otherwise.
        let authors = Set(
            events.map { event -> String in
                guard let changedBy = event.changedBy, changedBy != ownAccountId() else { return "" }
                return changedBy
            }
        )

        // Naming one person only works when there *is* one; a shared folder
        // touched by two people is "2 files changed", not a guess.
        let title =
            authors.count == 1 && !events.isEmpty
            ? "\(actor(of: events[0])) changed \(events.count) \(noun)"
            : "\(events.count) \(noun) changed"

        return SyncNotification(title: title, action: batchAction(events))
    }

    /// A conflicted copy is something the user has to look at, so it is never
    /// folded into a batch.
    public func conflict(_ event: SyncItemEvent) -> SyncNotification? {
        guard !changeNotificationsSuppressed() else { return nil }
        let name = Self.name(of: event.dbxPath)
        return SyncNotification(
            title: "Sync conflict",
            body: "\(name) was changed in two places. Auster kept both copies.",
            action: .revealInFinder(dbxPath: event.dbxPath)
        )
    }

    // MARK: - Failures

    /// Never suppressed: see the type's documentation.
    public func itemError(_ error: SyncItemError) -> SyncNotification? {
        SyncNotification(
            title: error.title,
            body: "\(Self.name(of: error.dbxPath)) — \(error.message)",
            action: .revealInFinder(dbxPath: error.dbxPath)
        )
    }

    public func fatal(_ error: SyncFatalError) -> SyncNotification? {
        SyncNotification(
            title: "Auster stopped syncing",
            body: error.errorDescription ?? "",
            action: .none
        )
    }

    // MARK: - Internals

    /// Who made a change, in the second person where that is us.
    ///
    /// Dropbox only reports an author inside shared folders. Everywhere else the
    /// absence is itself the answer: nobody but the account holder can write
    /// there, so an unattributed change is one of their own machines.
    private func actor(of event: SyncItemEvent) -> String {
        guard let changedBy = event.changedBy, changedBy != ownAccountId() else { return "You" }
        return displayName(changedBy) ?? "Someone"
    }

    private func action(for event: SyncItemEvent) -> SyncNotification.Action {
        event.changeType == .removed
            ? .openURL(Self.deletedFilesURL)
            : .revealInFinder(dbxPath: event.dbxPath)
    }

    /// Show has to land on something that exists, so a batch reveals an item
    /// that survived it — and falls back to Dropbox's own list when none did.
    private func batchAction(_ events: [SyncItemEvent]) -> SyncNotification.Action {
        guard let surviving = events.first(where: { $0.changeType != .removed }) else {
            return .openURL(Self.deletedFilesURL)
        }
        return .revealInFinder(dbxPath: surviving.dbxPath)
    }

    private static func verb(_ change: ChangeType) -> String {
        switch change {
        case .added: "added"
        case .modified: "changed"
        case .removed: "removed"
        case .moved: "moved"
        }
    }

    private static func name(of dbxPath: String) -> String {
        (dbxPath as NSString).lastPathComponent
    }

    private static func parent(of dbxPath: String) -> String {
        let parent = (dbxPath as NSString).deletingLastPathComponent
        return parent == "/" || parent.isEmpty ? "Dropbox" : parent
    }
}

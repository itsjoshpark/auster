import AppKit
import AusterCore
import Foundation
import UserNotifications

/// Delivers what `NotificationComposer` decided (ux §8).
///
/// The split is deliberate: every rule about *whether* and *what* to say lives
/// in the composer, in `AusterCore`, where it is tested; this only knows how to
/// hand a decided notification to macOS and what to do when its button is
/// pressed.
///
/// Permission is requested on the first notification rather than at launch, as
/// ux §8 asks. A permission sheet is much easier to say yes to when it arrives
/// alongside something worth being notified about.
///
/// `@unchecked Sendable` because `SyncNotifying` is called from the coordinator's
/// actor: everything mutable is behind the lock, and the delivery itself hops to
/// the main actor.
final class NotificationManager: NSObject, SyncNotifying, @unchecked Sendable {

    /// The identifiers the delegate reads back to find an action again.
    private enum Key {
        static let action = "auster.action"
        static let path = "auster.path"
        static let url = "auster.url"
    }

    private let composer: NotificationComposer
    private let center: UNUserNotificationCenter
    private let reveal: @MainActor @Sendable (String) -> Void

    private let lock = NSLock()
    private var hasRequestedPermission = false

    init(
        composer: NotificationComposer,
        center: UNUserNotificationCenter = .current(),
        reveal: @escaping @MainActor @Sendable (String) -> Void
    ) {
        self.composer = composer
        self.center = center
        self.reveal = reveal
        super.init()
        center.delegate = self
    }

    // MARK: - SyncNotifying

    func notifyDownloadBatch(_ completed: [SyncItemEvent]) {
        compose { $0.downloadBatch(completed) }
    }

    func notifyConflict(_ event: SyncItemEvent) {
        compose { $0.conflict(event) }
    }

    func notifyItemError(_ error: SyncItemError) {
        compose { $0.itemError(error) }
    }

    func notifyFatal(_ error: SyncFatalError) {
        compose { $0.fatal(error) }
    }

    /// Decides on the main actor, then delivers.
    ///
    /// The composer's inputs are `@MainActor` state in the app — the linked
    /// account, the snooze, the master switch — reached through
    /// `MainActor.assumeIsolated`. `SyncNotifying` is called from the
    /// coordinator's actor, so composing on the caller's executor runs those
    /// closures off the main actor and `assumeIsolated` traps the process. The
    /// hop has to happen before the decision, not just before the delivery.
    private func compose(_ decide: @escaping @Sendable (NotificationComposer) -> SyncNotification?) {
        let composer = composer
        Task { @MainActor in
            post(decide(composer))
        }
    }

    /// Says that a re-index is under way after the database had to be recreated
    /// (engine-doc §9).
    ///
    /// Not part of `SyncNotifying`: nothing failed, and nothing about a sync
    /// cycle happened. What it explains is why Auster is about to be busy for a
    /// while — activity with no cause is what makes a sync client look broken.
    @MainActor
    func rebuildingIndex() {
        post(
            SyncNotification(
                title: "Rebuilding sync index…",
                body: "Auster is comparing your Dropbox folder with Dropbox again. Nothing will be lost."
            )
        )
    }

    // MARK: - Delivery

    @MainActor
    private func post(_ notification: SyncNotification?) {
        guard let notification else { return }

        Task { @MainActor in
            guard await requestPermissionIfNeeded() else { return }

            let content = UNMutableNotificationContent()
            content.title = notification.title
            content.body = notification.body
            content.userInfo = Self.userInfo(for: notification.action)
            if notification.action != .none {
                content.categoryIdentifier = Self.showCategoryIdentifier
            }

            // A `nil` trigger delivers immediately; the identifier is unique so
            // one cycle never replaces the previous one's notification.
            try? await center.add(
                UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
            )
        }
    }

    /// Asks once, on the first thing worth saying.
    private func requestPermissionIfNeeded() async -> Bool {
        let shouldAsk = lock.withLock {
            defer { hasRequestedPermission = true }
            return !hasRequestedPermission
        }
        if shouldAsk {
            center.setNotificationCategories([Self.showCategory])
            return (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        }
        return await center.notificationSettings().authorizationStatus != .denied
    }

    /// One category with one button, because every action Auster offers is
    /// "show me" — the difference is only whether that means Finder or a web
    /// page, and the notification carries which.
    /// Built on demand rather than stored: `UNNotificationCategory` is not
    /// `Sendable`, and a shared instance would be a mutable global in all but
    /// name.
    private static var showCategory: UNNotificationCategory {
        UNNotificationCategory(
            identifier: showCategoryIdentifier,
            actions: [
                UNNotificationAction(identifier: "auster.show.action", title: "Show", options: [.foreground])
            ],
            intentIdentifiers: []
        )
    }

    private static let showCategoryIdentifier = "auster.show"

    private static func userInfo(for action: SyncNotification.Action) -> [String: Any] {
        switch action {
        case .none: [:]
        case .revealInFinder(let path): [Key.action: "reveal", Key.path: path]
        case .openURL(let url): [Key.action: "open", Key.url: url.absoluteString]
        }
    }
}

extension NotificationManager: UNUserNotificationCenterDelegate {

    /// Auster is a menu-bar app with no window to bring forward, so a
    /// notification arriving while it is frontmost still has to be shown.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list]
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let userInfo = response.notification.request.content.userInfo
        // Dismissing is an answer too, and not one that should open Finder.
        guard response.actionIdentifier != UNNotificationDismissActionIdentifier else { return }

        switch userInfo[Key.action] as? String {
        case "reveal":
            guard let path = userInfo[Key.path] as? String else { return }
            let reveal = self.reveal
            await MainActor.run { reveal(path) }
        case "open":
            guard let raw = userInfo[Key.url] as? String, let url = URL(string: raw) else { return }
            await MainActor.run { _ = NSWorkspace.shared.open(url) }
        default:
            return
        }
    }
}

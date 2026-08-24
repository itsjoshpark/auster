import AusterCore
import Foundation
import Observation

/// The user's preferences, as something SwiftUI can watch. `AppConfig` stays the
/// storage and is invisible to SwiftUI; this holds what the interface binds to
/// and writes each change back. Selective sync stays out of it (note N10).
@MainActor
@Observable
final class AppSettings {

    /// The storage every property here writes through to, and the value the
    /// engine is given.
    let config: AppConfig

    var dropboxFolderURL: URL? {
        didSet { config.dropboxFolderURL = dropboxFolderURL }
    }

    /// The master switch of ux §8. Never suppresses error notifications.
    var notificationsEnabled: Bool {
        didSet { config.notificationsEnabled = notificationsEnabled }
    }

    /// When the menu's snooze expires, or `nil` when not snoozed.
    var notificationsSnoozedUntil: Date? {
        didSet { config.notificationsSnoozedUntil = notificationsSnoozedUntil }
    }

    var updateCheckInterval: UpdateCheckInterval {
        didSet { config.updateCheckInterval = updateCheckInterval }
    }

    init(config: AppConfig = AppConfig()) {
        self.config = config
        dropboxFolderURL = config.dropboxFolderURL
        notificationsEnabled = config.notificationsEnabled
        notificationsSnoozedUntil = config.notificationsSnoozedUntil
        updateCheckInterval = config.updateCheckInterval
    }

    /// Whether change notifications are being held back right now. Computed from
    /// the date rather than from a timer: a snooze that expires while the app is
    /// asleep has still expired.
    var isSnoozed: Bool {
        guard let until = notificationsSnoozedUntil else { return false }
        return until > Date()
    }

    /// Holds change notifications for a while (ux §2 item 12).
    func snoozeNotifications(for duration: TimeInterval) {
        notificationsSnoozedUntil = Date().addingTimeInterval(duration)
    }

    /// Ends a snooze early, and turns the master switch back on with it — the
    /// menu offers one "Turn On Notifications", and it should mean it.
    func turnOnNotifications() {
        notificationsSnoozedUntil = nil
        notificationsEnabled = true
    }
}

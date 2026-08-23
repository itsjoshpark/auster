import AusterCore
import Foundation
import Observation

/// The user's preferences, as something SwiftUI can watch.
///
/// `AppConfig` is a `UserDefaults` façade: correct, shared with the engine, and
/// completely invisible to SwiftUI, which redraws from `@Observable` properties
/// and nothing else. This holds the handful of settings the interface actually
/// binds to, reads them once at launch, and writes each change straight back —
/// so the defaults stay the storage and this stays the notification.
///
/// Only settings the *UI* owns live here. The selective-sync exclusions
/// deliberately do not: the database is their source of truth and the coordinator
/// writes both copies (implementation note N10), so a third one would be a third
/// thing to keep in step.
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

    /// Whether change notifications are being held back right now.
    ///
    /// Computed from the date rather than from a timer: a snooze that expires
    /// while the app is asleep has still expired, and nothing has to be running
    /// for that to become true.
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

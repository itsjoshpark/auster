import Foundation

/// How often Sparkle should look for a new version (ux §6). `never` disables
/// automatic checks; the menu's "Check for Updates…" still works.
public enum UpdateCheckInterval: String, Sendable, Codable, CaseIterable {
    case daily
    case weekly
    case monthly
    case never

    /// The interval in seconds, or `nil` when automatic checks are off.
    public var duration: TimeInterval? {
        switch self {
        case .daily: 24 * 3600
        case .weekly: 7 * 24 * 3600
        case .monthly: 30 * 24 * 3600
        case .never: nil
        }
    }
}

/// The user's preferences, in `UserDefaults`.
///
/// Deliberately a thin façade rather than a stored model: every property reads
/// and writes the defaults immediately, so two `AppConfig` values over the same
/// suite can never disagree — which matters because the UI and the engine both
/// hold one.
///
/// `excludedItems` is the exception worth knowing about: the *source of truth*
/// for selective sync is the database (`StateKey.excludedItems`), because the
/// engine must not depend on the UI's copy. What lives here is a mirror kept for
/// the UI's convenience, written by the selective-sync operation alongside the
/// database.
///
/// `@unchecked Sendable` because `UserDefaults` is documented as thread-safe but
/// is not annotated as `Sendable`; nothing else here is mutable state.
public struct AppConfig: @unchecked Sendable {

    private let defaults: UserDefaults

    /// - Parameter defaults: injectable so tests get their own suite instead of
    ///   scribbling on the user's preferences.
    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    private enum Key {
        static let dropboxFolderPath = "dropboxFolderPath"
        static let excludedItems = "excludedItems"
        static let notificationsEnabled = "notificationsEnabled"
        static let notificationsSnoozedUntil = "notificationsSnoozedUntil"
        static let updateCheckInterval = "updateCheckInterval"
        static let isPaused = "isPaused"
    }

    /// The local Dropbox folder, or `nil` before onboarding has chosen one.
    ///
    /// Stored as a plain path rather than as bookmark data: the app is
    /// unsandboxed (decisions D2), so it needs no security scope, and a path
    /// stays readable and repairable if the folder is moved.
    public var dropboxFolderURL: URL? {
        get {
            defaults.string(forKey: Key.dropboxFolderPath).map { URL(fileURLWithPath: $0) }
        }
        nonmutating set {
            defaults.set(newValue?.path, forKey: Key.dropboxFolderPath)
        }
    }

    /// The selective-sync exclusions, as lowercased Dropbox paths. A UI mirror
    /// of the database's copy — see the type's documentation.
    public var excludedItems: Set<String> {
        get {
            // `array(forKey:)` is heterogeneous, and a defaults domain can be
            // edited by hand; anything that is not a string is discarded rather
            // than crashed on.
            Set(defaults.array(forKey: Key.excludedItems)?.compactMap { $0 as? String } ?? [])
        }
        nonmutating set {
            defaults.set(Array(newValue).sorted(), forKey: Key.excludedItems)
        }
    }

    /// Whether to post notifications about remote changes. On by default: a sync
    /// client that syncs silently on first run looks broken.
    public var notificationsEnabled: Bool {
        get {
            defaults.object(forKey: Key.notificationsEnabled) as? Bool ?? true
        }
        nonmutating set {
            defaults.set(newValue, forKey: Key.notificationsEnabled)
        }
    }

    /// When a snooze expires, or `nil` when not snoozed (ux §2 item 12).
    public var notificationsSnoozedUntil: Date? {
        get {
            defaults.object(forKey: Key.notificationsSnoozedUntil) as? Date
        }
        nonmutating set {
            defaults.set(newValue, forKey: Key.notificationsSnoozedUntil)
        }
    }

    public var updateCheckInterval: UpdateCheckInterval {
        get {
            defaults.string(forKey: Key.updateCheckInterval)
                .flatMap(UpdateCheckInterval.init(rawValue:)) ?? .daily
        }
        nonmutating set {
            defaults.set(newValue.rawValue, forKey: Key.updateCheckInterval)
        }
    }

    /// The user's own pause, which persists across launches (ux §9). Distinct
    /// from the automatic pause on disconnect, which is transient and never
    /// written here.
    public var isPaused: Bool {
        get {
            defaults.bool(forKey: Key.isPaused)
        }
        nonmutating set {
            defaults.set(newValue, forKey: Key.isPaused)
        }
    }
}

import Foundation
import Testing

@testable import AusterCore

/// `AppConfig` is the user's preferences, so the tests care about two things:
/// that a fresh install behaves sensibly with nothing stored, and that what the
/// user chose survives a relaunch.
@Suite("AppConfig")
struct AppConfigTests {

    /// A config over its own throwaway defaults domain, removed afterwards so
    /// suites running in parallel cannot see each other's writes.
    private func withConfig<T>(_ body: (AppConfig, UserDefaults) throws -> T) throws -> T {
        let suiteName = "auster-config-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        return try body(AppConfig(defaults: defaults), defaults)
    }

    // MARK: - Defaults

    @Test("A fresh install has no Dropbox folder chosen yet")
    func defaultFolderIsUnset() throws {
        try withConfig { config, _ in
            #expect(config.dropboxFolderURL == nil)
        }
    }

    @Test("Notifications start on")
    func defaultNotificationsEnabled() throws {
        try withConfig { config, _ in
            #expect(config.notificationsEnabled == true)
            #expect(config.notificationsSnoozedUntil == nil)
        }
    }

    @Test("A fresh install is not paused")
    func defaultNotPaused() throws {
        try withConfig { config, _ in
            #expect(config.isPaused == false)
        }
    }

    @Test("Updates are checked for daily by default")
    func defaultUpdateInterval() throws {
        try withConfig { config, _ in
            #expect(config.updateCheckInterval == .daily)
        }
    }

    @Test("Nothing is excluded by default")
    func defaultExclusions() throws {
        try withConfig { config, _ in
            #expect(config.excludedItems.isEmpty)
        }
    }

    // MARK: - Round trips

    @Test("The Dropbox folder round trips")
    func folderRoundTrip() throws {
        try withConfig { config, defaults in
            let url = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Dropbox")
            config.dropboxFolderURL = url

            #expect(AppConfig(defaults: defaults).dropboxFolderURL?.path == url.path)
        }
    }

    @Test("Clearing the Dropbox folder puts it back to unset")
    func folderCanBeCleared() throws {
        try withConfig { config, defaults in
            config.dropboxFolderURL = URL(fileURLWithPath: "/tmp/Dropbox")
            config.dropboxFolderURL = nil

            #expect(AppConfig(defaults: defaults).dropboxFolderURL == nil)
        }
    }

    @Test("A folder path containing spaces and accents survives the round trip")
    func folderWithAwkwardNameRoundTrips() throws {
        try withConfig { config, defaults in
            let url = URL(fileURLWithPath: "/Users/josh/Mon Dossier caf\u{e9}")
            config.dropboxFolderURL = url

            #expect(AppConfig(defaults: defaults).dropboxFolderURL?.path == url.path)
        }
    }

    @Test("The notifications switch round trips")
    func notificationsRoundTrip() throws {
        try withConfig { config, defaults in
            config.notificationsEnabled = false

            #expect(AppConfig(defaults: defaults).notificationsEnabled == false)
        }
    }

    @Test("A snooze deadline round trips and can be cleared")
    func snoozeRoundTrip() throws {
        try withConfig { config, defaults in
            let until = Date(timeIntervalSince1970: 1_700_000_000)
            config.notificationsSnoozedUntil = until
            #expect(AppConfig(defaults: defaults).notificationsSnoozedUntil == until)

            config.notificationsSnoozedUntil = nil
            #expect(AppConfig(defaults: defaults).notificationsSnoozedUntil == nil)
        }
    }

    @Test("The pause switch round trips — a paused app stays paused across launches")
    func pauseRoundTrip() throws {
        try withConfig { config, defaults in
            config.isPaused = true

            #expect(AppConfig(defaults: defaults).isPaused == true)
        }
    }

    @Test("The update interval round trips")
    func updateIntervalRoundTrip() throws {
        try withConfig { config, defaults in
            config.updateCheckInterval = .never

            #expect(AppConfig(defaults: defaults).updateCheckInterval == .never)
        }
    }

    @Test("An unrecognised stored update interval falls back to the default")
    func updateIntervalRejectsGarbage() throws {
        try withConfig { config, defaults in
            defaults.set("fortnightly", forKey: "updateCheckInterval")

            #expect(config.updateCheckInterval == .daily)
        }
    }

    @Test("Exclusions round trip")
    func exclusionsRoundTrip() throws {
        try withConfig { config, defaults in
            config.excludedItems = ["/photos", "/work/archive"]

            #expect(AppConfig(defaults: defaults).excludedItems == ["/photos", "/work/archive"])
        }
    }

    @Test("Emptying the exclusions is stored, not ignored")
    func exclusionsCanBeEmptied() throws {
        try withConfig { config, defaults in
            config.excludedItems = ["/photos"]
            config.excludedItems = []

            #expect(AppConfig(defaults: defaults).excludedItems.isEmpty)
        }
    }

    @Test("A non-string entry in the stored exclusions does not take the whole set down")
    func exclusionsRejectGarbage() throws {
        try withConfig { config, defaults in
            defaults.set([1, 2], forKey: "excludedItems")

            #expect(config.excludedItems.isEmpty)
        }
    }

    // MARK: - Update intervals

    @Test("Only Never has no interval, and the rest are ordered")
    func updateIntervalDurations() {
        #expect(UpdateCheckInterval.never.duration == nil)
        #expect(UpdateCheckInterval.daily.duration == TimeInterval(24 * 3600))
        #expect(UpdateCheckInterval.weekly.duration == TimeInterval(7 * 24 * 3600))
        #expect(UpdateCheckInterval.monthly.duration == TimeInterval(30 * 24 * 3600))
    }
}

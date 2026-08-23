import AusterCore
import Foundation
import Testing

@testable import Auster

/// App-target tests. The bulk of Auster's coverage lives in `AusterCoreTests`;
/// this target exists for the thin view-model layer (Phase 8) and to give the
/// `Auster` scheme a test action.
@Suite("App shell")
struct AppShellTests {

    /// A settings object over its own defaults suite, so a test never writes to
    /// the preferences of whoever is running it.
    @MainActor
    private static func isolatedSettings() -> (AppSettings, String) {
        let suiteName = "auster-app-tests-\(UUID().uuidString)"
        return (AppSettings(config: AppConfig(defaults: UserDefaults(suiteName: suiteName)!)), suiteName)
    }

    @MainActor
    @Test("The menu bar window builds")
    func menuBarViewBuilds() {
        let (settings, suiteName) = Self.isolatedSettings()
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }

        _ = MenuBarView(environment: AppEnvironment(link: LinkController(auth: nil), settings: settings))
    }

    /// Without an account there is nothing to coordinate, and the interface says
    /// so rather than showing an empty sync UI.
    @MainActor
    @Test("An environment with no account needs setting up")
    func unlinkedEnvironmentNeedsSetup() async {
        let (settings, suiteName) = Self.isolatedSettings()
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
        let environment = AppEnvironment(link: LinkController(auth: nil), settings: settings)

        await environment.start()

        #expect(environment.state.status == .needsSetup)
        #expect(environment.coordinator == nil)
    }

    /// Setup is only over once there is *also* somewhere to put the files: a
    /// linked account with no chosen folder is a half-finished wizard, not a
    /// working sync (ux §3).
    @MainActor
    @Test("An account without a chosen folder still needs setting up")
    func linkedWithoutFolderNeedsSetup() async {
        let (settings, suiteName) = Self.isolatedSettings()
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
        let environment = AppEnvironment(link: LinkController(auth: nil), settings: settings)

        #expect(settings.dropboxFolderURL == nil)
        await environment.start()

        #expect(environment.state.status == .needsSetup)
    }

    /// A snooze is a deadline, not a timer: it has expired once the time has
    /// passed, whether or not anything was running to notice (ux §2 item 12).
    @MainActor
    @Test("Snoozing suppresses notifications until its deadline passes")
    func snoozeExpiresByItself() {
        let (settings, suiteName) = Self.isolatedSettings()
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }

        #expect(!settings.isSnoozed)
        settings.snoozeNotifications(for: 1800)
        #expect(settings.isSnoozed)

        settings.notificationsSnoozedUntil = Date(timeIntervalSinceNow: -1)
        #expect(!settings.isSnoozed)

        settings.notificationsEnabled = false
        settings.snoozeNotifications(for: 1800)
        settings.turnOnNotifications()
        #expect(!settings.isSnoozed)
        #expect(settings.notificationsEnabled)
    }

    @Test("a build without a real app key is treated as having none")
    func appKeyRejectsPlaceholders() {
        #expect(AppKey.resolve(nil) == nil)
        #expect(AppKey.resolve("") == nil)
        #expect(AppKey.resolve("   ") == nil)
        #expect(AppKey.resolve("your_dropbox_app_key_here") == nil)
    }

    @Test("a real app key is trimmed and used as the OAuth redirect scheme")
    func appKeyIsUsable() {
        #expect(AppKey.resolve("  abc123  ") == "abc123")
    }

    /// Skipped where the build has no key: `Config/Secrets.xcconfig` is
    /// gitignored, so CI never has one. Where a key *is* configured, this proves
    /// the xcconfig reached both `Info.plist` entries — the value Auster reads
    /// and the `db-` scheme the OAuth redirect comes back on.
    @Test(
        "a configured app key reaches the built bundle",
        .enabled(if: AppKey.value != nil)
    )
    func bundleCarriesAppKey() throws {
        let key = try #require(AppKey.value)
        #expect(AppKey.redirectScheme == "db-\(key)")
    }
}

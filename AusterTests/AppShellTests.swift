import Foundation
import Testing

@testable import Auster

/// App-target tests. The bulk of Auster's coverage lives in `AusterCoreTests`;
/// this target exists for the thin view-model layer (Phase 8) and to give the
/// `Auster` scheme a test action.
@Suite("App shell")
struct AppShellTests {

    @MainActor
    @Test("Menu bar placeholder builds")
    func menuBarContentViewBuilds() {
        _ = MenuBarContentView(link: LinkController(auth: nil))
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

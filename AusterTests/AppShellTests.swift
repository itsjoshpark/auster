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

    @MainActor
    @Test("the app is built with a Dropbox app key")
    func bundleCarriesAppKey() throws {
        // Fails when Config/Secrets.xcconfig is missing, which is the one
        // misconfiguration that silently disables linking.
        let key = try #require(AppKey.value, "set DROPBOX_APP_KEY in Config/Secrets.xcconfig")
        #expect(AppKey.redirectScheme == "db-\(key)")
    }
}

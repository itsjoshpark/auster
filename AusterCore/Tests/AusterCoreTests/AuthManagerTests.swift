import Foundation
import Testing

@testable import AusterCore

/// Linking is the one place where a wrong answer is unrecoverable: a team
/// account that slipped through would have the engine syncing against a
/// namespace Auster does not understand (decisions D4).
@MainActor
@Suite("AuthManager")
struct AuthManagerTests {

    // MARK: - Doubles

    private final class FakeLinkStore: DropboxLinkStore, @unchecked Sendable {
        var authorizationResult: AuthorizationResult = .authorized
        var serviceAfterAuthorization = MockDropboxService()
        var stored: MockDropboxService?

        /// Simulates authorizing and then finding nothing usable in the keychain.
        var suppressService = false

        private(set) var requestedScopes: [String]?
        private(set) var clearCount = 0

        func storedService() async -> (any DropboxService)? { stored }

        func beginAuthorization(scopes: [String]) { requestedScopes = scopes }

        func completeAuthorization(url: URL) async -> AuthorizationResult {
            if case .authorized = authorizationResult, !suppressService {
                stored = serviceAfterAuthorization
            }
            return authorizationResult
        }

        func clearCredentials() {
            clearCount += 1
            stored = nil
        }
    }

    private let redirect = URL(string: "db-appkey://2/token?code=abc")!

    private func personal(_ mock: MockDropboxService) {
        mock.account = AccountInfo(
            accountId: "dbid:josh",
            displayName: "Josh Park",
            email: "josh@example.com",
            accountType: "pro",
            isTeam: false,
            profilePhotoURL: nil
        )
    }

    private func team(_ mock: MockDropboxService) {
        mock.account = AccountInfo(
            accountId: "dbid:team",
            displayName: "Work Account",
            email: "josh@work.example.com",
            accountType: "business",
            isTeam: true,
            profilePhotoURL: nil
        )
    }

    // MARK: - Starting a link

    @Test("a fresh manager is unlinked and has no service")
    func startsUnlinked() {
        let manager = AuthManager(store: FakeLinkStore())
        #expect(!manager.isLinked)
        #expect(manager.account == nil)
        #expect(manager.service == nil)
    }

    @Test("beginning a link requests exactly the scopes the app was registered for")
    func beginLinkRequestsScopes() {
        let store = FakeLinkStore()
        let manager = AuthManager(store: store)

        manager.beginLink()

        #expect(
            store.requestedScopes == [
                "account_info.read",
                "files.metadata.read",
                "files.content.read",
                "files.content.write",
            ]
        )
    }

    // MARK: - Completing a link

    @Test("a successful redirect links the account and exposes a service")
    func linksPersonalAccount() async {
        let store = FakeLinkStore()
        personal(store.serviceAfterAuthorization)
        let manager = AuthManager(store: store)

        let outcome = await manager.handleRedirect(url: redirect)

        #expect(outcome == .linked(store.serviceAfterAuthorization.account))
        #expect(manager.isLinked)
        #expect(manager.account?.email == "josh@example.com")
        #expect(manager.service != nil)
        #expect(store.clearCount == 0)
    }

    @Test("a team account is rejected and its credentials are discarded")
    func rejectsTeamAccount() async {
        let store = FakeLinkStore()
        team(store.serviceAfterAuthorization)
        let manager = AuthManager(store: store)

        let outcome = await manager.handleRedirect(url: redirect)

        #expect(outcome == .teamAccountNotSupported)
        #expect(!manager.isLinked)
        #expect(manager.account == nil)
        #expect(manager.service == nil)
        #expect(store.clearCount == 1)
        // The grant is handed back rather than left dangling on Josh's account.
        #expect(store.serviceAfterAuthorization.recordedCalls.contains(.revokeToken))
    }

    @Test("a cancelled authorization leaves the manager unlinked and silent")
    func cancellation() async {
        let store = FakeLinkStore()
        store.authorizationResult = .cancelled
        let manager = AuthManager(store: store)

        #expect(await manager.handleRedirect(url: redirect) == .cancelled)
        #expect(!manager.isLinked)
        #expect(store.clearCount == 0)
    }

    @Test("a URL that is not ours is ignored rather than reported as an error")
    func unrecognizedURL() async {
        let store = FakeLinkStore()
        store.authorizationResult = .unrecognizedURL
        let manager = AuthManager(store: store)

        #expect(await manager.handleRedirect(url: redirect) == .cancelled)
        #expect(!manager.isLinked)
    }

    @Test("an authorization error is reported with the server's message")
    func authorizationFailure() async {
        let store = FakeLinkStore()
        store.authorizationResult = .failed("access_denied")
        let manager = AuthManager(store: store)

        #expect(await manager.handleRedirect(url: redirect) == .failed("access_denied"))
        #expect(!manager.isLinked)
    }

    @Test("a failure to read the account after authorizing discards the credentials")
    func accountFetchFailureUnlinks() async {
        let store = FakeLinkStore()
        personal(store.serviceAfterAuthorization)
        store.serviceAfterAuthorization.failNext(.currentAccount, with: .connection)
        let manager = AuthManager(store: store)

        let outcome = await manager.handleRedirect(url: redirect)

        guard case .failed = outcome else {
            Issue.record("expected .failed, got \(outcome)")
            return
        }
        #expect(!manager.isLinked)
        #expect(store.clearCount == 1)
    }

    @Test("authorizing without any usable credentials fails rather than half-linking")
    func missingServiceFails() async {
        let store = FakeLinkStore()
        store.suppressService = true
        let manager = AuthManager(store: store)

        let outcome = await manager.handleRedirect(url: redirect)

        guard case .failed = outcome else {
            Issue.record("expected .failed, got \(outcome)")
            return
        }
        #expect(!manager.isLinked)
        #expect(manager.service == nil)
    }

    // MARK: - Unlinking

    @Test("unlinking revokes the token and clears the stored credentials")
    func unlink() async {
        let store = FakeLinkStore()
        personal(store.serviceAfterAuthorization)
        let manager = AuthManager(store: store)
        _ = await manager.handleRedirect(url: redirect)

        await manager.unlink()

        #expect(store.serviceAfterAuthorization.recordedCalls.contains(.revokeToken))
        #expect(store.clearCount == 1)
        #expect(!manager.isLinked)
        #expect(manager.account == nil)
        #expect(manager.service == nil)
    }

    @Test("unlinking clears credentials even when revoking the token fails")
    func unlinkSurvivesRevokeFailure() async {
        let store = FakeLinkStore()
        personal(store.serviceAfterAuthorization)
        let manager = AuthManager(store: store)
        _ = await manager.handleRedirect(url: redirect)
        store.serviceAfterAuthorization.failNext(.revokeToken, with: .connection)

        await manager.unlink()

        #expect(store.clearCount == 1)
        #expect(!manager.isLinked)
    }

    @Test("unlinking when nothing is linked is a no-op that still clears the store")
    func unlinkWhenUnlinked() async {
        let store = FakeLinkStore()
        let manager = AuthManager(store: store)

        await manager.unlink()

        #expect(store.clearCount == 1)
        #expect(!manager.isLinked)
    }

    // MARK: - Restoring at launch

    @Test("a stored link is restored without another trip through the browser")
    func restoresStoredLink() async {
        let store = FakeLinkStore()
        personal(store.serviceAfterAuthorization)
        store.stored = store.serviceAfterAuthorization
        let manager = AuthManager(store: store)

        await manager.restore()

        #expect(manager.isLinked)
        #expect(manager.account?.email == "josh@example.com")
        #expect(store.requestedScopes == nil)
    }

    @Test("nothing stored means nothing restored")
    func restoreWithoutCredentials() async {
        let store = FakeLinkStore()
        let manager = AuthManager(store: store)

        await manager.restore()

        #expect(!manager.isLinked)
        #expect(manager.account == nil)
    }

    @Test("a stored team account is discarded on restore, not honored")
    func restoreRejectsTeamAccount() async {
        let store = FakeLinkStore()
        team(store.serviceAfterAuthorization)
        store.stored = store.serviceAfterAuthorization
        let manager = AuthManager(store: store)

        await manager.restore()

        #expect(!manager.isLinked)
        #expect(store.clearCount == 1)
        #expect(store.serviceAfterAuthorization.recordedCalls.contains(.revokeToken))
    }

    @Test("an unreachable Dropbox at launch leaves the link intact for a later retry")
    func restoreSurvivesOfflineLaunch() async {
        let store = FakeLinkStore()
        personal(store.serviceAfterAuthorization)
        store.stored = store.serviceAfterAuthorization
        store.serviceAfterAuthorization.failNext(.currentAccount, with: .connection)
        let manager = AuthManager(store: store)

        await manager.restore()

        // Still linked: being offline is not the same as being unlinked.
        #expect(manager.isLinked)
        #expect(manager.account == nil)
        #expect(store.clearCount == 0)
    }

    @Test("an invalid token at launch unlinks, because only re-linking fixes it")
    func restoreUnlinksOnRevokedToken() async {
        let store = FakeLinkStore()
        personal(store.serviceAfterAuthorization)
        store.stored = store.serviceAfterAuthorization
        store.serviceAfterAuthorization.failNext(.currentAccount, with: .notAuthorized)
        let manager = AuthManager(store: store)

        await manager.restore()

        #expect(!manager.isLinked)
        #expect(store.clearCount == 1)
    }
}

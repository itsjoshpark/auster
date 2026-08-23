import Foundation
import SwiftyDropbox

/// The outcome of consuming an OAuth redirect, before Auster has decided what
/// it means for the account.
public enum AuthorizationResult: Equatable, Sendable {

    /// Credentials were stored. Whether the account is usable is a separate
    /// question — see `AuthManager.handleRedirect`.
    case authorized

    /// The user backed out of the Dropbox authorization page.
    case cancelled

    /// The URL was not one of ours. Nothing happened.
    case unrecognizedURL

    /// The server refused, with its own explanation.
    case failed(String)
}

/// Where Auster's Dropbox credentials live, and how a link is started and
/// finished.
///
/// This exists so `AuthManager`'s decision-making — which is where a mistake
/// costs the user something — is testable without a browser, a keychain or a
/// network. `KeychainDropboxLinkStore` is the real one.
@MainActor
public protocol DropboxLinkStore: AnyObject {

    /// Whether a previous link left usable credentials behind.
    var hasStoredCredentials: Bool { get }

    /// A service built on the stored credentials, or `nil` if there are none.
    func makeService() -> (any DropboxService)?

    /// Opens the Dropbox authorization page. The answer arrives later, as a
    /// redirect back into the app.
    func beginAuthorization(scopes: [String])

    /// Consumes a redirect URL, storing credentials if it carries any.
    func completeAuthorization(url: URL) async -> AuthorizationResult

    /// Forgets the stored credentials. Does not revoke them server-side.
    func clearCredentials()
}

/// The real store: SwiftyDropbox's PKCE flow, with tokens in the macOS keychain.
///
/// It deliberately owns its own `DropboxOAuthManager` rather than going through
/// `DropboxClientsManager`. The manager's `authorizedClient` is a mutable global
/// that Swift 6 refuses to let us read (decisions N4), and an instance we own
/// gives the same keychain-backed behaviour with none of that.
@MainActor
public final class KeychainDropboxLinkStore: DropboxLinkStore {

    private let oauth: DropboxOAuthManager
    private let application: any SharedApplication
    private let serviceFactory: @MainActor (DropboxClient) -> any DropboxService

    /// - Parameters:
    ///   - appKey: the Dropbox app key. Also fixes the `db-<key>` redirect scheme.
    ///   - presenter: opens URLs and shows errors; implemented by the app target,
    ///     because that is the only layer allowed to touch AppKit.
    public init(
        appKey: String,
        presenter: any AuthorizationPresenter,
        serviceFactory: @escaping @MainActor (DropboxClient) -> any DropboxService = {
            LiveDropboxService(client: $0)
        }
    ) {
        oauth = DropboxOAuthManager(appKey: appKey, secureStorageAccess: SecureStorageAccessDefaultImpl())
        application = SharedApplicationBridge(presenter: presenter)
        self.serviceFactory = serviceFactory
    }

    public var hasStoredCredentials: Bool {
        oauth.hasStoredAccessTokens()
    }

    public func makeService() -> (any DropboxService)? {
        guard let token = oauth.getFirstAccessToken() else { return nil }
        // Built from the token *and* the manager, so the client refreshes the
        // short-lived access token by itself.
        return serviceFactory(DropboxClient(accessToken: token, dropboxOauthManager: oauth))
    }

    public func beginAuthorization(scopes: [String]) {
        oauth.authorizeFromSharedApplication(
            application,
            usePKCE: true,
            scopeRequest: ScopeRequest(scopeType: .user, scopes: scopes, includeGrantedScopes: false)
        )
    }

    public func completeAuthorization(url: URL) async -> AuthorizationResult {
        await withCheckedContinuation { continuation in
            // The SDK calls this back exactly once, including for URLs it does
            // not recognise, so the continuation is always resumed.
            _ = oauth.handleRedirectURL(url) { result in
                switch result {
                case .success:
                    continuation.resume(returning: .authorized)
                case .cancel:
                    continuation.resume(returning: .cancelled)
                case .error(let error, let message):
                    continuation.resume(returning: .failed(message ?? "\(error)"))
                case .none:
                    continuation.resume(returning: .unrecognizedURL)
                }
            }
        }
    }

    public func clearCredentials() {
        _ = oauth.clearStoredAccessTokens()
    }
}

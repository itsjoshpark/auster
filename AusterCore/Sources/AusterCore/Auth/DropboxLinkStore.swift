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
/// finished. A protocol so `AuthManager`'s decisions are testable without a
/// browser, a keychain or a network; `KeychainDropboxLinkStore` is the real one.
public protocol DropboxLinkStore: AnyObject, Sendable {

    /// A service built on the stored credentials, or `nil` if there are none.
    ///
    /// Off the main actor deliberately: reading them touches the keychain, which
    /// blocks until the user answers a permission prompt (note N43).
    func storedService() async -> (any DropboxService)?

    /// Opens the Dropbox authorization page. The answer arrives later, as a
    /// redirect back into the app.
    @MainActor func beginAuthorization(scopes: [String])

    /// Consumes a redirect URL, storing credentials if it carries any.
    func completeAuthorization(url: URL) async -> AuthorizationResult

    /// Forgets the stored credentials. Does not revoke them server-side.
    @MainActor func clearCredentials()
}

/// The real store: SwiftyDropbox's PKCE flow, with tokens in the macOS keychain.
/// It owns its own `DropboxOAuthManager` because `DropboxClientsManager`'s is a
/// mutable global that Swift 6 refuses to let us read (decisions N4).
///
/// `@unchecked Sendable`: everything it holds is immutable after `init`, and the
/// keychain calls underneath `DropboxOAuthManager` are `SecItem*`, which are
/// themselves thread-safe.
public final class KeychainDropboxLinkStore: DropboxLinkStore, @unchecked Sendable {

    private let oauth: DropboxOAuthManager
    private let application: any SharedApplication
    private let serviceFactory: @Sendable (DropboxClient) -> any DropboxService

    /// `appKey` also fixes the `db-<key>` redirect scheme. `presenter` opens URLs
    /// and shows errors; the app target implements it, because that is the only
    /// layer allowed to touch AppKit.
    public init(
        appKey: String,
        presenter: any AuthorizationPresenter,
        serviceFactory: @escaping @Sendable (DropboxClient) -> any DropboxService = {
            LiveDropboxService(client: $0)
        }
    ) {
        oauth = DropboxOAuthManager(appKey: appKey, secureStorageAccess: SecureStorageAccessDefaultImpl())
        application = SharedApplicationBridge(presenter: presenter)
        self.serviceFactory = serviceFactory
    }

    /// Read on a detached task: a keychain prompt parks whatever thread asks,
    /// and on the main actor that is the menu bar icon, the windows and the
    /// engine all at once (note N43).
    public func storedService() async -> (any DropboxService)? {
        let oauth = oauth
        let serviceFactory = serviceFactory
        return await Task.detached(priority: .userInitiated) {
            guard let token = oauth.getFirstAccessToken() else { return nil }
            // Built from the token *and* the manager, so the client refreshes
            // the short-lived access token by itself.
            return serviceFactory(DropboxClient(accessToken: token, dropboxOauthManager: oauth))
        }.value
    }

    @MainActor public func beginAuthorization(scopes: [String]) {
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

    @MainActor public func clearCredentials() {
        _ = oauth.clearStoredAccessTokens()
    }
}

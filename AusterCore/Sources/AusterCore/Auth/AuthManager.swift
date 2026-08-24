import Foundation
import Observation

/// What came of an attempt to link a Dropbox account.
public enum LinkOutcome: Equatable, Sendable {

    /// Linked, and the account is one Auster can sync.
    case linked(AccountInfo)

    /// The user backed out, or the redirect was not ours. Nothing to report.
    case cancelled

    /// A Dropbox team account. Permanently out of scope (decisions D4), so the
    /// credentials are discarded rather than kept for later.
    case teamAccountNotSupported

    /// Something went wrong, described for the user.
    case failed(String)
}

/// Owns whether Auster is linked to a Dropbox account, and the service that
/// speaks for it. Thin by design: what lives here is the part with consequences
/// — refusing team accounts, and never leaving the app half-linked.
@MainActor
@Observable
public final class AuthManager {

    /// The scopes Auster's Dropbox app is registered for (decisions D3).
    /// Requested verbatim: a mismatch here fails the link at the server.
    public static let scopes = [
        "account_info.read",
        "files.metadata.read",
        "files.content.read",
        "files.content.write",
    ]

    /// Whether a usable account is linked right now.
    public private(set) var isLinked = false

    /// The linked account, once it has been read. `nil` while unlinked, and also
    /// while linked-but-offline.
    public private(set) var account: AccountInfo?

    /// The service the engine should use. `nil` exactly when unlinked.
    public private(set) var service: (any DropboxService)?

    private let store: any DropboxLinkStore

    public init(store: any DropboxLinkStore) {
        self.store = store
    }

    /// Opens the Dropbox authorization page in the browser.
    ///
    /// Returns immediately; the answer arrives at `handleRedirect(url:)`.
    public func beginLink() {
        store.beginAuthorization(scopes: Self.scopes)
    }

    /// Consumes an OAuth redirect and decides what it means. Anything short of a
    /// linked personal account leaves the app unlinked with no credentials on
    /// disk: a half-linked state is worse than making the user try again.
    @discardableResult
    public func handleRedirect(url: URL) async -> LinkOutcome {
        switch await store.completeAuthorization(url: url) {
        case .cancelled, .unrecognizedURL:
            // A URL that was not ours is not a failure worth showing anyone.
            return .cancelled

        case .failed(let message):
            return .failed(message)

        case .authorized:
            guard let service = await store.storedService() else {
                discardLink()
                return .failed("Dropbox authorized Auster but did not return any credentials.")
            }

            do {
                let account = try await service.currentAccount()
                guard !account.isTeam else {
                    await reject(service)
                    return .teamAccountNotSupported
                }
                adopt(service: service, account: account)
                return .linked(account)
            } catch {
                discardLink()
                return .failed(Self.describe(error))
            }
        }
    }

    /// Re-establishes the link from stored credentials at launch. Being offline
    /// is not being unlinked, so only a token the server has rejected clears the
    /// link — nothing but re-linking will fix that.
    public func restore() async {
        guard let service = await store.storedService() else {
            discardLink()
            return
        }

        isLinked = true
        self.service = service

        do {
            let account = try await service.currentAccount()
            guard !account.isTeam else {
                await reject(service)
                return
            }
            adopt(service: service, account: account)
        } catch DropboxServiceError.notAuthorized {
            // The server has already stopped honoring the token; nothing to revoke.
            discardLink()
        } catch {
            // Keep the link; the account details fill in when Dropbox is reachable.
        }
    }

    /// Revokes the token server-side, then forgets it locally. The local
    /// credentials go regardless of whether the revoke got through, or a user
    /// who unlinks while offline would stay linked.
    public func unlink() async {
        if let service {
            try? await service.revokeToken()
        }
        discardLink()
    }

    // MARK: - Internals

    /// Turns down an account Auster will not sync: the grant is handed back to
    /// Dropbox rather than left dangling, and nothing is kept locally.
    private func reject(_ service: any DropboxService) async {
        try? await service.revokeToken()
        discardLink()
    }

    private func adopt(service: any DropboxService, account: AccountInfo) {
        self.service = service
        self.account = account
        isLinked = true
    }

    private func discardLink() {
        store.clearCredentials()
        service = nil
        account = nil
        isLinked = false
    }

    private static func describe(_ error: any Error) -> String {
        (error as? DropboxServiceError)?.errorDescription ?? error.localizedDescription
    }
}

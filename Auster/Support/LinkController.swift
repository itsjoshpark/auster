import AusterCore
import Foundation
import Observation

/// Holds the app's link state for the temporary debug UI.
///
/// Phase 8 replaces this with the real app-state object; for now it exists so
/// linking can be exercised end to end against a real Dropbox account.
@MainActor
@Observable
final class LinkController {

    /// `nil` when the build has no Dropbox app key, which the app reports at
    /// launch and then cannot recover from.
    let auth: AuthManager?

    /// The last thing that happened, shown under the button.
    private(set) var status: String?

    init(auth: AuthManager?) {
        self.auth = auth
    }

    /// Builds a manager from the injected app key, or `nil` if there is none.
    static func fromBundle() -> LinkController {
        guard let appKey = AppKey.value else { return LinkController(auth: nil) }
        return LinkController(
            auth: AuthManager(
                store: KeychainDropboxLinkStore(
                    appKey: appKey,
                    presenter: AppKitAuthorizationPresenter()
                )
            )
        )
    }

    var isLinked: Bool { auth?.isLinked ?? false }

    var accountDescription: String? {
        guard let account = auth?.account else { return nil }
        return account.email
    }

    func restore() async {
        await auth?.restore()
        status = auth?.isLinked == true ? nil : "Not linked."
    }

    func beginLink() {
        status = "Waiting for Dropbox…"
        auth?.beginLink()
    }

    func handle(_ urls: [URL]) async {
        guard let auth else { return }
        for url in urls {
            switch await auth.handleRedirect(url: url) {
            case .linked(let account):
                status = "Linked as \(account.displayName)."
            case .cancelled:
                status = "Link cancelled."
            case .teamAccountNotSupported:
                // Exact copy from decisions D4 — never "not yet supported".
                status = "Not supported: Auster does not support Dropbox team accounts."
            case .failed(let message):
                status = message
            }
        }
    }

    func unlink() async {
        await auth?.unlink()
        status = "Not linked."
    }
}

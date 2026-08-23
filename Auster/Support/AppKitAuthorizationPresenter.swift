import AppKit
import AusterCore
import Foundation

/// Puts the Dropbox authorization page in front of the user.
///
/// This is the whole of the app target's involvement in linking: `AusterCore`
/// runs the OAuth flow but cannot import AppKit, so opening a URL and showing an
/// alert are delegated here (decisions N5).
@MainActor
final class AppKitAuthorizationPresenter: AuthorizationPresenter {

    func openInBrowser(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    func presentAuthorizationError(message: String, title: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}

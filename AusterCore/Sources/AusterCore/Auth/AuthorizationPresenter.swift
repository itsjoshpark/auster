import Foundation
import SwiftyDropbox

/// The one thing the OAuth flow needs that `AusterCore` cannot do itself:
/// putting a URL in front of the user. SwiftyDropbox's desktop entry point
/// takes an `NSApplication`, so the app target supplies this (decisions N5).
@MainActor
public protocol AuthorizationPresenter: AnyObject {

    /// Opens `url` in the user's browser.
    func openInBrowser(_ url: URL)

    /// Reports a problem that stopped the link before it began — no network, or
    /// a misconfigured redirect scheme.
    func presentAuthorizationError(message: String, title: String)
}

/// Adapts an `AuthorizationPresenter` to the interface SwiftyDropbox drives the
/// OAuth flow through — `DesktopSharedApplication` minus AppKit. On macOS every
/// route ends up opening the system browser.
final class SharedApplicationBridge: SharedApplication, @unchecked Sendable {

    private let presenter: any AuthorizationPresenter

    init(presenter: any AuthorizationPresenter) {
        self.presenter = presenter
    }

    func presentExternalApp(_ url: URL) {
        onMain { $0.openInBrowser(url) }
    }

    func canPresentExternalApp(_ url: URL) -> Bool { true }

    /// macOS has no platform-specific authorization app to hand off to.
    func presentPlatformSpecificAuth(_ authURL: URL) -> Bool { false }

    func presentAuthChannel(
        _ authURL: URL,
        tryIntercept: @escaping ((URL) -> Bool),
        cancelHandler: @escaping (() -> Void)
    ) {
        presentExternalApp(authURL)
    }

    func presentErrorMessage(_ message: String, title: String) {
        onMain { $0.presentAuthorizationError(message: message, title: title) }
    }

    func presentErrorMessageWithHandlers(
        _ message: String,
        title: String,
        buttonHandlers: [String: () -> Void]
    ) {
        presentErrorMessage(message, title: title)
    }

    /// Auster shows link progress in its own UI, so the SDK's loading hooks are
    /// deliberately inert.
    func presentLoading() {}

    func dismissLoading() {}

    /// The SDK calls these from whatever queue it happens to be on; the
    /// presenter is main-actor-bound.
    private func onMain(_ body: @escaping @MainActor (any AuthorizationPresenter) -> Void) {
        let presenter = presenter
        Task { @MainActor in body(presenter) }
    }
}

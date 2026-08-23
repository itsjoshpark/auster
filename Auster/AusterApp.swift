import AppKit
import AusterCore
import SwiftUI

/// Auster's entry point.
///
/// The app is a menu-bar-only agent (`LSUIElement`): a `MenuBarExtra` in window
/// style plus a `Settings` scene. All sync logic lives in `AusterCore`; this
/// target only renders state and forwards user intent.
@main
struct AusterApp: App {

    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra("Auster", systemImage: "checkmark.circle") {
            MenuBarContentView(link: appDelegate.link)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsPlaceholderView()
        }
    }
}

/// Handles the things a menu-bar-only app cannot do from a `Scene`.
///
/// The OAuth redirect arrives as a URL open. SwiftUI's `.onOpenURL` needs a view
/// on screen to attach to, and a `MenuBarExtra` window is built lazily when the
/// user clicks the icon — which is exactly when the redirect is *not* on screen.
/// The delegate is always there (decisions N6).
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    let link = LinkController.fromBundle()

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard link.auth != nil else {
            // Without an app key the app cannot link, and everything else
            // depends on being linked. Say so plainly and stop.
            let alert = NSAlert()
            alert.messageText = "Missing Dropbox app key"
            alert.informativeText = AppKey.missingKeyMessage
            alert.alertStyle = .critical
            alert.addButton(withTitle: "Quit")
            alert.runModal()
            NSApp.terminate(nil)
            return
        }

        Task { await link.restore() }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        Task { await link.handle(urls) }
    }
}

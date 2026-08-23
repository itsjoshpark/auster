import AppKit
import AusterCore
import SwiftUI

/// Auster's entry point.
///
/// The app is a menu-bar-only agent (`LSUIElement`): a `MenuBarExtra` in window
/// style, a `Settings` scene, and two ordinary windows for the things that do
/// not fit in a menu. All sync logic lives in `AusterCore`; this target only
/// renders state and forwards user intent.
@main
struct AusterApp: App {

    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    private var environment: AppEnvironment { appDelegate.environment }

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(environment: environment)
        } label: {
            StatusIconLabel(environment: environment)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsPlaceholderView(environment: environment)
        }

        Window("Sync Issues", id: SyncIssuesWindow.id) {
            SyncIssuesWindow(environment: environment)
        }
        .defaultSize(width: 560, height: 360)
    }
}

/// The menu bar's icon, as a view so that it tracks `SyncState`.
///
/// A `Scene`'s label is built once per update of the scene, and reading
/// observable state from inside a view is what guarantees the icon changes when
/// the status does.
private struct StatusIconLabel: View {

    @Bindable var environment: AppEnvironment

    var body: some View {
        let name = StatusIcon.assetName(
            for: environment.state.status,
            hasSyncErrors: !environment.state.syncErrors.isEmpty
        )
        if let image = StatusIcon.image(named: name) {
            Image(nsImage: image)
        } else {
            Image(systemName: "circle.dashed")
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

    let environment = AppEnvironment.fromBundle()

    private let onboardingController = OnboardingWindowController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard environment.auth != nil else {
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

        Task {
            await environment.start()
            // The wizard is the app until it has been through: a menu-bar icon
            // is not a call to action for someone who has never seen Auster.
            if environment.state.status == .needsSetup {
                onboardingController.show(environment)
            }
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        Task { await environment.handleRedirect(urls) }
    }

    /// Sync state is persisted incrementally — cursors and index rows are
    /// written as each change lands — so quitting only has to stop the loops
    /// (ux §9).
    func applicationWillTerminate(_ notification: Notification) {
        let environment = environment
        Task { await environment.stopForQuit() }
    }
}

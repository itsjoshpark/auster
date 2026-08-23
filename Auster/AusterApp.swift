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
            SettingsView(environment: environment)
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
        // One Auster at a time (ux §9). Two instances over one database and one
        // watched folder would each see the other's writes as the user's.
        if case .deferToExisting = SingleInstance.decision(
            otherProcessIdentifiers: Self.runningAusterProcesses(),
            current: ProcessInfo.processInfo.processIdentifier
        ) {
            Self.activateExistingInstance()
            NSApp.terminate(nil)
            return
        }

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

        // Unlinking from Settings puts the app back where a first launch does.
        environment.onNeedsSetup = { [weak self] in
            guard let self else { return }
            onboardingController.show(environment)
        }

        environment.observeFatalErrors()
        environment.observeSleepAndWake()

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

    /// Every process claiming Auster's bundle id, this one included — the
    /// decision of what to do about that is `SingleInstance`'s.
    private static func runningAusterProcesses() -> [pid_t] {
        guard let bundleIdentifier = Bundle.main.bundleIdentifier else { return [] }
        return
            NSRunningApplication
            .runningApplications(withBundleIdentifier: bundleIdentifier)
            .map(\.processIdentifier)
    }

    private static func activateExistingInstance() {
        guard let bundleIdentifier = Bundle.main.bundleIdentifier else { return }
        NSRunningApplication
            .runningApplications(withBundleIdentifier: bundleIdentifier)
            .first { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }?
            .activate()
    }

    /// Sync state is persisted incrementally — cursors and index rows are
    /// written as each change lands — so quitting only has to stop the loops
    /// (ux §9).
    func applicationWillTerminate(_ notification: Notification) {
        let environment = environment
        Task { await environment.stopForQuit() }
    }
}

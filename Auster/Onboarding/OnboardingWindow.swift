import AppKit
import AusterCore
import SwiftUI

/// The setup wizard's window (ux §3). An AppKit window rather than a SwiftUI
/// scene because it has to be on screen at launch: a scene opens only from a
/// view's environment, and a menu-bar app has none until its icon is clicked.
@MainActor
final class OnboardingWindowController: NSObject, NSWindowDelegate {

    private var window: NSWindow?
    private weak var environment: AppEnvironment?

    /// Shows the wizard, or brings it forward if it is already up.
    func show(_ environment: AppEnvironment) {
        self.environment = environment

        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let model = environment.beginOnboarding()
        let root = OnboardingWindow(model: model, environment: environment) { [weak self] in
            self?.close()
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 550, height: 400),
            // Non-resizable, per ux §3: the pages are laid out for one size.
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Set Up Auster"
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.contentView = NSHostingView(rootView: root)
        window.delegate = self
        window.center()
        window.isReleasedWhenClosed = false
        self.window = window

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Closes the wizard because it finished, rather than because the user gave
    /// up — so it must not take the app with it.
    private func close() {
        environment?.endOnboarding()
        let window = self.window
        self.window = nil
        window?.delegate = nil
        window?.close()
    }

    /// Closing an unfinished wizard quits: nothing Auster can do is available
    /// until it has been through (ux §3).
    func windowWillClose(_ notification: Notification) {
        guard window != nil else { return }
        window = nil
        NSApp.terminate(nil)
    }
}

/// The wizard's pages, one at a time.
struct OnboardingWindow: View {

    @Bindable var model: OnboardingModel
    @Bindable var environment: AppEnvironment

    /// Called by the last page. Closing the window any other way quits.
    let onFinished: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch model.page {
                case .welcome: WelcomePage(model: model)
                case .link: LinkPage(model: model)
                case .folder: FolderPage(model: model)
                case .selective: SelectiveSyncPage(model: model, environment: environment)
                case .done: DonePage(model: model, onFinished: onFinished)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(28)
        }
        .frame(width: 550, height: 400)
    }
}

/// The app icon at wizard size, shared by the first page and the last.
struct OnboardingIcon: View {

    var body: some View {
        Image(nsImage: NSApp.applicationIconImage)
            .resizable()
            .frame(width: 84, height: 84)
    }
}

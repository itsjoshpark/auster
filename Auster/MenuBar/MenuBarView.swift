import AppKit
import AusterCore
import SwiftUI

/// The menu bar menu, top to bottom exactly as ux §2 lists it.
///
/// A real `NSMenu`: the snooze row is a genuine submenu, and the highlight, the
/// disabled info rows and the shortcut column come from AppKit (note N42).
struct MenuBarView: View {

    @Bindable var environment: AppEnvironment

    var body: some View {
        Button("Open Dropbox Folder") { environment.openDropboxFolder() }
        Button("Launch Dropbox Website") { environment.openDropboxWebsite() }

        if environment.state.status == .needsSetup {
            UnlinkedRows(environment: environment)
        } else {
            LinkedRows(environment: environment)
        }

        Divider()
        Button("Quit Auster") { quit() }
            .keyboardShortcut("q")
    }

    /// Cursors and index rows are written as each change lands, so quitting only
    /// has to stop the loops (ux §9).
    private func quit() {
        Task {
            await environment.stopForQuit()
            NSApp.terminate(nil)
        }
    }
}

/// The menu as it stands once an account is linked (ux §2).
private struct LinkedRows: View {

    @Bindable var environment: AppEnvironment

    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    private var state: SyncState { environment.state }

    var body: some View {
        Divider()

        // A `Text` in a menu is a disabled item, which is what these rows are.
        if let account = state.account {
            Text(account.email)
        }
        Text(state.usageText)

        Divider()

        Text(statusText)
        ActivitySection(activity: state.activity)

        // A revoked token is the one fatal error the user can fix themselves,
        // and only through a browser (engine-doc §9).
        if environment.needsRelink {
            Button("Please re-link Auster…") { environment.relink() }
        }

        SyncIssuesRow(environment: environment)

        Button(state.status == .paused ? "Resume Syncing" : "Pause Syncing") {
            Task {
                if state.status == .paused {
                    await environment.resume()
                } else {
                    await environment.pause()
                }
            }
        }

        Button("Show Recent Changes…") {
            openWindow(id: RecentChangesWindow.id)
            NSApp.activate(ignoringOtherApps: true)
        }

        Divider()

        SnoozeRows(environment: environment)

        Button("Rebuild Index…") { confirmRebuild() }
            .disabled(environment.isBusy)

        Divider()

        Button("Settings…") { openSettings() }
            .keyboardShortcut(",")
        Button("Check for Updates…") { environment.updater.checkForUpdates() }
            .disabled(!environment.updater.canCheckForUpdates)
    }

    /// The status line of engine-doc §10.
    private var statusText: String {
        switch state.status {
        case .needsSetup: "Setting up…"
        case .connecting: "Connecting…"
        case .idle: state.syncErrors.isEmpty ? "Up to date" : "Sync error"
        case .syncing(let detail): detail
        case .paused: "Paused"
        case .fatalError(let error): error.errorDescription ?? "Sync stopped"
        }
    }

    /// Menu content is an `NSMenu`, so the confirmation ux §2 item 13 asks for
    /// is an alert rather than a SwiftUI dialog (note N42).
    private func confirmRebuild() {
        let alert = NSAlert()
        alert.messageText = "Rebuild Auster’s sync index?"
        alert.informativeText = """
            Auster will compare every file with Dropbox again. This can take a \
            while for a large Dropbox, and nothing is lost: where the two sides \
            disagree, Auster keeps both as conflicted copies.
            """
        alert.addButton(withTitle: "Rebuild")
        alert.addButton(withTitle: "Cancel")

        // A background agent has no window of its own to bring forward, so the
        // alert would open behind whatever is in front.
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task { await environment.rebuildIndex() }
    }
}

/// The issues row of ux §2 item 8: a count to click when there is one, a
/// disabled reassurance when there is not.
private struct SyncIssuesRow: View {

    @Bindable var environment: AppEnvironment

    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if environment.state.syncErrors.isEmpty {
            Text("No Sync Issues")
        } else {
            Button("Show Sync Issues (\(environment.state.syncErrors.count))…") {
                openWindow(id: SyncIssuesWindow.id)
                NSApp.activate(ignoringOtherApps: true)
            }
        }
    }
}

/// The snooze submenu of ux §2 item 12, and what stands in its place while
/// notifications are snoozed.
private struct SnoozeRows: View {

    @Bindable var environment: AppEnvironment

    var body: some View {
        if environment.settings.isSnoozed, let until = environment.settings.notificationsSnoozedUntil {
            Text("Notifications snoozed until \(until.formatted(date: .omitted, time: .shortened))")
            Button("Turn On Notifications") { environment.settings.turnOnNotifications() }
        } else {
            // Nested in a menu, this is a real submenu: it opens on hover and
            // flies out to the side (note N42).
            Menu("Snooze Notifications") {
                Button("For the next 30 minutes") { environment.settings.snoozeNotifications(for: 30 * 60) }
                Button("For the next hour") { environment.settings.snoozeNotifications(for: 3600) }
                Button("For the next 8 hours") { environment.settings.snoozeNotifications(for: 8 * 3600) }
            }
        }
    }
}

/// The unlinked menu of ux §2, before setup has been through.
private struct UnlinkedRows: View {

    @Bindable var environment: AppEnvironment

    var body: some View {
        Divider()
        Text("Setting up…")

        Divider()
        StartAtLoginRow()
        Button("Help Center") {
            NSWorkspace.shared.open(URL(string: "https://github.com/itsjoshpark/auster")!)
        }
    }
}

// MARK: - Rows

/// One in-flight transfer, as a line of text.
///
/// A menu item cannot hold a progress bar, and ux §2 item 7 does not ask for
/// one: it describes progress in words.
enum ActivityLine {

    static func text(for item: ActivityItem) -> String {
        let arrow = item.direction == .down ? "↓" : "↑"
        let name = (item.dbxPath as NSString).lastPathComponent
        // `total` is zero until the size is known. "0%" would read as stalled.
        guard item.total > 0 else { return "\(arrow) \(name)" }
        let percent = Int((item.fraction * 100).rounded())
        return "\(arrow) \(name) — \(percent)%"
    }
}

/// The in-flight transfers, at most five (ux §2 item 7).
private struct ActivitySection: View {

    let activity: [ActivityItem]

    var body: some View {
        ForEach(activity.prefix(5)) { item in
            Text(ActivityLine.text(for: item))
        }
    }
}

/// The unlinked menu's login-item switch (ux §2, unlinked variant).
private struct StartAtLoginRow: View {

    @State private var isEnabled = LoginItem.isEnabled

    var body: some View {
        Toggle("Start on Login", isOn: $isEnabled)
            .onChange(of: isEnabled) { _, newValue in
                // The system is the source of truth: if it refuses, snap the
                // switch back rather than lie about what will happen at login.
                try? LoginItem.setEnabled(newValue)
                isEnabled = LoginItem.isEnabled
            }
    }
}

import AppKit
import AusterCore
import SwiftUI

/// The menu bar menu, top to bottom exactly as ux §2 lists it.
///
/// A real menu rather than a window-style panel. The panel was chosen so that
/// the status and activity rows could be richer than a menu item, but the rows
/// ux §2 actually asks for are lines of text, and emulating a menu inside a
/// window cost more than it bought: a hand-built hover highlight on every row,
/// and a snooze "submenu" that was a pop-up button — it needed a click, opened
/// downwards over the rows below, and drew its disclosure on the wrong side.
/// `.menuBarExtraStyle(.menu)` gets all of that from AppKit, including a
/// submenu that opens on hover (note N42).
struct MenuBarView: View {

    @Bindable var environment: AppEnvironment

    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    private var state: SyncState { environment.state }

    var body: some View {
        Button("Open Dropbox Folder") { environment.openDropboxFolder() }
        Button("Launch Dropbox Website") { environment.openDropboxWebsite() }

        if state.status == .needsSetup {
            unlinkedRows
        } else {
            linkedRows
        }

        Divider()
        Button("Quit Auster") { quit() }
            .keyboardShortcut("q")
    }

    // MARK: - Linked (ux §2)

    @ViewBuilder
    private var linkedRows: some View {
        Divider()

        // A `Text` in a menu is a disabled item, which is what these rows are:
        // Maestral's could not be clicked either.
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

        syncIssuesRow

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

        snoozeRows

        Button("Rebuild Index…") { confirmRebuild() }
            .disabled(environment.isBusy)

        Divider()

        Button("Settings…") { openSettings() }
            .keyboardShortcut(",")
        Button("Check for Updates…") { environment.updater.checkForUpdates() }
            .disabled(!environment.updater.canCheckForUpdates)
    }

    @ViewBuilder
    private var syncIssuesRow: some View {
        if state.syncErrors.isEmpty {
            Text("No Sync Issues")
        } else {
            Button("Show Sync Issues (\(state.syncErrors.count))…") {
                openWindow(id: SyncIssuesWindow.id)
                NSApp.activate(ignoringOtherApps: true)
            }
        }
    }

    @ViewBuilder
    private var snoozeRows: some View {
        if environment.settings.isSnoozed, let until = environment.settings.notificationsSnoozedUntil {
            Text("Notifications snoozed until \(Self.time.string(from: until))")
            Button("Turn On Notifications") { environment.settings.turnOnNotifications() }
        } else {
            // Nested in a menu, this is a real submenu: it opens on hover, flies
            // out to the side, and draws its own disclosure (ux §2 item 12).
            Menu("Snooze Notifications") {
                Button("For the next 30 minutes") { environment.settings.snoozeNotifications(for: 30 * 60) }
                Button("For the next hour") { environment.settings.snoozeNotifications(for: 3600) }
                Button("For the next 8 hours") { environment.settings.snoozeNotifications(for: 8 * 3600) }
            }
        }
    }

    // MARK: - Unlinked (ux §2)

    @ViewBuilder
    private var unlinkedRows: some View {
        Divider()
        Text("Setting up…")

        Divider()
        StartAtLoginRow()
        Button("Help Center") {
            NSWorkspace.shared.open(URL(string: "https://github.com/itsjoshpark/auster")!)
        }
    }

    // MARK: - Helpers

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

    /// Menu content is an `NSMenu`, not a view hierarchy, so a SwiftUI
    /// confirmation dialog has nothing to attach itself to — the confirmation
    /// ux §2 item 13 asks for is an alert (note N42).
    private func confirmRebuild() {
        let alert = NSAlert()
        alert.messageText = "Rebuild Auster's sync index?"
        alert.informativeText = """
            Auster will compare every file with Dropbox again. This can take a \
            while for a large Dropbox, and nothing is lost: where the two sides \
            disagree, Auster keeps both as conflicted copies.
            """
        alert.addButton(withTitle: "Rebuild")
        alert.addButton(withTitle: "Cancel")

        // The app has no windows of its own to bring forward, and an alert from
        // a background agent would otherwise open behind whatever is in front.
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task { await environment.rebuildIndex() }
    }

    /// Quitting stops the loops first; cursors and index rows are written as
    /// each change lands, so there is nothing else to flush (ux §9).
    private func quit() {
        Task {
            await environment.stopForQuit()
            NSApp.terminate(nil)
        }
    }

    private static let time: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }()
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

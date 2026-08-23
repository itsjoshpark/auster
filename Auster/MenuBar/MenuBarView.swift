import AppKit
import AusterCore
import SwiftUI

/// The menu bar window, top to bottom exactly as ux §2 lists it.
///
/// A window-style `MenuBarExtra` rather than a real menu, because three of the
/// rows are not menu items at all: the status line carries live progress rows,
/// the recent-changes section is a disclosure of thirty entries, and the usage
/// readout updates while it is open. What it costs is that every row has to be
/// built to look like a menu item, which `MenuRowButton` below is for.
struct MenuBarView: View {

    @Bindable var environment: AppEnvironment

    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    @State private var isConfirmingRebuild = false

    private var state: SyncState { environment.state }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            MenuRowButton("Open Dropbox Folder") { environment.openDropboxFolder() }
            MenuRowButton("Launch Dropbox Website") { environment.openDropboxWebsite() }

            if state.status == .needsSetup {
                unlinkedRows
            } else {
                linkedRows
            }

            Divider().padding(.vertical, 4)
            MenuRowButton("Quit Auster", shortcutHint: "⌘Q") { quit() }
                .keyboardShortcut("q")
        }
        .padding(6)
        .frame(width: 300)
        .confirmationDialog(
            "Rebuild Auster's sync index?",
            isPresented: $isConfirmingRebuild
        ) {
            Button("Rebuild") { Task { await environment.rebuildIndex() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                """
                Auster will compare every file with Dropbox again. This can take \
                a while for a large Dropbox, and nothing is lost: where the two \
                sides disagree, Auster keeps both as conflicted copies.
                """
            )
        }
    }

    // MARK: - Linked (ux §2)

    @ViewBuilder
    private var linkedRows: some View {
        Divider().padding(.vertical, 4)

        if let account = state.account {
            MenuInfoRow(account.email)
        }
        MenuInfoRow(state.usageText)

        Divider().padding(.vertical, 4)

        MenuInfoRow(statusText, isProminent: true)
        ActivitySection(activity: state.activity)

        syncIssuesRow

        MenuRowButton(state.status == .paused ? "Resume Syncing" : "Pause Syncing") {
            Task {
                if state.status == .paused {
                    await environment.resume()
                } else {
                    await environment.pause()
                }
            }
        }

        RecentChangesSection(
            changes: state.recentChanges,
            reveal: { environment.revealInFinder(dbxPath: $0) }
        )

        Divider().padding(.vertical, 4)

        snoozeRows

        MenuRowButton("Rebuild Index…") { isConfirmingRebuild = true }
            .disabled(environment.isBusy)

        Divider().padding(.vertical, 4)

        MenuRowButton("Settings…", shortcutHint: "⌘,") { openSettings() }
            .keyboardShortcut(",")
        MenuRowButton("Check for Updates…") { environment.updater.checkForUpdates() }
            .disabled(!environment.updater.canCheckForUpdates)
    }

    @ViewBuilder
    private var syncIssuesRow: some View {
        if state.syncErrors.isEmpty {
            MenuInfoRow("No Sync Issues")
        } else {
            MenuRowButton("Show Sync Issues (\(state.syncErrors.count))…") {
                openWindow(id: SyncIssuesWindow.id)
                NSApp.activate(ignoringOtherApps: true)
            }
        }
    }

    @ViewBuilder
    private var snoozeRows: some View {
        if environment.settings.isSnoozed, let until = environment.settings.notificationsSnoozedUntil {
            MenuInfoRow("Notifications snoozed until \(Self.time.string(from: until))")
            MenuRowButton("Turn On Notifications") { environment.settings.turnOnNotifications() }
        } else {
            Menu("Snooze Notifications") {
                Button("For the next 30 minutes") { environment.settings.snoozeNotifications(for: 30 * 60) }
                Button("For the next hour") { environment.settings.snoozeNotifications(for: 3600) }
                Button("For the next 8 hours") { environment.settings.snoozeNotifications(for: 8 * 3600) }
            }
            .menuStyle(.borderlessButton)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
        }
    }

    // MARK: - Unlinked (ux §2)

    @ViewBuilder
    private var unlinkedRows: some View {
        Divider().padding(.vertical, 4)
        MenuInfoRow("Setting up…", isProminent: true)

        Divider().padding(.vertical, 4)
        StartAtLoginRow()
        MenuRowButton("Help Center") {
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

/// A row that looks and highlights like a menu item.
///
/// `Button(...)` in a `.window`-style `MenuBarExtra` draws as a push button, so
/// the whole menu would look like a form. This is the plain-styled equivalent,
/// with the hover highlight AppKit menus have.
struct MenuRowButton: View {

    private let title: String
    private let shortcutHint: String?
    private let action: () -> Void

    @State private var isHovering = false
    @Environment(\.isEnabled) private var isEnabled

    init(_ title: String, shortcutHint: String? = nil, action: @escaping () -> Void) {
        self.title = title
        self.shortcutHint = shortcutHint
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(title)
                Spacer(minLength: 8)
                if let shortcutHint {
                    Text(shortcutHint).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .contentShape(.rect)
            .background(
                isHovering && isEnabled ? Color.accentColor.opacity(0.85) : .clear,
                in: .rect(cornerRadius: 4)
            )
            .foregroundStyle(isHovering && isEnabled ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}

/// A row that states something rather than doing something: the email, the
/// usage, the status line. Disabled-looking on purpose — these are the rows
/// Maestral's menu could not be clicked on either.
struct MenuInfoRow: View {

    private let text: String
    private let isProminent: Bool

    init(_ text: String, isProminent: Bool = false) {
        self.text = text
        self.isProminent = isProminent
    }

    var body: some View {
        Text(text)
            .foregroundStyle(isProminent ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
            .lineLimit(1)
            .truncationMode(.middle)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The in-flight transfers, at most five (ux §2 item 7).
private struct ActivitySection: View {

    let activity: [ActivityItem]

    var body: some View {
        ForEach(activity.prefix(5)) { item in
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Image(systemName: item.direction == .down ? "arrow.down" : "arrow.up")
                        .font(.caption2)
                    Text((item.dbxPath as NSString).lastPathComponent)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                if item.total > 0 {
                    ProgressView(value: item.fraction).controlSize(.mini)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 1)
        }
    }
}

/// The unlinked menu's login-item switch (ux §2, unlinked variant).
private struct StartAtLoginRow: View {

    @State private var isEnabled = LoginItem.isEnabled

    var body: some View {
        Toggle("Start on Login", isOn: $isEnabled)
            .toggleStyle(.checkbox)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .onChange(of: isEnabled) { _, newValue in
                // The system is the source of truth: if it refuses, snap the
                // switch back rather than lie about what will happen at login.
                try? LoginItem.setEnabled(newValue)
                isEnabled = LoginItem.isEnabled
            }
    }
}

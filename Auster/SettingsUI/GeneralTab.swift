import AppKit
import AusterCore
import SwiftUI

/// Where the folder is, and the switches that decide when Auster speaks up
/// (ux §4).
struct GeneralTab: View {

    @Bindable var environment: AppEnvironment
    @Bindable var settings: AppSettings

    @State private var startAtLogin = LoginItem.isEnabled
    @State private var moveError: String?
    @State private var loginItemError: String?

    var body: some View {
        Form {
            Section {
                LabeledContent("Dropbox folder") {
                    HStack(spacing: 8) {
                        Text(environment.dropboxFolderURL.path)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(environment.dropboxFolderURL.path)
                        Button("Move…") { chooseNewLocation() }
                            .disabled(environment.isBusy)
                    }
                }
            } footer: {
                Text("Moving the folder stops sync, relocates the files, and starts again.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Start at login", isOn: $startAtLogin)
                    .onChange(of: startAtLogin) { _, newValue in setStartAtLogin(newValue) }
                if LoginItem.requiresApproval {
                    Text("Auster is turned off in System Settings › General › Login Items.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let loginItemError {
                    Text(loginItemError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                Toggle("Notify about remote changes", isOn: $settings.notificationsEnabled)

                Picker("Check for updates", selection: $settings.updateCheckInterval) {
                    Text("Daily").tag(UpdateCheckInterval.daily)
                    Text("Weekly").tag(UpdateCheckInterval.weekly)
                    Text("Monthly").tag(UpdateCheckInterval.monthly)
                    Text("Never").tag(UpdateCheckInterval.never)
                }
            }
        }
        .formStyle(.grouped)
        .alert(
            "Could not move your Dropbox folder",
            isPresented: Binding(get: { moveError != nil }, set: { if !$0 { moveError = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(moveError ?? "")
        }
    }

    /// Picks a location; the folder keeps its name inside it, as in the wizard.
    private func chooseNewLocation() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Move"
        panel.message = "Choose where to keep your Dropbox folder."
        panel.directoryURL = environment.dropboxFolderURL.deletingLastPathComponent()

        guard panel.runModal() == .OK, let location = panel.url else { return }
        let destination = location.appendingPathComponent(
            environment.dropboxFolderURL.lastPathComponent,
            isDirectory: false
        )

        Task {
            do {
                try await environment.moveDropboxFolder(to: destination)
            } catch {
                moveError = error.localizedDescription
            }
        }
    }

    /// The system is the source of truth: if it refuses, the switch snaps back
    /// rather than claiming something that will not happen at login (ux §9).
    private func setStartAtLogin(_ enabled: Bool) {
        do {
            try LoginItem.setEnabled(enabled)
            loginItemError = nil
        } catch {
            loginItemError = error.localizedDescription
        }
        startAtLogin = LoginItem.isEnabled
    }
}

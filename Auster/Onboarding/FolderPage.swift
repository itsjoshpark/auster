import AppKit
import AusterCore
import SwiftUI

/// Page 3 of ux §3: where the user's Dropbox will live locally.
struct FolderPage: View {

    @Bindable var model: OnboardingModel

    @State private var candidate: URL?
    @State private var isConfirmingMerge = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Successfully linked")
                .font(.title2)
            if let name = model.accountName {
                Text("Signed in as \(name)\(model.accountEmail.map { " (\($0))" } ?? "").")
                    .foregroundStyle(.secondary)
            }

            Text(
                """
                Choose where to keep your Dropbox folder. If the folder already \
                has files in it, Auster can merge them with your Dropbox — \
                anything already identical on both sides is left where it is.
                """
            )
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Image(systemName: "folder")
                    .foregroundStyle(.secondary)
                Text(model.folderURL.path)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                Button("Choose…") { chooseLocation() }
            }
            .padding(8)
            .background(.background.secondary, in: .rect(cornerRadius: 6))

            Spacer()

            HStack {
                Button("Cancel & Unlink") { Task { await model.cancelAndUnlink() } }
                Spacer()
                Button("Select") { select(model.folderURL) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .confirmationDialog(
            "\"\(candidate?.lastPathComponent ?? "Dropbox")\" already has files in it.",
            isPresented: $isConfirmingMerge
        ) {
            Button("Merge") { if let candidate { model.confirmFolder(candidate) } }
            Button("Choose Another…") { chooseLocation() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                """
                Auster will sync these files with your Dropbox. Files that are \
                already the same on both sides are not transferred.
                """
            )
        }
    }

    /// Picks a *location*, not the folder itself: Auster creates a folder called
    /// "Dropbox" inside it, so the user never has to name it (ux §3.3).
    private func chooseLocation() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Select"
        panel.message = "Choose where to create your Dropbox folder."
        panel.directoryURL = model.folderURL.deletingLastPathComponent()

        guard panel.runModal() == .OK, let location = panel.url else { return }
        select(model.proposedFolder(in: location))
    }

    private func select(_ url: URL) {
        candidate = url
        switch model.decision(for: url) {
        case .ready:
            model.confirmFolder(url)
        case .needsMergeConfirmation:
            isConfirmingMerge = true
        }
    }
}

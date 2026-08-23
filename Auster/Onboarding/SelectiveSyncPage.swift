import AusterCore
import SwiftUI

/// Page 4 of ux §3: which folders come down to this Mac.
///
/// The same tree as the Settings tab, but the selection is only *carried* here —
/// there is no engine yet to apply it to. It is handed over with the folder when
/// the last page finishes, so the very first index already filters it.
struct SelectiveSyncPage: View {

    @Bindable var model: OnboardingModel
    @Bindable var environment: AppEnvironment

    @State private var tree: FolderTreeModel?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Choose folders to sync")
                .font(.title2)
            Text("Folders you leave unchecked stay in your Dropbox but are not downloaded to this Mac.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Group {
                if let tree {
                    SelectiveSyncTree(model: tree)
                } else {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .background(.background.secondary, in: .rect(cornerRadius: 6))
            .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(.separator) }

            HStack {
                Button("Back") { model.back() }
                Spacer()
                Button("Select") { model.confirmSelection(tree?.resultingExcludedSet() ?? []) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { if tree == nil { tree = environment.makeFolderTreeModel() } }
    }
}

import AusterCore
import SwiftUI

/// The tri-state folder tree of ux §5. Draws `FolderTreeModel` and nothing else:
/// every rule about what a checkbox means, and what toggling one does, lives in
/// the model where it can be tested without a window.
struct SelectiveSyncTree: View {

    let model: FolderTreeModel

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                if model.isLoadingRoots && model.roots.isEmpty {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Loading folders…").foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                } else if let error = model.loadError, model.roots.isEmpty {
                    Text(error)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.vertical, 4)
                } else if model.roots.isEmpty {
                    Text("This Dropbox has no folders.")
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 4)
                }

                ForEach(model.roots) { node in
                    FolderTreeRow(model: model, node: node, depth: 0)
                }
            }
            .padding(6)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task { await model.loadRoot() }
    }
}

/// One folder, and — once expanded — the folders inside it. Expansion is driven
/// from here: whether a branch is open belongs to the view, whether its children
/// are known belongs to the model, and conflating them reloads on every reopen.
private struct FolderTreeRow: View {

    let model: FolderTreeModel
    let node: FolderTreeModel.Node
    let depth: Int

    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                disclosure
                checkbox
                Image(systemName: "folder")
                    .foregroundStyle(.secondary)
                Text(node.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if node.isLoading {
                    ProgressView().controlSize(.mini)
                }
                Spacer(minLength: 0)
            }
            .padding(.leading, CGFloat(depth) * 18)
            .contentShape(.rect)

            if isExpanded {
                ForEach(node.children ?? []) { child in
                    FolderTreeRow(model: model, node: child, depth: depth + 1)
                }
            }
        }
    }

    private var disclosure: some View {
        Button {
            isExpanded.toggle()
            if isExpanded { Task { await model.expand(node) } }
        } label: {
            Image(systemName: "chevron.right")
                .rotationEffect(.degrees(isExpanded ? 90 : 0))
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 12)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isExpanded ? "Collapse \(node.name)" : "Expand \(node.name)")
    }

    private var checkbox: some View {
        Button {
            model.toggle(node)
        } label: {
            Image(systemName: symbolName)
                .foregroundStyle(node.checkState == .on ? Color.accentColor : .secondary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(node.name)
        .accessibilityValue(accessibilityValue)
    }

    private var symbolName: String {
        switch node.checkState {
        case .on: "checkmark.square.fill"
        case .off: "square"
        case .mixed: "minus.square.fill"
        }
    }

    private var accessibilityValue: String {
        switch node.checkState {
        case .on: "Syncing"
        case .off: "Not syncing"
        case .mixed: "Partly syncing"
        }
    }
}

/// The tree plus the two buttons that commit or abandon a selection. Nothing is
/// applied as the user clicks: selective sync deletes folders, so the change
/// stays reversible right up to the moment Apply is pressed.
struct SelectiveSyncEditor: View {

    @Bindable var environment: AppEnvironment

    @State private var model: FolderTreeModel?
    @State private var isApplying = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Choose which folders to sync to this Mac.")
                .foregroundStyle(.secondary)

            Group {
                if let model {
                    SelectiveSyncTree(model: model)
                        .id(ObjectIdentifier(model))
                } else {
                    Text("Link a Dropbox account to choose folders.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .background(.background.secondary, in: .rect(cornerRadius: 6))
            .overlay {
                RoundedRectangle(cornerRadius: 6).strokeBorder(.separator)
            }

            HStack {
                Spacer()
                Button("Revert") { model = environment.makeFolderTreeModel() }
                    .disabled(!(model?.hasChanges ?? false) || isApplying)
                Button("Apply") { apply() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!(model?.hasChanges ?? false) || isApplying)
            }
        }
        .onAppear { if model == nil { model = environment.makeFolderTreeModel() } }
    }

    private func apply() {
        guard let model else { return }
        isApplying = true
        Task {
            await environment.setExcluded(model.resultingExcludedSet())
            // A fresh model, so "changed" is measured against what the engine
            // now has rather than against what it had when the tab opened.
            self.model = environment.makeFolderTreeModel()
            isApplying = false
        }
    }
}

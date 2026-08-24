import AusterCore
import SwiftUI

/// How a completed sync event is presented (ux §2 item 10, §7). Pure and
/// separate from the view, like `StatusIcon`: these are the whole content of a
/// row somebody scans rather than reads.
enum RecentChangePresentation {

    /// Maestral showed the last thirty, and thirty is about what fits before a
    /// list stops being a list and starts being a log (ux §7).
    static let limit = 30

    static func displayed(_ changes: [HistoryEntry]) -> [HistoryEntry] {
        Array(changes.prefix(limit))
    }

    /// The change, not the file type: what the row reports is what happened,
    /// and — for an addition, where the ambiguity is — which way it travelled.
    static func symbolName(for entry: HistoryEntry) -> String {
        switch entry.changeType {
        case .added: entry.direction == .down ? "arrow.down.circle" : "arrow.up.circle"
        case .modified: "pencil.circle"
        case .moved: "arrow.right.circle"
        case .removed: "trash.circle"
        }
    }

    /// A removal has nothing left on disk to point at, so the row is inert
    /// rather than misleading (ux §7).
    static func isRevealable(_ entry: HistoryEntry) -> Bool {
        entry.changeType != .removed
    }
}

/// The Recent Changes window of ux §2 item 10 and §7. The list is thirty rows
/// deep and gets scrolled and compared against, which a panel that dismisses the
/// moment focus moves is a bad place for.
struct RecentChangesWindow: View {

    static let id = "recent-changes"

    @Bindable var environment: AppEnvironment

    private var changes: [HistoryEntry] {
        RecentChangePresentation.displayed(environment.state.recentChanges)
    }

    var body: some View {
        Group {
            if changes.isEmpty {
                ContentUnavailableView(
                    "No Recent Changes",
                    systemImage: "clock.arrow.circlepath",
                    description: Text("Files Auster syncs will be listed here.")
                )
            } else {
                List(changes, id: \.id) { entry in
                    RecentChangeRow(environment: environment, entry: entry)
                }
                .listStyle(.inset)
            }
        }
        .frame(minWidth: 480, minHeight: 320)
    }
}

private struct RecentChangeRow: View {

    let environment: AppEnvironment
    let entry: HistoryEntry

    private var isRevealable: Bool { RecentChangePresentation.isRevealable(entry) }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: RecentChangePresentation.symbolName(for: entry))
                .foregroundStyle(.secondary)
                .font(.title3)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text((entry.dbxPath as NSString).lastPathComponent)
                    .fontWeight(.medium)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(entry.dbxPath)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }

            Spacer(minLength: 8)

            Text(entry.timestamp, format: .relative(presentation: .numeric))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize()
        }
        .padding(.vertical, 3)
        .contentShape(.rect)
        // Double-click reveals, as Maestral's list did (ux §7); the context menu
        // is there because a double-click is not something a list advertises.
        .onTapGesture(count: 2) { reveal() }
        .contextMenu {
            if isRevealable {
                Button("Show in Finder") { reveal() }
            }
            Button("Open on Dropbox") { environment.openOnDropboxWebsite(dbxPath: entry.dbxPath) }
        }
        .help(isRevealable ? "Double-click to reveal in Finder" : entry.dbxPath)
    }

    private func reveal() {
        guard isRevealable else { return }
        environment.revealInFinder(dbxPath: entry.dbxPath)
    }
}

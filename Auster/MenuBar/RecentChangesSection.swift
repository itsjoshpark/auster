import AusterCore
import SwiftUI

/// The last thirty completed sync events, collapsed by default (ux §2 item 10,
/// §7).
///
/// Inline rather than a window of its own: the question it answers — "did that
/// file I just saved actually go?" — is asked while the menu is already open,
/// and a second window to answer it would be a second thing to close.
struct RecentChangesSection: View {

    let changes: [HistoryEntry]

    /// Selecting the item in Finder, which a deleted item has no use for.
    let reveal: (String) -> Void

    @State private var isExpanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            if changes.isEmpty {
                Text("No recent changes")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 2)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(changes.prefix(30), id: \.id) { entry in
                            RecentChangeRow(entry: entry, reveal: reveal)
                        }
                    }
                }
                .frame(maxHeight: 220)
            }
        } label: {
            Text("Show Recent Changes")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
    }
}

private struct RecentChangeRow: View {

    let entry: HistoryEntry
    let reveal: (String) -> Void

    @State private var isHovering = false

    /// A removal has nothing left on disk to point at, so the row is inert
    /// rather than misleading (ux §7).
    private var isRevealable: Bool {
        entry.changeType != .removed
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbolName)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 14)

            VStack(alignment: .leading, spacing: 0) {
                Text((entry.dbxPath as NSString).lastPathComponent)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(entry.dbxPath)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }

            Spacer(minLength: 6)

            Text(entry.timestamp, format: .relative(presentation: .numeric))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize()
        }
        .font(.caption)
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
        .contentShape(.rect)
        .background(
            isHovering && isRevealable ? Color.primary.opacity(0.08) : .clear,
            in: .rect(cornerRadius: 4)
        )
        .onHover { isHovering = $0 }
        .onTapGesture {
            guard isRevealable else { return }
            reveal(entry.dbxPath)
        }
        .help(isRevealable ? "Reveal in Finder" : entry.dbxPath)
    }

    /// The change, not the file type: what the row is reporting is what
    /// happened, and the direction it happened in.
    private var symbolName: String {
        switch entry.changeType {
        case .added: entry.direction == .down ? "arrow.down.circle" : "arrow.up.circle"
        case .modified: "pencil.circle"
        case .moved: "arrow.right.circle"
        case .removed: "trash.circle"
        }
    }
}

import AusterCore
import SwiftUI

/// The Sync Issues window of ux §6: one row per path the engine could not sync,
/// with the two things a user can do about it. Rows leave as the engine clears
/// them — the list is `state.syncErrors`, emptied by a successful retry.
struct SyncIssuesWindow: View {

    static let id = "sync-issues"

    @Bindable var environment: AppEnvironment

    private var errors: [SyncErrorEntry] { environment.state.syncErrors }

    var body: some View {
        Group {
            if errors.isEmpty {
                ContentUnavailableView(
                    "No Sync Issues",
                    systemImage: "checkmark.circle",
                    description: Text("Everything in your Dropbox folder is up to date.")
                )
            } else {
                List(errors, id: \.dbxPathLower) { error in
                    SyncIssueRow(environment: environment, error: error)
                }
                .listStyle(.inset)
            }
        }
        .frame(minWidth: 480, minHeight: 320)
    }
}

private struct SyncIssueRow: View {

    let environment: AppEnvironment
    let error: SyncErrorEntry

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.title3)

            VStack(alignment: .leading, spacing: 2) {
                Text((error.dbxPath as NSString).lastPathComponent)
                    .fontWeight(.medium)
                Text(error.dbxPath)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
                Text(error.title)
                    .font(.callout)
                Text(error.message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 4) {
                Button("Show in Finder") { environment.revealInFinder(dbxPath: error.dbxPath) }
                Button("Open on Dropbox") { environment.openOnDropboxWebsite(dbxPath: error.dbxPath) }
            }
            .buttonStyle(.link)
            .font(.caption)
        }
        .padding(.vertical, 4)
    }
}

import AusterCore
import SwiftUI

/// Placeholder contents of the menu bar window.
///
/// Phase 8 replaces this with the real status header, activity list and actions
/// described in `docs/research/maestral-ux.md`. Until then it carries just
/// enough to link an account and watch the engine work: a status line, whatever
/// is transferring, and pause/resume.
struct MenuBarContentView: View {

    @Bindable var environment: AppEnvironment

    private var state: SyncState { environment.state }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Auster")
                .font(.headline)

            Text(statusText)
                .font(.callout)
                .foregroundStyle(.secondary)

            if state.status == .needsSetup {
                Button("Link Dropbox Account…") {
                    environment.link.beginLink()
                }
                .disabled(environment.link.auth == nil)
            } else {
                accountSection
            }

            if let message = environment.link.status {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding()
        .frame(width: 300, alignment: .leading)
    }

    @ViewBuilder
    private var accountSection: some View {
        if let account = state.account {
            Text(account.email)
                .font(.footnote)
                .foregroundStyle(.secondary)
            Text(state.usageText)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }

        if !state.activity.isEmpty {
            Divider()
            ForEach(state.activity.prefix(5)) { item in
                HStack(spacing: 6) {
                    Image(systemName: item.direction == .down ? "arrow.down" : "arrow.up")
                    Text(item.dbxPath)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .font(.footnote)
            }
        }

        if !state.syncErrors.isEmpty {
            Text("^[\(state.syncErrors.count) sync issue](inflect: true)")
                .font(.footnote)
                .foregroundStyle(.orange)
        }

        Divider()
        HStack {
            Button(state.status == .paused ? "Resume Syncing" : "Pause Syncing") {
                Task {
                    if state.status == .paused {
                        await environment.resume()
                    } else {
                        await environment.pause()
                    }
                }
            }
            Button("Unlink") {
                Task { await environment.unlink() }
            }
        }
    }

    /// The status line of engine-doc §10.
    private var statusText: String {
        switch state.status {
        case .needsSetup: "Not linked"
        case .connecting: "Connecting…"
        case .idle: state.syncErrors.isEmpty ? "Up to date" : "Sync error"
        case .syncing(let detail): detail
        case .paused: "Paused"
        case .fatalError(let error): error.errorDescription ?? "Sync stopped"
        }
    }
}

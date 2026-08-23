import AppKit
import SwiftUI

/// What this is and which version of it (ux §4).
struct AboutTab: View {

    @Bindable var environment: AppEnvironment

    private static let repositoryURL = URL(string: "https://github.com/itsjoshpark/auster")!

    var body: some View {
        VStack(spacing: 12) {
            Spacer()

            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)

            Text("Auster")
                .font(.title)
            Text(Self.versionText)
                .foregroundStyle(.secondary)

            Link("github.com/itsjoshpark/auster", destination: Self.repositoryURL)

            // Hidden rather than disabled where there is no updater at all: a
            // build without Sparkle is updated by whatever installed it, and a
            // dead button would only invite clicking.
            if environment.updater.canCheckForUpdates {
                Button("Check for Updates…") { environment.updater.checkForUpdates() }
            }

            Spacer()

            Text("An open source Dropbox client for macOS.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private static var versionText: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "—"
        let build = info?["CFBundleVersion"] as? String ?? "—"
        return "Version \(version) (\(build))"
    }
}

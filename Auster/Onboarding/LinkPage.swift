import AusterCore
import SwiftUI

/// Page 2 of ux §3, modernized: the browser does the authorizing, and this waits
/// for the `db-<appkey>://` redirect to come back.
struct LinkPage: View {

    @Bindable var model: OnboardingModel

    var body: some View {
        VStack(spacing: 16) {
            Spacer()

            switch model.linkState {
            case .waiting, .idle:
                ProgressView()
                    .controlSize(.large)
                Text("Waiting for authorization…")
                    .font(.title3)
                Text("Auster opened Dropbox in your browser. Approve the request there to continue.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)

            case .failed(let message):
                Image(systemName: "exclamationmark.triangle")
                    .font(.largeTitle)
                    .foregroundStyle(.orange)
                Text("Could not link your account")
                    .font(.title3)
                Text(message)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()

            HStack {
                Button("Cancel") { model.back() }
                Spacer()
                if case .failed = model.linkState {
                    Button("Try Again") { model.beginLink() }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .frame(maxWidth: .infinity)
    }
}

import AusterCore
import SwiftUI

/// Page 1 of ux §3: what this is, and the one thing to do about it.
struct WelcomePage: View {

    @Bindable var model: OnboardingModel

    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            OnboardingIcon()

            Text("Welcome to Auster")
                .font(.title)
            Text("An open source Dropbox client for macOS.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Spacer()

            Button("Link Dropbox Account") { model.beginLink() }
                .keyboardShortcut(.defaultAction)
                .controlSize(.large)
                .disabled(!model.canLink)

            if !model.canLink {
                Text(AppKey.missingKeyMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

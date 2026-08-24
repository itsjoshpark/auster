import AusterCore
import SwiftUI

/// Page 5 of ux §3: sync starts, and the window goes away.
struct DonePage: View {

    @Bindable var model: OnboardingModel
    let onFinished: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            OnboardingIcon()

            Text("You’re all set")
                .font(.title)
            Text(
                """
                Auster is set up. Allow some time for the first indexing and \
                download — the menu bar icon shows what it is doing.
                """
            )
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)

            Spacer()

            Button("Close") {
                // Closing *is* the start: nothing has been written until now, so
                // the wizard must not disappear before it has been.
                Task {
                    await model.finish()
                    onFinished()
                }
            }
            .keyboardShortcut(.defaultAction)
            .controlSize(.large)
        }
        .frame(maxWidth: .infinity)
    }
}

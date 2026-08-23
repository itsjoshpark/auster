import SwiftUI

/// Placeholder contents of the menu bar window.
///
/// Phase 8 replaces this with the real status header, activity list and
/// actions described in `docs/research/maestral-ux.md`.
struct MenuBarContentView: View {

    var body: some View {
        Text("Auster")
            .font(.headline)
            .padding()
            .frame(width: 260)
    }
}

#Preview {
    MenuBarContentView()
}

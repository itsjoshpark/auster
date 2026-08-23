import AusterCore
import SwiftUI

/// Placeholder contents of the menu bar window.
///
/// Phase 8 replaces this with the real status header, activity list and
/// actions described in `docs/research/maestral-ux.md`. Until then it carries
/// just enough to link and unlink an account.
struct MenuBarContentView: View {

    let link: LinkController

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Auster")
                .font(.headline)

            if link.isLinked {
                Text(link.accountDescription ?? "Linked")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Button("Unlink") {
                    Task { await link.unlink() }
                }
            } else {
                Button("Link Dropbox Account…") {
                    link.beginLink()
                }
                .disabled(link.auth == nil)
            }

            if let status = link.status {
                Text(status)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding()
        .frame(width: 260, alignment: .leading)
    }
}

#Preview {
    MenuBarContentView(link: LinkController(auth: nil))
}

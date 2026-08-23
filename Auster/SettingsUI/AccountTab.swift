import AusterCore
import SwiftUI

/// Who Auster is linked to, and the one button that undoes it (ux §4).
struct AccountTab: View {

    @Bindable var environment: AppEnvironment

    @State private var isConfirmingUnlink = false

    private var account: AccountInfo? { environment.state.account }

    var body: some View {
        VStack(spacing: 16) {
            if let account {
                ProfilePhoto(url: account.profilePhotoURL, initials: Self.initials(of: account.displayName))

                VStack(spacing: 2) {
                    Text(account.displayName)
                        .font(.title2)
                    Text("\(account.email) · \(Self.planName(account.accountType))")
                        .foregroundStyle(.secondary)
                }

                Text(environment.state.usageText)
                    .foregroundStyle(.secondary)
            } else {
                ContentUnavailableView(
                    "Account details unavailable",
                    systemImage: "person.crop.circle.badge.questionmark",
                    description: Text("Auster will fill these in the next time it reaches Dropbox.")
                )
            }

            Spacer()

            Button("Unlink this Dropbox…", role: .destructive) { isConfirmingUnlink = true }
                .disabled(!environment.isLinked)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .confirmationDialog("Unlink this Dropbox account?", isPresented: $isConfirmingUnlink) {
            Button("Unlink", role: .destructive) { Task { await environment.unlink() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                """
                Auster will stop syncing and forget this account. The files \
                already in your Dropbox folder stay exactly where they are.
                """
            )
        }
    }

    /// Dropbox reports the plan as a bare identifier; these are the names the
    /// user recognizes from their own account page.
    private static func planName(_ accountType: String) -> String {
        switch accountType {
        case "basic": "Dropbox Basic"
        case "pro": "Dropbox Plus"
        case "business": "Dropbox Business"
        default: accountType.capitalized
        }
    }

    private static func initials(of name: String) -> String {
        let words = name.split(separator: " ").prefix(2)
        return words.compactMap { $0.first }.map(String.init).joined().uppercased()
    }
}

/// The circle-clipped profile picture, with the initials standing in until (or
/// unless) it loads.
private struct ProfilePhoto: View {

    let url: URL?
    let initials: String

    var body: some View {
        AsyncImage(url: url) { image in
            image.resizable().scaledToFill()
        } placeholder: {
            ZStack {
                Circle().fill(.quaternary)
                Text(initials).font(.title2).foregroundStyle(.secondary)
            }
        }
        .frame(width: 72, height: 72)
        .clipShape(.circle)
    }
}

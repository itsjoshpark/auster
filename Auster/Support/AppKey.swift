import Foundation

/// Auster's Dropbox app key, injected at build time.
///
/// The key is not a cryptographic secret — OAuth uses PKCE, so no client secret
/// ships in the app (decisions D3) — but it identifies Josh's developer-console
/// entry, so it stays out of the repository: `Config/Secrets.xcconfig`
/// (gitignored) defines `DROPBOX_APP_KEY`, `Info.plist` carries it through, and
/// this reads it back.
enum AppKey {

    /// The value the committed template ships with, so a developer who has not
    /// copied `Secrets.xcconfig` yet gets told exactly that.
    private static let placeholder = "your_dropbox_app_key_here"

    /// The key, or `nil` when the build has no real one.
    static var value: String? {
        resolve(Bundle.main.object(forInfoDictionaryKey: "DropboxAppKey") as? String)
    }

    /// The OAuth redirect scheme Dropbox requires: the app key prefixed `db-`.
    /// `Info.plist` registers the same string.
    static var redirectScheme: String? {
        value.map { "db-\($0)" }
    }

    /// Explains a missing key in the terms the reader can act on.
    static let missingKeyMessage = """
        Auster was built without a Dropbox app key, so it cannot link an account.

        Copy Config/Secrets.xcconfig.template to Config/Secrets.xcconfig, set \
        DROPBOX_APP_KEY, and build again.
        """

    /// Shared by `value` and its tests: an unset, blank or placeholder key is
    /// no key at all.
    static func resolve(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != placeholder else { return nil }
        return trimmed
    }
}

import Foundation

/// Namespace for constants shared across the engine and the app shell.
/// `AusterCore` is UI-free by design: Foundation, CryptoKit and CoreServices
/// only, never AppKit or SwiftUI.
public enum AusterCore {

    /// Bundle identifier of the shipping app. Used for keychain access groups,
    /// notification identifiers and the login-item registration.
    public static let bundleIdentifier = "com.itsjoshpark.Auster"

    /// Name of the staging directory kept inside the sync folder. Downloads are
    /// written here and moved into place atomically (decisions.md D9.3).
    public static let cacheDirectoryName = ".auster.cache"

    /// Default location of the sync folder, offered during onboarding.
    public static var defaultSyncFolderURL: URL {
        URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appending(path: "Dropbox", directoryHint: .isDirectory)
    }
}

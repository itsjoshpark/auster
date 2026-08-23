import Foundation

/// What never syncs (engine-doc §8).
///
/// Two independent rules, deliberately kept apart because they fail differently:
/// `isExcludedName` is a fixed policy about junk — caches, editor scratch files,
/// Finder metadata — that both directions apply unconditionally, while
/// `isExcluded(byUser:)` is the user's selective-sync choice, which Phase 7 lets
/// them change and which a remote deletion can retract.
public enum Exclusions {

    /// The name of the engine's staging directory. It lives *inside* the Dropbox
    /// folder so downloads can be moved into place atomically (§4.6), which is
    /// exactly why it also has to be excluded from sync.
    public static let cacheDirectoryName = ".auster.cache"

    /// The §8 list, lowercased for comparison.
    ///
    /// Case-insensitive rather than the literal case-sensitive list of the
    /// research doc: Dropbox paths are case-insensitive, so `Desktop.ini` and
    /// `desktop.ini` are one file, and a rule that caught only one spelling
    /// would sync the other. (The doc's list spells two of these twice for the
    /// same reason.)
    private static let excludedNames: Set<String> = [
        "desktop.ini",
        "thumbs.db",
        ".ds_store",
        ".spotlight-v100",
        ".trashes",
        ".fseventd",
        ".localized",
        ".temporaryitems",
        "icon\r",
        ".com.apple.timemachine.supported",
        ".dropbox",
        ".dropbox.attr",
        ".dropbox.cache",
        cacheDirectoryName,
    ]

    /// Whether an item is one Auster never syncs.
    ///
    /// Accepts a bare name or a whole path: *every* component is checked, so
    /// anything inside an excluded folder is excluded with it. Without that, the
    /// staging directory's own contents would be queued for upload.
    public static func isExcludedName(_ pathOrName: String) -> Bool {
        pathOrName
            .split(separator: "/", omittingEmptySubsequences: true)
            .contains { isExcludedComponent(String($0)) }
    }

    private static func isExcludedComponent(_ name: String) -> Bool {
        let lowered = name.lowercased().precomposedStringWithCanonicalMapping
        if excludedNames.contains(lowered) { return true }

        // Editors write their scratch files beside the document, so these
        // appear and vanish inside real sync folders constantly.
        if lowered.hasPrefix("~$") { return true }
        if lowered.hasPrefix(".~") { return true }
        if lowered.hasPrefix("~") && lowered.hasSuffix(".tmp") { return true }
        return false
    }

    /// Whether a path falls inside the user's selective-sync exclusions.
    ///
    /// `excluded` holds normalized (lowercased, NFC) Dropbox paths; the query is
    /// normalized here so a caller may pass either spelling. Matching is on
    /// component boundaries — `"/a"` covers `/a/b` but not `/ab`.
    public static func isExcluded(byUser dbxPathLower: String, excluded: Set<String>) -> Bool {
        guard !excluded.isEmpty else { return false }
        let path = PathStore.normalize(dbxPathLower)

        return excluded.contains { entry in
            path == entry || path.hasPrefix(entry + "/")
        }
    }
}

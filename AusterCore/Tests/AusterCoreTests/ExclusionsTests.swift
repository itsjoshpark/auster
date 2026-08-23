import Foundation
import Testing

@testable import AusterCore

/// The two ways an item is kept out of sync (engine-doc §8): names nobody ever
/// wants synced, and folders the user deselected. Getting either wrong is
/// visible — an over-eager rule silently drops a real file, a lax one uploads
/// `.DS_Store` to every folder — so the whole list is pinned here.
@Suite("Exclusions")
struct ExclusionsTests {

    @Test(
        "Every always-excluded name of engine-doc §8 is excluded",
        arguments: [
            "desktop.ini", "Thumbs.db", "thumbs.db", ".DS_Store", ".ds_store",
            ".Spotlight-V100", ".Trashes", ".fseventd", ".localized", ".TemporaryItems",
            "Icon\r", ".com.apple.timemachine.supported", ".dropbox", ".dropbox.attr",
            ".dropbox.cache", ".auster.cache",
        ]
    )
    func alwaysExcludedNames(name: String) {
        #expect(Exclusions.isExcludedName(name))
    }

    /// Dropbox paths are case-insensitive, so a differently-cased spelling is
    /// the same file and has to be caught by the same rule.
    @Test("Excluded names are matched regardless of case")
    func namesAreCaseInsensitive() {
        #expect(Exclusions.isExcludedName("DESKTOP.INI"))
        #expect(Exclusions.isExcludedName(".ds_STORE"))
    }

    @Test(
        "Editor scratch files are excluded by pattern",
        arguments: ["~$report.docx", ".~lock.sheet.ods#", "~work.tmp", "~WRL0001.TMP"]
    )
    func temporaryPatterns(name: String) {
        #expect(Exclusions.isExcludedName(name))
    }

    @Test(
        "Ordinary names are not excluded",
        arguments: ["report.docx", "notes.tmp", "~report", "icon", "store.ds", "Thumbs.dbx"]
    )
    func ordinaryNames(name: String) {
        #expect(!Exclusions.isExcludedName(name))
    }

    @Test("A full path is judged by its basename")
    func pathsAreJudgedByBasename() {
        #expect(Exclusions.isExcludedName("/Photos/2024/.DS_Store"))
        #expect(!Exclusions.isExcludedName("/Photos/2024/cat.jpg"))
    }

    /// Anything *inside* an excluded folder is excluded too — otherwise the
    /// engine would happily sync the contents of `.dropbox.cache`.
    @Test("An excluded ancestor excludes everything under it")
    func excludedAncestorsCascade() {
        #expect(Exclusions.isExcludedName("/.dropbox.cache/staged/file.txt"))
        #expect(Exclusions.isExcludedName("/.auster.cache/tmp-1"))
    }

    @Test("An empty path is not excluded")
    func emptyPath() {
        #expect(!Exclusions.isExcludedName(""))
        #expect(!Exclusions.isExcludedName("/"))
    }

    // MARK: - User exclusions

    @Test("A user-excluded path excludes itself and its children, not its prefix-mates")
    func userExclusionMatching() {
        let excluded: Set<String> = ["/a"]

        #expect(Exclusions.isExcluded(byUser: "/a", excluded: excluded))
        #expect(Exclusions.isExcluded(byUser: "/a/b", excluded: excluded))
        #expect(Exclusions.isExcluded(byUser: "/a/b/c.txt", excluded: excluded))
        #expect(!Exclusions.isExcluded(byUser: "/ab", excluded: excluded))
        #expect(!Exclusions.isExcluded(byUser: "/b", excluded: excluded))
    }

    @Test("An empty exclusion set excludes nothing")
    func emptyExclusionSet() {
        #expect(!Exclusions.isExcluded(byUser: "/a/b", excluded: []))
    }

    @Test("Any one entry of the set is enough")
    func anyEntryMatches() {
        let excluded: Set<String> = ["/photos", "/work/archive"]

        #expect(Exclusions.isExcluded(byUser: "/work/archive/2024", excluded: excluded))
        #expect(!Exclusions.isExcluded(byUser: "/work/current", excluded: excluded))
    }

    /// The set holds normalized paths, and so must the query: an event's path
    /// arrives cased, and lowercasing it is the caller's job — but a
    /// differently-normalized *Unicode* spelling of the same name is the same
    /// path, and must still match.
    @Test("Matching is normalization-insensitive")
    func normalizationInsensitive() {
        let excluded: Set<String> = [PathStore.normalize("/caf\u{00E9}")]

        #expect(Exclusions.isExcluded(byUser: "/cafe\u{0301}", excluded: excluded))
    }
}

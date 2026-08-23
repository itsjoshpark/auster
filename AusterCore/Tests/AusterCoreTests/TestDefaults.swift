import Foundation

/// Removes a throwaway `UserDefaults` suite, file included.
///
/// `removePersistentDomain(forName:)` empties the domain but leaves
/// `~/Library/Preferences/<suite>.plist` on disk. With a suite per test that is
/// about eleven empty plists per run: 680 of them, 2.7 MB, had accumulated in a
/// developer's home directory by the time anyone looked. Tests clean up after
/// themselves on the filesystem; there is no reason for preferences to be the
/// exception.
func removeTestDefaults(suiteName: String) {
    UserDefaults.standard.removePersistentDomain(forName: suiteName)

    guard
        let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
    else { return }
    let preferences = library.appendingPathComponent("Preferences", isDirectory: true)
    let plist = preferences.appendingPathComponent("\(suiteName).plist", isDirectory: false)
    try? FileManager.default.removeItem(at: plist)
}

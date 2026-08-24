import Foundation

/// Removes a throwaway `UserDefaults` suite, file included:
/// `removePersistentDomain(forName:)` empties the domain but leaves
/// `~/Library/Preferences/<suite>.plist` behind, and there is a suite per test.
func removeTestDefaults(suiteName: String) {
    UserDefaults.standard.removePersistentDomain(forName: suiteName)

    guard
        let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
    else { return }
    let preferences = library.appendingPathComponent("Preferences", isDirectory: true)
    let plist = preferences.appendingPathComponent("\(suiteName).plist", isDirectory: false)
    try? FileManager.default.removeItem(at: plist)
}

import AppKit
import AusterCore

/// The modal Auster shows when it cannot find the user's Dropbox folder
/// (engine-doc §9, ux §9). `NSAlert` because a menu-bar agent may have no window
/// to attach a sheet to. The wording avoids implying anything will be deleted.
@MainActor
enum FatalErrorDialogs {

    /// Asks where the Dropbox folder went.
    ///
    /// - Returns: the user's answer, as the recovery model's own vocabulary.
    static func askAboutMissingFolder(configuredFolder: URL) -> RecoveryModel.FolderMissingChoice {
        let alert = NSAlert()
        alert.messageText = "Your Dropbox folder can’t be found"
        alert.informativeText = """
            Auster expected it at \(configuredFolder.path). If the folder was \
            moved or renamed, or is on a drive that isn't connected, point Auster \
            at it and nothing will be lost.

            Auster has stopped syncing until you choose. Nothing has been deleted \
            from your Dropbox.
            """
        alert.alertStyle = .critical
        alert.addButton(withTitle: "Locate…")
        alert.addButton(withTitle: "Recreate")
        alert.addButton(withTitle: "Quit")

        NSApp.activate(ignoringOtherApps: true)
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            // Cancelling the picker is not an answer, so ask again rather than
            // silently leaving sync stopped with no dialog on screen.
            guard let located = locateFolder(startingAt: configuredFolder) else {
                return askAboutMissingFolder(configuredFolder: configuredFolder)
            }
            return .locate(located)

        case .alertSecondButtonReturn:
            return .recreate

        default:
            return .quit
        }
    }

    /// The folder picker behind "Locate…".
    private static func locateFolder(startingAt folder: URL) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Use This Folder"
        panel.message = "Choose your Dropbox folder."
        panel.directoryURL = folder.deletingLastPathComponent()

        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    /// Says what happened when there is nothing to be done about it.
    static func report(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Auster stopped syncing"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")

        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}

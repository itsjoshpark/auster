import AppKit
import AusterCore

/// Which menu bar glyph a sync status wears (ux §1). A fatal error outranks
/// everything, and per-path sync issues badge the icon only once nothing is in
/// flight — an issue the running cycle is about to clear is not worth alarm.
enum StatusIcon {

    /// The template image set for a status.
    static func assetName(for status: SyncState.Status, hasSyncErrors: Bool) -> String {
        switch status {
        case .fatalError:
            "menubar-error"
        case .syncing:
            "menubar-syncing"
        case .paused:
            "menubar-paused"
        case .connecting, .needsSetup:
            "menubar-offline"
        case .idle:
            hasSyncErrors ? "menubar-error" : "menubar-idle"
        }
    }

    /// The icon as the status bar wants it: a template image at 18 pt, so the
    /// system tints it for light, dark and tinted menu bars. `NSImage` because a
    /// `MenuBarExtra` label takes the artwork at its natural size.
    @MainActor
    static func image(named name: String) -> NSImage? {
        guard let image = NSImage(named: name) else { return nil }
        let sized = image.copy() as! NSImage
        sized.isTemplate = true
        sized.size = NSSize(width: 18, height: 18)
        return sized
    }
}

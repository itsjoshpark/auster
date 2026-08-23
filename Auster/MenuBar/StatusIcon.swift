import AppKit
import AusterCore

/// Which menu bar glyph a sync status wears (ux §1).
///
/// A pure mapping in its own type because it is the one piece of the interface
/// that is always on screen and never read carefully: the user glances at it and
/// decides whether to worry. The two rules worth stating out loud are that a
/// fatal error outranks everything, and that per-path sync issues badge the icon
/// only once nothing is in flight — an issue that the running cycle is about to
/// clear is not worth alarming anyone about (engine-doc §10).
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
    /// system tints it for light, dark and tinted menu bars (design README).
    ///
    /// `NSImage` rather than a SwiftUI `Image` because a `MenuBarExtra` label
    /// takes the artwork at its natural size, and the artwork is drawn on a
    /// 36-point canvas.
    @MainActor
    static func image(named name: String) -> NSImage? {
        guard let image = NSImage(named: name) else { return nil }
        let sized = image.copy() as! NSImage
        sized.isTemplate = true
        sized.size = NSSize(width: 18, height: 18)
        return sized
    }
}

import Foundation
import ServiceManagement

/// The "Start at login" toggle, over `SMAppService` (ux §9). `setEnabled`
/// reports failure rather than swallowing it, and `isEnabled` always asks the
/// service: the user can turn Auster off in System Settings.
enum LoginItem {

    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Whether macOS is refusing to act on the setting at all — the case where
    /// the user has to go to System Settings, not to Auster's own switch.
    static var requiresApproval: Bool {
        SMAppService.mainApp.status == .requiresApproval
    }

    /// - Throws: whatever `SMAppService` refused with, so the caller can say so.
    static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}

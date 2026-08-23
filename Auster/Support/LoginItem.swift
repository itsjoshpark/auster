import Foundation
import ServiceManagement

/// The "Start at login" toggle, over `SMAppService` (ux §9).
///
/// Registration can fail for reasons the user can act on — an unsigned build, or
/// a login item they disabled in System Settings — so `setEnabled` reports
/// rather than swallows, and `isEnabled` always answers from the service instead
/// of from a remembered preference. The system is the source of truth here: the
/// user can turn Auster off in System Settings without ever opening Auster.
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

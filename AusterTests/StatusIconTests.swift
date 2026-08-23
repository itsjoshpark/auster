import AusterCore
import Testing

@testable import Auster

/// The menu bar icon's state mapping (ux §1).
///
/// Worth its own tests because the icon is the only part of Auster most users
/// look at: it is the whole status report for someone who never opens the menu,
/// and a wrong glyph is a wrong answer to "is my work backed up?".
@Suite("Status icon")
struct StatusIconTests {

    @Test("each engine status maps to its template icon")
    func statusesMapToAssets() {
        #expect(StatusIcon.assetName(for: .idle, hasSyncErrors: false) == "menubar-idle")
        #expect(StatusIcon.assetName(for: .syncing(detail: "Syncing…"), hasSyncErrors: false) == "menubar-syncing")
        #expect(StatusIcon.assetName(for: .paused, hasSyncErrors: false) == "menubar-paused")
        #expect(StatusIcon.assetName(for: .connecting, hasSyncErrors: false) == "menubar-offline")
        #expect(StatusIcon.assetName(for: .fatalError(.notAuthorized), hasSyncErrors: false) == "menubar-error")
    }

    /// Before an account exists there is nothing to report on, and the dimmed
    /// icon says "not working yet" rather than "up to date".
    @Test("an unconfigured app shows the offline icon")
    func needsSetupIsOffline() {
        #expect(StatusIcon.assetName(for: .needsSetup, hasSyncErrors: false) == "menubar-offline")
    }

    /// The badge means "sync finished, and these items did not" — so it appears
    /// only once there is nothing in flight that might still fix them
    /// (engine-doc §10).
    @Test("sync issues badge the icon only when idle")
    func errorBadgeOnlyWhenIdle() {
        #expect(StatusIcon.assetName(for: .idle, hasSyncErrors: true) == "menubar-error")
        #expect(StatusIcon.assetName(for: .syncing(detail: "Syncing…"), hasSyncErrors: true) == "menubar-syncing")
        #expect(StatusIcon.assetName(for: .paused, hasSyncErrors: true) == "menubar-paused")
        #expect(StatusIcon.assetName(for: .connecting, hasSyncErrors: true) == "menubar-offline")
    }

    /// A fatal error outranks everything: sync has stopped, and no per-path
    /// issue is more important than saying so.
    @Test("a fatal error shows the error icon whatever else is true")
    func fatalErrorWins() {
        #expect(StatusIcon.assetName(for: .fatalError(.dropboxFolderMissing), hasSyncErrors: true) == "menubar-error")
    }

    @MainActor
    @Test("every mapped asset exists in the bundle")
    func assetsAreBundled() {
        let statuses: [SyncState.Status] = [
            .needsSetup, .connecting, .idle, .syncing(detail: "Syncing…"), .paused,
            .fatalError(.notAuthorized),
        ]
        for status in statuses {
            for hasErrors in [true, false] {
                let name = StatusIcon.assetName(for: status, hasSyncErrors: hasErrors)
                #expect(StatusIcon.image(named: name) != nil, "missing asset \(name)")
            }
        }
    }
}

import Foundation
import Observation

/// Where Sparkle will be (Phase 10).
///
/// A real type rather than a commented-out block, because the interface has to
/// decide *now* what to show when there is no updater: an app installed from a
/// package manager, or run from a build directory, has none either, so
/// "unavailable" is a permanent state and not just a Phase 9 one. Controls bound
/// to this hide or disable themselves rather than offering a button that cannot
/// do anything.
@MainActor
@Observable
final class UpdaterController {

    /// Whether update checks can run at all. Phase 10 makes this true when a
    /// Sparkle updater has started successfully.
    var canCheckForUpdates: Bool { false }

    func checkForUpdates() {}
}

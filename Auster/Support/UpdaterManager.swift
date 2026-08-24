import AusterCore
import Foundation
import Observation
import Sparkle

/// Sparkle, and the two things the interface asks of it. The updater is started
/// by hand because starting can fail, and Sparkle's own start would answer that
/// with an alert at launch; a failure just leaves `canCheckForUpdates` false.
@MainActor
@Observable
final class UpdaterManager {

    /// Whether an update check can run right now. False where Sparkle never
    /// started, and while a check is already in flight.
    private(set) var canCheckForUpdates = false

    @ObservationIgnored private let controller: SPUStandardUpdaterController?
    @ObservationIgnored private var availability: NSKeyValueObservation?

    /// - Parameter checkInterval: the "Check for updates" setting to start with.
    init(checkInterval: UpdateCheckInterval = .daily) {
        let controller = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )

        do {
            try controller.updater.start()
        } catch {
            // Nothing to recover: this build cannot update itself, and every
            // control bound to `canCheckForUpdates` already hides itself.
            self.controller = nil
            return
        }

        self.controller = controller
        observeAvailability(of: controller.updater)
        apply(checkInterval: checkInterval)
    }

    /// Runs a user-initiated check, with Sparkle's own progress and dialogs.
    func checkForUpdates() {
        controller?.updater.checkForUpdates()
    }

    /// Binds automatic checks to the setting (ux §4). Sparkle would otherwise ask
    /// the user on first launch whether to check automatically; writing the flag
    /// here answers from the preference, so there is only ever one switch.
    func apply(checkInterval: UpdateCheckInterval) {
        guard let updater = controller?.updater else { return }
        if let duration = checkInterval.duration {
            updater.updateCheckInterval = duration
            updater.automaticallyChecksForUpdates = true
        } else {
            updater.automaticallyChecksForUpdates = false
        }
    }

    /// Mirrors Sparkle's KVO property onto an observable one, so a menu row
    /// re-enables itself when a check finishes.
    private func observeAvailability(of updater: SPUUpdater) {
        canCheckForUpdates = updater.canCheckForUpdates
        // The new value rather than a second read of the updater: Sparkle posts
        // these on the main thread, but the observation closure is `Sendable`
        // and may not touch a main-actor object to find out.
        availability = updater.observe(\.canCheckForUpdates, options: [.new]) { [weak self] _, change in
            guard let canCheck = change.newValue else { return }
            MainActor.assumeIsolated { self?.canCheckForUpdates = canCheck }
        }
    }
}

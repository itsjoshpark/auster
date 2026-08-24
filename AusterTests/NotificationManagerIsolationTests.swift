import AusterCore
import Foundation
import Testing

@testable import Auster

/// The composer's closures read `@MainActor` state through
/// `MainActor.assumeIsolated`, and `SyncNotifying` is called from the
/// coordinator's actor, so composing on the caller's executor traps.
@Suite("NotificationManager isolation")
struct NotificationManagerIsolationTests {

    /// A box the composer's closures write to from wherever they are called.
    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var _wasMain: Bool?
        var wasMain: Bool? {
            get { lock.withLock { _wasMain } }
            set { lock.withLock { _wasMain = newValue } }
        }
    }

    /// Suppressing change notifications is enough: `downloadBatch` reads the
    /// suppression closure first, so nothing reaches `UNUserNotificationCenter`
    /// and no permission prompt appears.
    private func makeManager(_ recorder: Recorder) -> NotificationManager {
        NotificationManager(
            composer: NotificationComposer(
                ownAccountId: { nil },
                changeNotificationsSuppressed: {
                    recorder.wasMain = Thread.isMainThread
                    return true
                }
            ),
            reveal: { _ in }
        )
    }

    @Test("a download batch composed from a background actor still reads its inputs on the main actor")
    func composesOnMainActorFromBackground() async throws {
        let recorder = Recorder()
        let manager = makeManager(recorder)

        // Exactly how SyncCoordinator calls it: from an actor that is not the
        // main one.
        actor Caller {
            func notify(_ manager: NotificationManager) {
                manager.notifyDownloadBatch([
                    SyncItemEvent(
                        direction: .down,
                        changeType: .added,
                        itemType: .file,
                        dbxPath: "/Notes/kickoff.txt",
                        dbxPathLower: "/notes/kickoff.txt",
                        localURL: URL(fileURLWithPath: "/tmp/Dropbox/Notes/kickoff.txt")
                    )
                ])
            }
        }
        await Caller().notify(manager)

        try await waitUntil { recorder.wasMain != nil }
        #expect(recorder.wasMain == true)
    }

    private func waitUntil(
        timeout: Duration = .seconds(2),
        _ condition: @Sendable () -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("condition was never met")
    }
}

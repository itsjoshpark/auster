import Foundation
import Synchronization
import Testing

@testable import AusterCore

/// Reading stored credentials touches the keychain, which blocks until the user
/// answers a permission prompt — every launch after the code signature changes.
/// On the main actor that takes the whole app down with it: no menu bar icon,
/// no windows, no sync, and nothing on screen to explain why.
/// Blocks the calling thread, which is what a synchronous keychain call does.
private func park(until ready: () -> Bool) {
    while !ready() { Thread.sleep(forTimeInterval: 0.01) }
}

@Suite("Auth restore isolation", .timeLimit(.minutes(1)))
struct AuthRestoreIsolationTests {

    /// A store whose credential read blocks the way a keychain prompt does.
    private final class BlockingLinkStore: DropboxLinkStore {

        private let reading = Mutex(false)
        private let mayFinish = Mutex(false)

        var isReading: Bool { reading.withLock { $0 } }

        func release() { mayFinish.withLock { $0 = true } }

        func storedService() async -> (any DropboxService)? {
            reading.withLock { $0 = true }
            // Parks the thread it is running on, as the keychain does.
            park(until: { self.mayFinish.withLock { $0 } })
            return nil
        }

        @MainActor func beginAuthorization(scopes: [String]) {}
        func completeAuthorization(url: URL) async -> AuthorizationResult { .unrecognizedURL }
        @MainActor func clearCredentials() {}
    }

    @Test("the main actor keeps running while stored credentials are read")
    @MainActor
    func restoreLeavesTheMainActorFree() async throws {
        let store = BlockingLinkStore()
        let manager = AuthManager(store: store)

        let restoring = Task { await manager.restore() }
        await Task.detached { park(until: { store.isReading }) }.value

        // With the read on the main actor this never returns: the hop cannot be
        // scheduled behind a thread that is parked in `SecItemCopyMatching`.
        var ranWhileBlocked = false
        await MainActor.run { ranWhileBlocked = true }
        #expect(ranWhileBlocked)

        store.release()
        await restoring.value
        #expect(manager.isLinked == false)
    }
}

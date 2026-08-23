import Foundation
import Testing

@testable import AusterCore

/// Retry policy is the difference between a flaky network and a stalled sync,
/// and between a transient 429 and a hammered API. Timing is driven by an
/// injected sleeper so these run instantly and assert exact delays.
@Suite("Retry")
struct RetryTests {

    /// Records what it was asked to wait for instead of waiting.
    private final class FakeSleeper: RetrySleeper, @unchecked Sendable {
        private let lock = NSLock()
        private var recorded: [TimeInterval] = []

        var delays: [TimeInterval] { lock.withLock { recorded } }

        func sleep(for seconds: TimeInterval) async throws {
            lock.withLock { recorded.append(seconds) }
        }
    }

    /// Counts attempts across the retry loop.
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0

        var count: Int { lock.withLock { value } }

        @discardableResult
        func increment() -> Int {
            lock.withLock {
                value += 1
                return value
            }
        }
    }

    /// Jitter pinned to the midpoint, so delays are the un-jittered values.
    private let noJitter: @Sendable () -> Double = { 0.5 }

    private func policy(
        maxAttempts: Int = 10,
        baseDelay: TimeInterval = 1,
        maxDelay: TimeInterval = 60,
        jitter: Double = 0.25
    ) -> RetryPolicy {
        RetryPolicy(maxAttempts: maxAttempts, baseDelay: baseDelay, maxDelay: maxDelay, jitter: jitter)
    }

    // MARK: - Success

    @Test("a call that succeeds runs once and never sleeps")
    func succeedsFirstTime() async throws {
        let sleeper = FakeSleeper()
        let attempts = Counter()

        let result = try await withRetry(policy: policy(), sleeper: sleeper, randomFraction: noJitter) {
            attempts.increment()
            return 42
        }

        #expect(result == 42)
        #expect(attempts.count == 1)
        #expect(sleeper.delays.isEmpty)
    }

    @Test("a transient failure is retried and the eventual result is returned")
    func retriesThenSucceeds() async throws {
        let sleeper = FakeSleeper()
        let attempts = Counter()

        let result = try await withRetry(policy: policy(), sleeper: sleeper, randomFraction: noJitter) {
            if attempts.increment() < 3 { throw DropboxServiceError.connection }
            return "done"
        }

        #expect(result == "done")
        #expect(attempts.count == 3)
        #expect(sleeper.delays == [1, 2])
    }

    // MARK: - What is and is not retried

    @Test(
        "a failure the caller cannot recover from is rethrown immediately",
        arguments: [
            DropboxServiceError.notFound(path: "/a"),
            .notAuthorized,
            .insufficientSpace,
            .conflict(path: "/a"),
            .disallowedName(path: "/a"),
            .malformedPath(path: "/a"),
            .restrictedContent(path: "/a"),
            .fileChangedDuringUpload(path: "/a"),
            .cursorReset,
            .other(message: "nope"),
        ]
    )
    func doesNotRetryTerminalErrors(error: DropboxServiceError) async {
        let sleeper = FakeSleeper()
        let attempts = Counter()

        await #expect(throws: error) {
            try await withRetry(policy: policy(), sleeper: sleeper, randomFraction: noJitter) {
                attempts.increment()
                throw error
            }
        }

        #expect(attempts.count == 1)
        #expect(sleeper.delays.isEmpty)
    }

    @Test(
        "a transient failure is retried up to the attempt budget",
        arguments: [
            DropboxServiceError.connection,
            .tooManyWriteOperations,
            .dataCorrupted(path: "/a"),
            .rateLimited(retryAfter: 1),
        ]
    )
    func retriesTransientErrors(error: DropboxServiceError) async {
        let sleeper = FakeSleeper()
        let attempts = Counter()

        await #expect(throws: error) {
            try await withRetry(policy: policy(maxAttempts: 4), sleeper: sleeper, randomFraction: noJitter) {
                attempts.increment()
                throw error
            }
        }

        #expect(attempts.count == 4)
        #expect(sleeper.delays.count == 3)
    }

    @Test("the standard policy gives corruption and write contention ten attempts")
    func standardPolicyBudget() async {
        #expect(RetryPolicy.standard.maxAttempts == 10)

        let sleeper = FakeSleeper()
        let attempts = Counter()
        await #expect(throws: DropboxServiceError.dataCorrupted(path: "/a")) {
            try await withRetry(policy: .standard, sleeper: sleeper, randomFraction: noJitter) {
                attempts.increment()
                throw DropboxServiceError.dataCorrupted(path: "/a")
            }
        }
        #expect(attempts.count == 10)
    }

    @Test("a policy of one attempt never retries")
    func neverPolicy() async {
        let sleeper = FakeSleeper()
        let attempts = Counter()

        await #expect(throws: DropboxServiceError.connection) {
            try await withRetry(policy: .never, sleeper: sleeper, randomFraction: noJitter) {
                attempts.increment()
                throw DropboxServiceError.connection
            }
        }

        #expect(attempts.count == 1)
        #expect(sleeper.delays.isEmpty)
    }

    @Test("an error from outside the service layer is never retried")
    func foreignErrorsPropagate() async {
        struct Boom: Error, Equatable {}
        let sleeper = FakeSleeper()
        let attempts = Counter()

        await #expect(throws: Boom.self) {
            try await withRetry(policy: policy(), sleeper: sleeper, randomFraction: noJitter) {
                attempts.increment()
                throw Boom()
            }
        }

        #expect(attempts.count == 1)
        #expect(sleeper.delays.isEmpty)
    }

    @Test("cancellation stops the loop instead of being retried")
    func cancellationPropagates() async {
        let sleeper = FakeSleeper()
        let attempts = Counter()

        await #expect(throws: CancellationError.self) {
            try await withRetry(policy: policy(), sleeper: sleeper, randomFraction: noJitter) {
                attempts.increment()
                throw CancellationError()
            }
        }

        #expect(attempts.count == 1)
    }

    // MARK: - Delays

    @Test("delays grow exponentially and stop at the ceiling")
    func exponentialBackoffIsCapped() async {
        let sleeper = FakeSleeper()

        await #expect(throws: DropboxServiceError.connection) {
            try await withRetry(
                policy: policy(maxAttempts: 7, baseDelay: 1, maxDelay: 8),
                sleeper: sleeper,
                randomFraction: noJitter
            ) {
                throw DropboxServiceError.connection
            }
        }

        #expect(sleeper.delays == [1, 2, 4, 8, 8, 8])
    }

    @Test("a rate limit is honored for exactly as long as the server asked")
    func honorsRetryAfter() async {
        let sleeper = FakeSleeper()

        await #expect(throws: DropboxServiceError.rateLimited(retryAfter: 30)) {
            try await withRetry(
                policy: policy(maxAttempts: 3, baseDelay: 1),
                sleeper: sleeper,
                randomFraction: noJitter
            ) {
                throw DropboxServiceError.rateLimited(retryAfter: 30)
            }
        }

        #expect(sleeper.delays == [30, 30])
    }

    @Test("a rate limit longer than the ceiling is still waited out in full")
    func retryAfterIgnoresCeiling() async {
        let sleeper = FakeSleeper()

        await #expect(throws: DropboxServiceError.rateLimited(retryAfter: 300)) {
            try await withRetry(
                policy: policy(maxAttempts: 2, baseDelay: 1, maxDelay: 8),
                sleeper: sleeper,
                randomFraction: noJitter
            ) {
                throw DropboxServiceError.rateLimited(retryAfter: 300)
            }
        }

        #expect(sleeper.delays == [300])
    }

    @Test("jitter spreads the delay symmetrically around the computed value")
    func jitterBounds() async {
        for (fraction, expected) in [(0.0, 0.5), (1.0, 1.5)] {
            let sleeper = FakeSleeper()
            await #expect(throws: DropboxServiceError.connection) {
                try await withRetry(
                    policy: policy(maxAttempts: 2, baseDelay: 1, jitter: 0.5),
                    sleeper: sleeper,
                    randomFraction: { fraction }
                ) {
                    throw DropboxServiceError.connection
                }
            }
            #expect(sleeper.delays == [expected])
        }
    }

    @Test("a delay is never negative, whatever the jitter")
    func jitterNeverGoesNegative() async {
        let sleeper = FakeSleeper()

        await #expect(throws: DropboxServiceError.connection) {
            try await withRetry(
                policy: policy(maxAttempts: 2, baseDelay: 1, jitter: 2),
                sleeper: sleeper,
                randomFraction: { 0 }
            ) {
                throw DropboxServiceError.connection
            }
        }

        #expect(sleeper.delays == [0])
    }
}

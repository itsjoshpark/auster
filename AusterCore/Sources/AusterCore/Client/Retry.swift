import Foundation

/// How hard to try again after a failure that might not repeat.
///
/// Dropbox asks clients to back off exponentially with jitter (api-notes §5).
/// Jitter matters more than it looks: without it, a folder full of files that
/// all fail at once would retry in lockstep forever.
public struct RetryPolicy: Sendable, Equatable {

    /// Total attempts, including the first. `1` disables retrying.
    public var maxAttempts: Int

    /// Delay before the second attempt; doubles from there.
    public var baseDelay: TimeInterval

    /// Ceiling for the exponential growth. A server-supplied `retryAfter` is
    /// honored in full and ignores this.
    public var maxDelay: TimeInterval

    /// How far a delay is randomised either side of its computed value, as a
    /// fraction of that value. `0.25` means ±25%.
    public var jitter: Double

    public init(
        maxAttempts: Int = 10,
        baseDelay: TimeInterval = 1,
        maxDelay: TimeInterval = 60,
        jitter: Double = 0.25
    ) {
        self.maxAttempts = maxAttempts
        self.baseDelay = baseDelay
        self.maxDelay = maxDelay
        self.jitter = jitter
    }

    /// The default for transfers and mutations: ten attempts, which is the
    /// budget api-notes §5 gives a corrupted transfer.
    public static let standard = RetryPolicy()

    /// One attempt. For calls whose caller wants to handle failure itself —
    /// longpolling, say, which has its own backoff loop.
    public static let never = RetryPolicy(maxAttempts: 1)
}

/// Where waiting happens, so tests can assert delays instead of enduring them.
///
/// The longpoll loop uses this too, for the server-supplied `backoff` that
/// arrives in a longpoll response rather than in an error.
public protocol RetrySleeper: Sendable {
    func sleep(for seconds: TimeInterval) async throws
}

/// The real clock.
public struct SystemSleeper: RetrySleeper {
    public init() {}

    public func sleep(for seconds: TimeInterval) async throws {
        guard seconds > 0 else { return }
        try await Task.sleep(for: .seconds(seconds))
    }
}

/// Runs `operation`, repeating it while it fails in a way that waiting might fix.
///
/// Only `DropboxServiceError`s the service layer marked retryable are repeated;
/// everything else — including cancellation and errors from outside the service
/// layer — propagates on the first attempt, because retrying a `notFound` or a
/// `notAuthorized` just delays the real answer.
///
/// `randomFraction` is the source of jitter, in `0...1`. It is injectable so
/// delays are deterministic under test.
public func withRetry<T>(
    policy: RetryPolicy = .standard,
    sleeper: any RetrySleeper = SystemSleeper(),
    randomFraction: @escaping @Sendable () -> Double = { Double.random(in: 0...1) },
    operation: () async throws -> T
) async throws -> T {
    var attempt = 1
    while true {
        do {
            return try await operation()
        } catch let error as DropboxServiceError where error.isRetryable {
            guard attempt < policy.maxAttempts else { throw error }
            try await sleeper.sleep(
                for: delay(for: error, attempt: attempt, policy: policy, randomFraction: randomFraction)
            )
            attempt += 1
        }
    }
}

/// The wait before the attempt following `attempt`.
///
/// A rate limit carries the server's own answer, which is honored exactly and
/// is not subject to `maxDelay` — the server knows better than the ceiling does.
private func delay(
    for error: DropboxServiceError,
    attempt: Int,
    policy: RetryPolicy,
    randomFraction: @Sendable () -> Double
) -> TimeInterval {
    let base: TimeInterval
    if case .rateLimited(let retryAfter) = error {
        base = retryAfter
    } else {
        base = min(policy.maxDelay, policy.baseDelay * pow(2, Double(attempt - 1)))
    }

    let spread = policy.jitter * (2 * randomFraction() - 1)
    return max(0, base * (1 + spread))
}

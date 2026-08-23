import Foundation

/// Drops the filesystem events the engine caused itself (engine-doc §5.2).
///
/// This is the single most load-bearing piece of the two-way loop. FSEvents
/// reports *that* a file changed, never *who* changed it, so without this every
/// download would land on disk, be seen as a local change, and be uploaded
/// straight back — forever. Each engine mutation therefore declares the events it
/// is about to cause, and the first matching delivery of each is swallowed.
///
/// Two details make it correct rather than merely plausible:
///
/// - A declaration outlives its operation by `registrationLifetime`, because
///   FSEvents batches and can deliver seconds late. The clock only starts when
///   the operation *ends*, so a slow copy of a large file is not raced by its own
///   expiry.
/// - Directory operations register recursively and are never consumed: deleting a
///   folder produces an unknowable number of child events, so the registration
///   has to keep matching until it expires rather than after the first hit.
///
/// A class, not an actor: `FileEventIgnoring` wraps synchronous mutations, and
/// the FSEvents callback that consults it runs on a dispatch queue with nowhere
/// to await.
public final class IgnoreFilter: FileEventIgnoring, @unchecked Sendable {

    /// How long a declaration keeps matching after its operation finishes.
    ///
    /// Long enough to cover FSEvents' batching latency, short enough that a real
    /// user edit moments later is not mistaken for our echo.
    public static let registrationLifetime: TimeInterval = 2

    private struct Registration {
        let expected: ExpectedFSEvent
        /// Which `ignoring` call this came from, so the alternatives declared by
        /// one operation can be retired together.
        let callID: Int
        /// `nil` while the operation is still running — an unfinished operation
        /// can never be stale.
        var expiresAt: Date?
    }

    private let lock = NSLock()
    private var registrations: [Int: Registration] = [:]
    private var nextID = 0
    private let now: @Sendable () -> Date

    /// - Parameter now: the clock, injectable so expiry can be tested exactly
    ///   rather than slept through.
    public init(now: @escaping @Sendable () -> Date = { Date() }) {
        self.now = now
    }

    /// How many declarations are currently outstanding. For tests and diagnostics.
    public var registrationCount: Int {
        lock.withLock { registrations.count }
    }

    // MARK: - Declaring

    public func ignoring<T>(_ expected: [ExpectedFSEvent], _ body: () throws -> T) rethrows -> T {
        let ids = lock.withLock { () -> [Int] in
            nextID += 1
            let callID = nextID
            return expected.map { event -> Int in
                nextID += 1
                registrations[nextID] = Registration(expected: event, callID: callID, expiresAt: nil)
                return nextID
            }
        }

        // `defer`, not a trailing statement: if the body throws, the mutation may
        // well have happened anyway, and its echo is still ours to swallow.
        defer {
            let deadline = now().addingTimeInterval(Self.registrationLifetime)
            lock.withLock {
                for id in ids {
                    registrations[id]?.expiresAt = deadline
                }
            }
        }

        return try body()
    }

    // MARK: - Filtering

    /// Whether this event is an echo of something the engine did.
    ///
    /// Consumes the matching declaration unless it is recursive.
    public func shouldDrop(_ event: RawFSEvent) -> Bool {
        let currentTime = now()

        return lock.withLock {
            discardExpired(asOf: currentTime)

            guard let id = registrations.first(where: { Self.matches($0.value.expected, event) })?.key,
                let matched = registrations[id]
            else {
                return false
            }
            guard !matched.expected.recursive else { return true }

            // Matching one declaration retires all of them from that call. The
            // several declarations of one operation are alternative *descriptions*
            // of a single event — a `rename(2)` over an existing file surfaces as
            // a rename of the source, or a creation of the destination, or a
            // modification of it, depending on what was there and how FSEvents
            // chose to coalesce. Exactly one arrives; leaving the others
            // registered would let them swallow the user's next edit to the same
            // file, seconds later.
            registrations = registrations.filter { _, registration in
                registration.callID != matched.callID
            }
            return true
        }
    }

    /// Drops declarations whose lifetime has run out.
    ///
    /// Called on every filtered event anyway; exposed so an idle monitor can
    /// still let go of a registration for an operation nothing echoed.
    public func expireStale() {
        let currentTime = now()
        lock.withLock { discardExpired(asOf: currentTime) }
    }

    private func discardExpired(asOf currentTime: Date) {
        registrations = registrations.filter { _, registration in
            guard let expiresAt = registration.expiresAt else { return true }
            return expiresAt > currentTime
        }
    }

    // MARK: - Matching

    private static func matches(_ expected: ExpectedFSEvent, _ event: RawFSEvent) -> Bool {
        expected.recursive
            ? matchesRecursively(expected, event)
            : matchesExactly(expected, event)
    }

    private static func matchesExactly(_ expected: ExpectedFSEvent, _ event: RawFSEvent) -> Bool {
        guard samePath(expected.url, event.url) else { return false }

        switch (expected.kind, event.kind) {
        case (.created, .created), (.deleted, .deleted), (.modified, .modified):
            return true
        case (.moved(let expectedDestination), .moved(let destination)):
            return samePath(expectedDestination, destination)
        default:
            return false
        }
    }

    /// Compares locations, not `URL` values.
    ///
    /// Two `URL`s for one item can differ in their directory hint — `URL`'s
    /// path-appending API stats the filesystem and adds a trailing slash for
    /// directories — so `==` would say a folder the engine created is not the
    /// folder FSEvents just reported.
    private static func samePath(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.standardizedFileURL.pathComponents == rhs.standardizedFileURL.pathComponents
    }

    /// A directory operation covers the directory itself and everything under it.
    private static func matchesRecursively(_ expected: ExpectedFSEvent, _ event: RawFSEvent) -> Bool {
        switch (expected.kind, event.kind) {
        case (.created, .created), (.deleted, .deleted), (.modified, .modified):
            return isSelfOrDescendant(event.url, of: expected.url)

        case (.moved(let expectedDestination), .moved(let destination)):
            // Both halves have to land inside the move. A child that went
            // somewhere else was moved by the user, mid-operation.
            return isSelfOrDescendant(event.url, of: expected.url)
                && isSelfOrDescendant(destination, of: expectedDestination)

        default:
            return false
        }
    }

    /// Containment on component boundaries, so `Photos` never covers
    /// `PhotosArchive`.
    private static func isSelfOrDescendant(_ url: URL, of ancestor: URL) -> Bool {
        let components = url.standardizedFileURL.pathComponents
        let ancestorComponents = ancestor.standardizedFileURL.pathComponents
        guard components.count >= ancestorComponents.count else { return false }
        return Array(components.prefix(ancestorComponents.count)) == ancestorComponents
    }
}

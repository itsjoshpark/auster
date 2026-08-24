import Foundation
import Testing

@testable import AusterCore

/// The mechanism that stops the engine hearing its own footsteps (engine-doc
/// §5.2). Wrong one way, every download re-uploads itself; wrong the other, a
/// real user edit is swallowed.
@Suite("IgnoreFilter")
struct IgnoreFilterTests {

    /// A clock the test advances by hand, so TTL expiry is exact instead of slept for.
    private final class TestClock: @unchecked Sendable {
        private let lock = NSLock()
        private var storage = Date(timeIntervalSince1970: 1_000)

        var now: Date { lock.withLock { storage } }
        func advance(_ interval: TimeInterval) { lock.withLock { storage += interval } }
        var reader: @Sendable () -> Date { { [self] in now } }
    }

    private let root = URL(fileURLWithPath: "/Dropbox")

    private func url(_ path: String) -> URL {
        root.appendingPathComponent(path)
    }

    private func expected(
        _ kind: ExpectedFSEvent.Kind,
        _ path: String,
        isDirectory: Bool = false,
        recursive: Bool = false
    ) -> ExpectedFSEvent {
        ExpectedFSEvent(kind: kind, url: url(path), isDirectory: isDirectory, recursive: recursive)
    }

    private func raw(_ kind: RawFSEvent.Kind, _ path: String, isDirectory: Bool = false) -> RawFSEvent {
        RawFSEvent(kind: kind, url: url(path), isDirectory: isDirectory)
    }

    // MARK: - One-shot matching

    @Test("A declared event is dropped")
    func declaredEventIsDropped() {
        let filter = IgnoreFilter()
        filter.ignoring([expected(.created, "a.txt")]) {}

        #expect(filter.shouldDrop(raw(.created, "a.txt")))
    }

    /// The engine writes a file once; if the user then writes it again, that
    /// second event is theirs and has to get through.
    @Test("Only the first matching event is dropped")
    func matchIsConsumed() {
        let filter = IgnoreFilter()
        filter.ignoring([expected(.created, "a.txt")]) {}

        #expect(filter.shouldDrop(raw(.created, "a.txt")))
        #expect(!filter.shouldDrop(raw(.created, "a.txt")))
    }

    @Test("An event for another path passes through")
    func otherPathPassesThrough() {
        let filter = IgnoreFilter()
        filter.ignoring([expected(.created, "a.txt")]) {}

        #expect(!filter.shouldDrop(raw(.created, "b.txt")))
    }

    @Test("An event of another kind passes through")
    func otherKindPassesThrough() {
        let filter = IgnoreFilter()
        filter.ignoring([expected(.created, "a.txt")]) {}

        #expect(!filter.shouldDrop(raw(.deleted, "a.txt")))
    }

    @Test("Nothing is dropped when nothing was declared")
    func undeclaredEventPassesThrough() {
        #expect(!IgnoreFilter().shouldDrop(raw(.modified, "a.txt")))
    }

    /// One `rename(2)` surfaces as a rename, a creation, or a modification
    /// depending on what was there and how FSEvents coalesced — so an operation
    /// declares all of them, and exactly one arrives.
    @Test("The events declared by one call are alternatives, and any of them matches")
    func declarationsAreAlternatives() {
        for arriving in [RawFSEvent.Kind.created, .modified] {
            let filter = IgnoreFilter()
            filter.ignoring([expected(.created, "a.txt"), expected(.modified, "a.txt")]) {}

            #expect(filter.shouldDrop(RawFSEvent(kind: arriving, url: url("a.txt"), isDirectory: false)))
        }
    }

    /// The failure this prevents: a download declares three ways of describing
    /// its write, one of them matches, and the leftovers sit there for two
    /// seconds waiting to swallow whatever the user does to that file next.
    @Test("Matching one declaration retires the alternatives it was declared with")
    func matchingRetiresTheAlternatives() {
        let filter = IgnoreFilter()
        filter.ignoring([
            ExpectedFSEvent(kind: .moved(to: url("a.txt")), url: url("staged"), isDirectory: false, recursive: false),
            expected(.created, "a.txt"),
            expected(.modified, "a.txt"),
        ]) {}

        #expect(filter.shouldDrop(raw(.moved(to: url("a.txt")), "staged")))
        // The user's own edit, moments later, must get through.
        #expect(!filter.shouldDrop(raw(.modified, "a.txt")))
        #expect(filter.registrationCount == 0)
    }

    @Test("Separate calls each drop their own event")
    func separateCallsAreIndependent() {
        let filter = IgnoreFilter()
        filter.ignoring([expected(.deleted, "a.txt")]) {}
        filter.ignoring([expected(.created, "a.txt")]) {}

        #expect(filter.shouldDrop(raw(.deleted, "a.txt")))
        #expect(filter.shouldDrop(raw(.created, "a.txt")))
    }

    // MARK: - Moves

    @Test("A declared move is matched on both its source and its destination")
    func moveMatchesOnBothPaths() {
        let filter = IgnoreFilter()
        filter.ignoring([
            ExpectedFSEvent(kind: .moved(to: url("b.txt")), url: url("a.txt"), isDirectory: false, recursive: false)
        ]) {}

        #expect(!filter.shouldDrop(raw(.moved(to: url("elsewhere.txt")), "a.txt")))
        #expect(filter.shouldDrop(raw(.moved(to: url("b.txt")), "a.txt")))
    }

    // MARK: - Recursive ignores

    /// Deleting a folder produces an event per item inside it, and there is no
    /// way to enumerate them in advance — so the declaration covers the subtree.
    @Test("A recursive ignore drops events for descendants")
    func recursiveIgnoreDropsChildren() {
        let filter = IgnoreFilter()
        filter.ignoring([expected(.deleted, "Photos", isDirectory: true, recursive: true)]) {}

        #expect(filter.shouldDrop(raw(.deleted, "Photos", isDirectory: true)))
        #expect(filter.shouldDrop(raw(.deleted, "Photos/cat.jpg")))
        #expect(filter.shouldDrop(raw(.deleted, "Photos/2024/dog.jpg")))
    }

    /// A shower of child events cannot be counted in advance, so a recursive
    /// registration keeps matching until it expires.
    @Test("A recursive ignore is not consumed by the first match")
    func recursiveIgnoreIsNotConsumed() {
        let filter = IgnoreFilter()
        filter.ignoring([expected(.deleted, "Photos", isDirectory: true, recursive: true)]) {}

        #expect(filter.shouldDrop(raw(.deleted, "Photos/one.jpg")))
        #expect(filter.shouldDrop(raw(.deleted, "Photos/two.jpg")))
    }

    @Test("A recursive ignore does not cover a sibling whose name merely shares a prefix")
    func recursiveIgnoreRespectsComponentBoundaries() {
        let filter = IgnoreFilter()
        filter.ignoring([expected(.deleted, "Photos", isDirectory: true, recursive: true)]) {}

        #expect(!filter.shouldDrop(raw(.deleted, "PhotosArchive/cat.jpg")))
    }

    @Test("A recursive ignore does not cover a different kind of event on a child")
    func recursiveIgnoreRespectsKind() {
        let filter = IgnoreFilter()
        filter.ignoring([expected(.deleted, "Photos", isDirectory: true, recursive: true)]) {}

        #expect(!filter.shouldDrop(raw(.created, "Photos/new.jpg")))
    }

    /// Moving a folder relocates its whole subtree; a child event only belongs
    /// to that move if *both* of its paths sit inside it.
    @Test("A recursive move ignore requires both child paths to be inside the move")
    func recursiveMoveNeedsBothSides() {
        let filter = IgnoreFilter()
        filter.ignoring([
            ExpectedFSEvent(kind: .moved(to: url("B")), url: url("A"), isDirectory: true, recursive: true)
        ]) {}

        #expect(filter.shouldDrop(raw(.moved(to: url("B/cat.jpg")), "A/cat.jpg")))
        // The user moved a file out of the folder mid-operation: not our doing.
        #expect(!filter.shouldDrop(raw(.moved(to: url("Elsewhere/cat.jpg")), "A/cat.jpg")))
    }

    // MARK: - Expiry

    /// FSEvents can deliver late, so a registration outlives its operation — but
    /// not forever, or a later user edit would be swallowed.
    @Test("A registration survives briefly after its operation ends")
    func registrationOutlivesTheOperation() {
        let clock = TestClock()
        let filter = IgnoreFilter(now: clock.reader)
        filter.ignoring([expected(.created, "a.txt")]) {}

        clock.advance(1)

        #expect(filter.shouldDrop(raw(.created, "a.txt")))
    }

    @Test("A registration stops matching once it has expired")
    func registrationExpires() {
        let clock = TestClock()
        let filter = IgnoreFilter(now: clock.reader)
        filter.ignoring([expected(.created, "a.txt")]) {}

        clock.advance(IgnoreFilter.registrationLifetime + 1)

        #expect(!filter.shouldDrop(raw(.created, "a.txt")))
    }

    @Test("A long operation does not start its own expiry clock until it ends")
    func expiryStartsWhenTheOperationEnds() {
        let clock = TestClock()
        let filter = IgnoreFilter(now: clock.reader)

        filter.ignoring([expected(.created, "big.bin")]) {
            // A large atomic move can take longer than the registration lifetime.
            clock.advance(IgnoreFilter.registrationLifetime * 10)
        }

        #expect(filter.shouldDrop(raw(.created, "big.bin")))
    }

    @Test("Expiring stale registrations frees them")
    func expireStaleClearsRegistrations() {
        let clock = TestClock()
        let filter = IgnoreFilter(now: clock.reader)
        filter.ignoring([expected(.created, "a.txt")]) {}

        clock.advance(IgnoreFilter.registrationLifetime + 1)
        filter.expireStale()

        #expect(filter.registrationCount == 0)
    }

    @Test("A consumed registration is discarded immediately")
    func consumedRegistrationIsDiscarded() {
        let filter = IgnoreFilter()
        filter.ignoring([expected(.created, "a.txt")]) {}

        #expect(filter.shouldDrop(raw(.created, "a.txt")))
        #expect(filter.registrationCount == 0)
    }

    // MARK: - Pass-through

    @Test("The value the operation returns is passed through")
    func returnValueIsPassedThrough() {
        #expect(IgnoreFilter().ignoring([]) { 42 } == 42)
    }

    @Test("An operation that throws still registers its expiry")
    func throwingOperationStillExpires() {
        struct Boom: Error {}
        let filter = IgnoreFilter()

        #expect(throws: Boom.self) {
            try filter.ignoring([expected(.created, "a.txt")]) { throw Boom() }
        }
        // The mutation may well have happened before the throw, so its echo is
        // still ours to swallow.
        #expect(filter.shouldDrop(raw(.created, "a.txt")))
    }
}

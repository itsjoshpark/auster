import Foundation
import Testing

@testable import AusterCore

/// Turning a raw FSEvents batch into one intent per path (engine-doc §5.3).
/// Editors save atomically, so one save arrives as a temp created, the original
/// unlinked and the temp renamed in — out of order.
@Suite("LocalEventCleaner")
struct LocalEventCleanerTests {

    private let root = URL(fileURLWithPath: "/Dropbox")

    private func url(_ path: String) -> URL {
        root.appendingPathComponent(path, isDirectory: false)
    }

    private func event(_ kind: RawFSEvent.Kind, _ path: String, isDirectory: Bool = false) -> RawFSEvent {
        RawFSEvent(kind: kind, url: url(path), isDirectory: isDirectory)
    }

    private func moved(_ from: String, to destination: String, isDirectory: Bool = false) -> RawFSEvent {
        RawFSEvent(kind: .moved(to: url(destination)), url: url(from), isDirectory: isDirectory)
    }

    /// Cleans, and captures any rescan the cleaner asked for.
    private func clean(
        _ events: [RawFSEvent],
        excluded: Set<String> = []
    ) -> (events: [RawFSEvent], rescans: [URL]) {
        let collected = Rescans()
        let cleaned = LocalEventCleaner.clean(
            events,
            isExcluded: { excluded.contains($0.lastPathComponent) },
            requestRescan: { collected.append($0) }
        )
        return (cleaned, collected.urls)
    }

    private final class Rescans: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [URL] = []
        var urls: [URL] { lock.withLock { storage } }
        func append(_ url: URL) { lock.withLock { storage.append(url) } }
    }

    // MARK: - Pass-through

    @Test("An empty batch cleans to nothing")
    func emptyBatch() {
        #expect(clean([]).events.isEmpty)
    }

    @Test("Unrelated single events survive untouched")
    func singleEventsSurvive() {
        let events = [event(.created, "a.txt"), event(.modified, "b.txt"), event(.deleted, "c.txt")]

        #expect(clean(events).events == events)
    }

    // MARK: - Per-path collapse (§5.3 rule 2)

    @Test("More creations than deletions collapse to one creation")
    func createsWinCollapseToCreated() {
        let events = [event(.created, "a.txt"), event(.deleted, "a.txt"), event(.created, "a.txt")]

        #expect(clean(events).events == [event(.created, "a.txt")])
    }

    @Test("More deletions than creations collapse to one deletion")
    func deletesWinCollapseToDeleted() {
        let events = [event(.created, "a.txt"), event(.deleted, "a.txt"), event(.deleted, "a.txt")]

        #expect(clean(events).events == [event(.deleted, "a.txt")])
    }

    /// The atomic-save shape: the original is unlinked and the replacement moved
    /// into place. The user calls that "editing a file", and so must we.
    @Test("A deletion followed by a creation is a modification")
    func deleteThenCreateIsModified() {
        let events = [event(.deleted, "a.txt"), event(.created, "a.txt")]

        #expect(clean(events).events == [event(.modified, "a.txt")])
    }

    @Test("Repeated modifications collapse to one")
    func modificationsCollapse() {
        let events = [event(.modified, "a.txt"), event(.modified, "a.txt"), event(.modified, "a.txt")]

        #expect(clean(events).events == [event(.modified, "a.txt")])
    }

    /// A file that appeared and vanished within one batch was scratch — but
    /// macOS can deliver an atomic save's events out of order, so the path is
    /// re-examined from disk rather than simply believed.
    @Test("A path created and deleted in the same batch is dropped and rescanned")
    func temporaryFileIsDroppedAndRescanned() {
        let result = clean([event(.created, "a.txt"), event(.deleted, "a.txt")])

        #expect(result.events.isEmpty)
        #expect(result.rescans == [url("a.txt")])
    }

    /// "Modified" cannot express a file becoming a folder, so the collapse has
    /// to keep both halves.
    @Test("A path that changed type collapses to a deletion and a creation")
    func typeChangeKeepsBothHalves() {
        let events = [event(.deleted, "Thing", isDirectory: false), event(.created, "Thing", isDirectory: true)]

        let cleaned = clean(events).events
        #expect(cleaned.count == 2)
        #expect(cleaned.first == event(.deleted, "Thing", isDirectory: false))
        #expect(cleaned.last == event(.created, "Thing", isDirectory: true))
    }

    @Test("A deletion reports the type the item had, not the type that replaced it")
    func deletionKeepsOriginalType() {
        let events = [event(.deleted, "Thing", isDirectory: true), event(.deleted, "Thing", isDirectory: true)]

        #expect(clean(events).events == [event(.deleted, "Thing", isDirectory: true)])
    }

    // MARK: - Moves (§5.3 rules 1 and 3)

    @Test("A clean move survives as a single move")
    func moveSurvives() {
        #expect(clean([moved("before.txt", to: "after.txt")]).events == [moved("before.txt", to: "after.txt")])
    }

    /// Once either end of a move has other traffic on it, the two halves are no
    /// longer one atomic rename, and pretending otherwise would upload the wrong
    /// thing.
    @Test("A move whose destination was also written stays split")
    func moveWithSideEventsStaysSplit() {
        let events = [moved("before.txt", to: "after.txt"), event(.modified, "after.txt")]

        let cleaned = clean(events).events
        #expect(!cleaned.contains { if case .moved = $0.kind { return true } else { return false } })
        #expect(cleaned.contains { $0.url == url("before.txt") && $0.kind == .deleted })
        #expect(cleaned.contains { $0.url == url("after.txt") })
    }

    /// A rename into deselected space is a deletion as far as Dropbox is
    /// concerned; recombining it into a move would ask the server to relocate
    /// something into a folder we do not sync.
    @Test("A move onto an excluded path stays split")
    func moveToExcludedPathStaysSplit() {
        let events = [moved("before.txt", to: "secret.txt")]

        let cleaned = clean(events, excluded: ["secret.txt"]).events
        #expect(cleaned.contains { $0.url == url("before.txt") && $0.kind == .deleted })
        #expect(cleaned.contains { $0.url == url("secret.txt") && $0.kind == .created })
    }

    @Test("A move out of excluded space stays split")
    func moveFromExcludedPathStaysSplit() {
        let events = [moved("secret.txt", to: "public.txt")]

        let cleaned = clean(events, excluded: ["secret.txt"]).events
        #expect(cleaned.contains { $0.url == url("secret.txt") && $0.kind == .deleted })
        #expect(cleaned.contains { $0.url == url("public.txt") && $0.kind == .created })
    }

    // MARK: - Pruning children (§5.3 rule 4)

    /// Moving a folder is one remote call; its children come along implicitly.
    /// Leaving their events in would turn one API call into thousands.
    @Test("A directory move prunes the child moves that merely mirror it")
    func directoryMovePrunesChildren() {
        let events = [
            moved("A", to: "B", isDirectory: true),
            moved("A/cat.jpg", to: "B/cat.jpg"),
            moved("A/2024/dog.jpg", to: "B/2024/dog.jpg"),
        ]

        #expect(clean(events).events == [moved("A", to: "B", isDirectory: true)])
    }

    @Test("A directory move keeps a child that went somewhere else")
    func directoryMoveKeepsDivergentChild() {
        let events = [
            moved("A", to: "B", isDirectory: true),
            moved("A/cat.jpg", to: "Elsewhere/cat.jpg"),
        ]

        let cleaned = clean(events).events
        #expect(cleaned.count == 2)
    }

    @Test("A directory deletion prunes the deletions of its contents")
    func directoryDeletePrunesChildren() {
        let events = [
            event(.deleted, "A", isDirectory: true),
            event(.deleted, "A/cat.jpg"),
            event(.deleted, "A/2024/dog.jpg"),
        ]

        #expect(clean(events).events == [event(.deleted, "A", isDirectory: true)])
    }

    @Test("A directory deletion does not prune a sibling that merely shares a prefix")
    func pruningRespectsComponentBoundaries() {
        let events = [event(.deleted, "A", isDirectory: true), event(.deleted, "AB/cat.jpg")]

        #expect(clean(events).events.count == 2)
    }

    @Test("A file deletion prunes nothing")
    func fileDeletionPrunesNothing() {
        let events = [event(.deleted, "A"), event(.deleted, "A/cat.jpg")]

        #expect(clean(events).events.count == 2)
    }

    // MARK: - Scale

    /// A batch this size is what arrives after a big folder is dropped in, and
    /// the cleaner runs before anything else can start. Nested scans over the
    /// batch would make it quadratic; the rules are all dictionary lookups.
    @Test("A twenty-thousand event batch cleans in well under a second")
    func scalesToLargeBatches() {
        var events: [RawFSEvent] = []
        events.reserveCapacity(20_000)
        for index in 0..<10_000 {
            events.append(event(.created, "folder\(index % 100)/file\(index).txt"))
            events.append(event(.modified, "folder\(index % 100)/file\(index).txt"))
        }

        let start = ContinuousClock.now
        let cleaned = clean(events).events
        let elapsed = ContinuousClock.now - start

        #expect(cleaned.count == 10_000)
        #expect(elapsed < .seconds(1))
    }
}

import AusterCore
import Foundation
import Testing

@testable import Auster

/// How a completed sync event is presented in the Recent Changes window (ux §7).
/// Tested apart from the view: a removal must not offer to reveal something that
/// is no longer there.
@Suite("Recent change presentation")
struct RecentChangePresentationTests {

    private func entry(
        _ change: ChangeType,
        direction: SyncDirection = .down,
        path: String = "/Notes/todo.md"
    ) -> HistoryEntry {
        HistoryEntry(
            direction: direction,
            changeType: change,
            itemType: .file,
            dbxPath: path,
            size: 12,
            timestamp: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    @Test("an addition points the way it travelled")
    func additionsShowDirection() {
        #expect(RecentChangePresentation.symbolName(for: entry(.added, direction: .down)) == "arrow.down.circle")
        #expect(RecentChangePresentation.symbolName(for: entry(.added, direction: .up)) == "arrow.up.circle")
    }

    @Test("the other change types describe what happened, not which way")
    func otherChangesDescribeTheChange() {
        #expect(RecentChangePresentation.symbolName(for: entry(.modified)) == "pencil.circle")
        #expect(RecentChangePresentation.symbolName(for: entry(.moved)) == "arrow.right.circle")
        #expect(RecentChangePresentation.symbolName(for: entry(.removed)) == "trash.circle")
    }

    /// A removed item has nothing left on disk, so the row must not offer to
    /// show it — Dropbox's deleted-files page is the only thing left to point at.
    @Test("only a change that left a file behind can be revealed")
    func removalsAreNotRevealable() {
        #expect(RecentChangePresentation.isRevealable(entry(.added)))
        #expect(RecentChangePresentation.isRevealable(entry(.modified)))
        #expect(RecentChangePresentation.isRevealable(entry(.moved)))
        #expect(!RecentChangePresentation.isRevealable(entry(.removed)))
    }

    /// The window shows the same thirty Maestral did (ux §7).
    @Test("the window shows at most thirty entries, newest first")
    func windowIsCappedAtThirty() {
        let many = (1...50).map { entry(.added, path: "/f\($0).txt") }
        #expect(RecentChangePresentation.displayed(many).count == 30)
        #expect(RecentChangePresentation.displayed(many).first?.dbxPath == "/f1.txt")
        #expect(RecentChangePresentation.displayed([]).isEmpty)
    }
}

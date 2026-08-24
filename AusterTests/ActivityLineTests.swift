import AusterCore
import Testing

@testable import Auster

/// An `NSMenu` item is a line of text, so the in-flight transfers that used to
/// carry a progress bar now have to say the same thing in words (ux §2 item 7).
@Suite("Activity line")
struct ActivityLineTests {

    private func item(path: String, direction: SyncDirection, completed: Int64, total: Int64)
        -> ActivityItem
    {
        ActivityItem(
            id: path,
            dbxPath: path,
            direction: direction,
            completed: completed,
            total: total
        )
    }

    @Test("a download in progress reads as an arrow, a name and a percentage")
    func downloadInProgress() {
        let line = ActivityLine.text(
            for: item(path: "/Projects/Alpha/report.pdf", direction: .down, completed: 42, total: 100)
        )
        #expect(line == "↓ report.pdf — 42%")
    }

    @Test("an upload points the other way")
    func uploadDirection() {
        let line = ActivityLine.text(
            for: item(path: "/notes.txt", direction: .up, completed: 1, total: 4)
        )
        #expect(line == "↑ notes.txt — 25%")
    }

    /// `total` is zero for an item whose size is not known yet. A "0%" there
    /// would read as stalled rather than as starting.
    @Test("an item of unknown size shows no percentage")
    func unknownSize() {
        let line = ActivityLine.text(
            for: item(path: "/Media/big.bin", direction: .down, completed: 0, total: 0)
        )
        #expect(line == "↓ big.bin")
    }

    @Test("the last path component is what the row names")
    func namesTheLastComponent() {
        let line = ActivityLine.text(
            for: item(path: "/a/b/c/deep file.txt", direction: .down, completed: 1, total: 2)
        )
        #expect(line == "↓ deep file.txt — 50%")
    }
}

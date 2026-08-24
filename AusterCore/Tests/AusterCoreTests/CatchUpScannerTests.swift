import Foundation
import Testing

@testable import AusterCore

/// Finding out what happened while Auster was not running (engine-doc §6). The
/// dangerous half is deletions: a missing folder would produce one for every
/// file the user owns, so the root guard runs first (§9).
@Suite("CatchUpScanner")
struct CatchUpScannerTests {

    /// Old enough that anything written during a test looks newer.
    private let cursor = Date(timeIntervalSince1970: 1_000)

    private func scan(_ fixture: EngineFixture, localCursor: Date? = nil) throws -> [RawFSEvent] {
        try CatchUpScanner.scan(
            root: fixture.dropbox,
            database: fixture.database,
            pathStore: fixture.pathStore,
            localCursor: localCursor ?? cursor
        )
    }

    private func setModified(_ url: URL, to date: Date) throws {
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
    }

    // MARK: - Creations

    @Test("A file the index has never seen is a creation")
    func untrackedFileIsCreated() throws {
        let fixture = try EngineFixture()
        try fixture.writeLocal("/new.txt", "new")

        let events = try scan(fixture)

        #expect(events.contains { $0.url == fixture.local("/new.txt") && $0.kind == .created })
    }

    @Test("An untracked folder is a creation, and so is what is inside it")
    func untrackedFolderIsCreated() throws {
        let fixture = try EngineFixture()
        try fixture.writeLocal("/Photos/cat.jpg", "meow")

        let events = try scan(fixture)

        #expect(events.contains { $0.url == fixture.local("/Photos") && $0.isDirectory })
        #expect(events.contains { $0.url == fixture.local("/Photos/cat.jpg") })
    }

    @Test("Names Auster never syncs are not reported")
    func excludedNamesAreSkipped() throws {
        let fixture = try EngineFixture()
        try fixture.writeLocal("/.DS_Store", "junk")
        try fixture.writeLocal("/real.txt", "real")

        let events = try scan(fixture)

        #expect(events.count == 1)
        #expect(events.first?.url == fixture.local("/real.txt"))
    }

    /// The staging directory lives inside the Dropbox folder, so a scan that did
    /// not skip it would try to upload half-finished downloads.
    @Test("The engine's own cache directory is not reported")
    func cacheDirectoryIsSkipped() throws {
        let fixture = try EngineFixture()
        let staged = try fixture.fileOps.newTempFile()
        try Data("partial".utf8).write(to: staged)

        #expect(try scan(fixture).isEmpty)
    }

    // MARK: - Modifications

    @Test("A tracked file written since the last sync is a modification")
    func newerMtimeIsModified() throws {
        let fixture = try EngineFixture()
        let url = try fixture.writeLocal("/report.txt", "edited")
        try fixture.seedIndex("/report.txt", lastSync: Date(timeIntervalSince1970: 2_000))
        try setModified(url, to: Date(timeIntervalSince1970: 5_000))

        let events = try scan(fixture)

        #expect(events == [RawFSEvent(kind: .modified, url: url, isDirectory: false)])
    }

    @Test("A tracked file untouched since the last sync reports nothing")
    func unchangedFileIsQuiet() throws {
        let fixture = try EngineFixture()
        let url = try fixture.writeLocal("/report.txt", "same")
        try fixture.seedIndex("/report.txt", lastSync: Date(timeIntervalSince1970: 5_000))
        try setModified(url, to: Date(timeIntervalSince1970: 2_000))

        #expect(try scan(fixture).isEmpty)
    }

    /// The local cursor covers the window the index cannot: a file synced long
    /// ago, then edited, then edited again after the last completed cycle.
    @Test("The local cursor is used when it is later than the item's own last sync")
    func localCursorRaisesTheBar() throws {
        let fixture = try EngineFixture()
        let url = try fixture.writeLocal("/report.txt", "same")
        try fixture.seedIndex("/report.txt", lastSync: Date(timeIntervalSince1970: 2_000))
        try setModified(url, to: Date(timeIntervalSince1970: 3_000))

        let events = try scan(fixture, localCursor: Date(timeIntervalSince1970: 4_000))

        #expect(events.isEmpty)
    }

    @Test("A tracked folder on disk reports nothing of its own")
    func unchangedFolderIsQuiet() throws {
        let fixture = try EngineFixture()
        try fixture.makeLocalFolder("/Photos")
        try fixture.seedIndex("/Photos", type: .folder, lastSync: Date(timeIntervalSince1970: 5_000))

        #expect(try scan(fixture).isEmpty)
    }

    // MARK: - Deletions

    @Test("A tracked item the disk no longer has is a deletion")
    func missingFileIsDeleted() throws {
        let fixture = try EngineFixture()
        try fixture.seedIndex("/gone.txt")

        let events = try scan(fixture)

        #expect(events == [RawFSEvent(kind: .deleted, url: fixture.local("/gone.txt"), isDirectory: false)])
    }

    @Test("A tracked folder the disk no longer has is a directory deletion")
    func missingFolderIsDeleted() throws {
        let fixture = try EngineFixture()
        try fixture.seedIndex("/Photos", type: .folder)

        #expect(try scan(fixture).first?.isDirectory == true)
    }

    /// A rename cannot be seen offline, so a recasing shows up as the old name
    /// disappearing and the new one arriving — which converges to the same
    /// place.
    @Test("A file whose casing drifted counts as gone, and its new spelling as new")
    func casingDriftIsADeletionAndACreation() throws {
        let fixture = try EngineFixture()
        try fixture.writeLocal("/report.txt", "same")
        try fixture.seedIndex("/Report.txt")

        let events = try scan(fixture)

        #expect(events.contains { $0.url == fixture.local("/Report.txt") && $0.kind == .deleted })
        #expect(events.contains { $0.url == fixture.local("/report.txt") && $0.kind == .created })
    }

    /// "Modified" cannot express a file having become a folder.
    @Test("An item that changed type is reported as a deletion and a creation")
    func typeChangeIsAPair() throws {
        let fixture = try EngineFixture()
        try fixture.makeLocalFolder("/Thing")
        try fixture.seedIndex("/Thing", type: .file)

        let events = try scan(fixture)

        #expect(events.contains { $0.url == fixture.local("/Thing") && $0.kind == .deleted && !$0.isDirectory })
        #expect(events.contains { $0.url == fixture.local("/Thing") && $0.kind == .created && $0.isDirectory })
    }

    // MARK: - The root guard (§9)

    /// The whole reason the guard exists: without it, a folder the user renamed
    /// would be read as "the user deleted everything" and the scan would
    /// dutifully propose deleting their entire Dropbox.
    @Test("A missing Dropbox folder throws instead of proposing a deletion storm")
    func missingRootThrows() throws {
        let fixture = try EngineFixture()
        try fixture.seedIndex("/a.txt")
        try fixture.seedIndex("/b.txt")
        try FileManager.default.removeItem(at: fixture.dropbox)

        #expect(throws: SyncFatalError.dropboxFolderMissing) {
            try scan(fixture)
        }
    }

    @Test("A Dropbox folder whose own casing drifted is treated as missing")
    func recasedRootThrows() throws {
        let fixture = try EngineFixture()
        try FileManager.default.moveItem(
            at: fixture.dropbox,
            to: fixture.root.appendingPathComponent("dropbox")
        )

        #expect(throws: SyncFatalError.dropboxFolderMissing) {
            try scan(fixture)
        }
    }
}

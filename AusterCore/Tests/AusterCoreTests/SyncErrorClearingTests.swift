import Foundation
import Testing

@testable import AusterCore

/// When a recorded sync issue is allowed to disappear. An error row feeds the
/// menu count, the Sync Issues window and the startup retry list, so clearing
/// one for a path that is still wrong loses the retry with it (note N40).
@Suite("Sync error clearing")
struct SyncErrorClearingTests {

    private func downloadError(_ path: String) -> SyncErrorEntry {
        SyncErrorEntry(
            dbxPathLower: PathStore.normalize(path),
            dbxPath: path,
            direction: .down,
            title: "Could not download file",
            message: "Permission denied"
        )
    }

    @Test("a skipped folder upload leaves its children's errors alone")
    func skippedFolderKeepsChildErrors() async throws {
        let fixture = try EngineFixture()

        // The folder is already on the remote and in the index, so uploading it
        // again has nothing to do.
        fixture.service.seedFolder(at: "/Notes")
        try fixture.seedIndex("/Notes", type: .folder)
        try fixture.makeLocalFolder("/Notes")

        // A child that failed to download and is still not on disk.
        try fixture.database.upsertSyncError(downloadError("/Notes/blocked.txt"))

        try await fixture.makeEngine().uploadCycle(
            rawEvents: [RawFSEvent(kind: .created, url: fixture.local("/Notes"), isDirectory: true)]
        )

        let remaining = try fixture.database.syncErrors().map(\.dbxPathLower)
        #expect(remaining == ["/notes/blocked.txt"])
    }

    @Test("a folder's own error is cleared when the folder itself syncs")
    func folderClearsItsOwnError() async throws {
        let fixture = try EngineFixture()
        fixture.service.seedFolder(at: "/Notes")
        try fixture.seedIndex("/Notes", type: .folder)
        try fixture.makeLocalFolder("/Notes")

        try fixture.database.upsertSyncError(downloadError("/Notes"))

        try await fixture.makeEngine().uploadCycle(
            rawEvents: [RawFSEvent(kind: .created, url: fixture.local("/Notes"), isDirectory: true)]
        )

        #expect(try fixture.database.syncErrors().isEmpty)
    }

    @Test("a file that does sync clears its own error")
    func fileClearsItsOwnError() async throws {
        let fixture = try EngineFixture()
        try fixture.writeLocal("/report.txt", "hello")
        try fixture.database.upsertSyncError(downloadError("/report.txt"))

        try await fixture.makeEngine().uploadCycle(
            rawEvents: [RawFSEvent(kind: .created, url: fixture.local("/report.txt"), isDirectory: false)]
        )

        #expect(try fixture.database.syncErrors().isEmpty)
    }
}

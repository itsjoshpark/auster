import Foundation
import Testing

@testable import AusterCore

/// The §4.4 decision table, one test per row plus the cases where its *order*
/// is what matters.
///
/// This is the single point where the engine decides whether a remote change may
/// touch local bytes, so every row is pinned separately: a rule that fires one
/// position too early silently discards the user's edits, which is precisely
/// what decisions D9.1 forbids.
@Suite("ConflictResolver")
struct ConflictResolverTests {

    // MARK: - Fixtures

    /// A `last_sync` far enough in the future that nothing on disk can look
    /// newer — i.e. "this item has no unsynced local changes".
    private let synced = Date().addingTimeInterval(3_600)

    /// A `last_sync` in the past, so anything written now looks unsynced.
    private let stale = Date(timeIntervalSince1970: 1_000)

    private func downloadEvent(
        _ fixture: EngineFixture,
        _ dbxPath: String,
        changeType: ChangeType = .modified,
        itemType: ItemType? = .file,
        rev: String? = "remote-rev",
        contentHash: String? = "remote-hash",
        symlinkTarget: String? = nil
    ) -> SyncItemEvent {
        SyncItemEvent(
            direction: .down,
            changeType: changeType,
            itemType: itemType,
            dbxPath: dbxPath,
            dbxPathLower: PathStore.normalize(dbxPath),
            localURL: fixture.local(dbxPath),
            rev: rev,
            contentHash: contentHash,
            symlinkTarget: symlinkTarget
        )
    }

    private func deletionEvent(
        _ fixture: EngineFixture,
        _ dbxPath: String,
        itemType: ItemType
    ) -> SyncItemEvent {
        downloadEvent(
            fixture,
            dbxPath,
            changeType: .removed,
            itemType: itemType,
            rev: nil,
            contentHash: nil
        )
    }

    private func check(_ fixture: EngineFixture, _ event: SyncItemEvent) throws -> DownloadConflict {
        try ConflictResolver.check(
            event: event,
            index: fixture.indexEntry(event.dbxPathLower),
            hasher: fixture.hasher,
            database: fixture.database
        )
    }

    // MARK: - Row 1: rev equality

    @Test("A revision we already have is skipped without touching the index")
    func sameRevIsLocalNewerOrIdentical() throws {
        let fixture = try EngineFixture()
        try fixture.seedIndex("/a.txt", rev: "remote-rev", lastSync: stale)
        try fixture.writeLocal("/a.txt", "whatever the user did since")

        #expect(try check(fixture, downloadEvent(fixture, "/a.txt")) == .localNewerOrIdentical)
    }

    /// Folders have no revisions, so the index and every event both carry the
    /// literal `"folder"` — which makes row 1 the rule that short-circuits every
    /// already-known folder.
    @Test("A known folder matches on the folder sentinel")
    func folderSentinelRevEquality() throws {
        let fixture = try EngineFixture()
        try fixture.seedIndex("/Photos", type: .folder, lastSync: stale)
        try fixture.makeLocalFolder("/Photos")

        let event = downloadEvent(
            fixture,
            "/Photos",
            itemType: .folder,
            rev: ItemType.folderSentinel,
            contentHash: ItemType.folderSentinel
        )

        #expect(try check(fixture, event) == .localNewerOrIdentical)
    }

    // MARK: - Row 2: content equality

    @Test("Content already on disk is identical: skip the transfer, record the rev")
    func matchingContentIsIdentical() throws {
        let fixture = try EngineFixture()
        try fixture.seedIndex("/a.txt", rev: "old-rev", lastSync: stale)
        try fixture.writeLocal("/a.txt", "same bytes")

        let event = downloadEvent(
            fixture,
            "/a.txt",
            contentHash: ContentHasher.hash(data: Data("same bytes".utf8))
        )

        #expect(try check(fixture, event) == .identical)
    }

    @Test("A file the index has never seen but whose content matches is identical")
    func matchingContentWithoutIndexEntry() throws {
        let fixture = try EngineFixture()
        try fixture.writeLocal("/a.txt", "same bytes")

        let event = downloadEvent(
            fixture,
            "/a.txt",
            changeType: .added,
            contentHash: ContentHasher.hash(data: Data("same bytes".utf8))
        )

        #expect(try check(fixture, event) == .identical)
    }

    /// A symlink and a regular file can hold the same bytes and still be
    /// different things, so the target has to agree too.
    @Test("Equal content with a different symlink target is not identical")
    func symlinkTargetIsPartOfContentEquality() throws {
        let fixture = try EngineFixture()
        try fixture.seedIndex("/link", rev: "old-rev", lastSync: synced)
        try fixture.writeLocal("/link", "payload")

        let event = downloadEvent(
            fixture,
            "/link",
            contentHash: ContentHasher.hash(data: Data("payload".utf8)),
            symlinkTarget: "/somewhere/else"
        )

        #expect(try check(fixture, event) != .identical)
    }

    @Test("A symlink pointing where the remote says, with matching content, is identical")
    func matchingSymlinkIsIdentical() throws {
        let fixture = try EngineFixture()
        let target = try fixture.writeLocal("/target.txt", "payload")
        try fixture.seedIndex("/link", rev: "old-rev", lastSync: synced)
        try FileManager.default.createSymbolicLink(
            atPath: fixture.local("/link").path,
            withDestinationPath: target.path
        )

        let event = downloadEvent(
            fixture,
            "/link",
            contentHash: ContentHasher.hash(data: Data("payload".utf8)),
            symlinkTarget: target.path
        )

        #expect(try check(fixture, event) == .identical)
    }

    // MARK: - Row 3: an unresolved upload error

    /// Row 3 has to beat row 4: the local file may look perfectly synced while
    /// the change that failed to upload is still only on disk.
    @Test("An unresolved upload error makes the path a conflict even when it looks synced")
    func pendingUploadErrorIsConflict() throws {
        let fixture = try EngineFixture()
        try fixture.seedIndex("/a.txt", rev: "old-rev", lastSync: synced)
        try fixture.writeLocal("/a.txt", "local")
        try fixture.database.upsertSyncError(
            SyncErrorEntry(
                dbxPathLower: "/a.txt",
                dbxPath: "/a.txt",
                direction: .up,
                title: "Could not upload file",
                message: "Dropbox is full."
            )
        )

        #expect(try check(fixture, downloadEvent(fixture, "/a.txt")) == .conflict)
    }

    /// A *download* error on the path says nothing about the local file, so it
    /// must not manufacture a conflicted copy.
    @Test("A previous download error is not an upload conflict")
    func pendingDownloadErrorIsNotConflict() throws {
        let fixture = try EngineFixture()
        try fixture.seedIndex("/a.txt", rev: "old-rev", lastSync: synced)
        try fixture.writeLocal("/a.txt", "local")
        try fixture.database.upsertSyncError(
            SyncErrorEntry(
                dbxPathLower: "/a.txt",
                dbxPath: "/a.txt",
                direction: .down,
                title: "Could not download file",
                message: "Auster cannot reach Dropbox."
            )
        )

        #expect(try check(fixture, downloadEvent(fixture, "/a.txt")) == .remoteNewer)
    }

    // MARK: - Row 4: no unsynced local changes

    @Test("A local file with no unsynced changes yields to the remote")
    func syncedLocalFileIsRemoteNewer() throws {
        let fixture = try EngineFixture()
        try fixture.seedIndex("/a.txt", rev: "old-rev", lastSync: synced)
        try fixture.writeLocal("/a.txt", "local")

        #expect(try check(fixture, downloadEvent(fixture, "/a.txt")) == .remoteNewer)
    }

    @Test("A path with nothing on disk and nothing in the index yields to the remote")
    func brandNewFileIsRemoteNewer() throws {
        let fixture = try EngineFixture()

        #expect(
            try check(fixture, downloadEvent(fixture, "/new.txt", changeType: .added)) == .remoteNewer
        )
    }

    // MARK: - Row 5: local edits beat a remote deletion

    @Test("A remote deletion is skipped when the local file has unsynced changes")
    func deletionLosesToLocalEdits() throws {
        let fixture = try EngineFixture()
        try fixture.seedIndex("/a.txt", rev: "old-rev", lastSync: stale)
        try fixture.writeLocal("/a.txt", "edited since the last sync")

        let event = deletionEvent(fixture, "/a.txt", itemType: .file)

        #expect(try check(fixture, event) == .localNewerOrIdentical)
    }

    @Test("A remote deletion of an untouched file applies")
    func deletionOfUntouchedFileApplies() throws {
        let fixture = try EngineFixture()
        try fixture.seedIndex("/a.txt", rev: "old-rev", lastSync: synced)
        try fixture.writeLocal("/a.txt", "untouched")

        let event = deletionEvent(fixture, "/a.txt", itemType: .file)

        #expect(try check(fixture, event) == .remoteNewer)
    }

    // MARK: - Row 6: everything else is a conflict

    @Test("A remote edit of a locally edited file is a conflict")
    func concurrentEditsAreConflict() throws {
        let fixture = try EngineFixture()
        try fixture.seedIndex("/a.txt", rev: "old-rev", lastSync: stale)
        try fixture.writeLocal("/a.txt", "the user's version")

        #expect(try check(fixture, downloadEvent(fixture, "/a.txt")) == .conflict)
    }

    /// A file the index knows but the disk does not was deleted locally, and
    /// that deletion is itself an unsynced change.
    @Test("A file missing locally but present in the index counts as changed")
    func missingLocallyCountsAsChanged() throws {
        let fixture = try EngineFixture()
        try fixture.seedIndex("/a.txt", rev: "old-rev", lastSync: synced)

        #expect(try check(fixture, downloadEvent(fixture, "/a.txt")) == .conflict)
        #expect(try check(fixture, deletionEvent(fixture, "/a.txt", itemType: .file)) == .localNewerOrIdentical)
    }

    // MARK: - §4.5: the recursive ctime walk

    @Test("A remote folder deletion is vetoed by an unsynced file inside it")
    func folderDeletionLosesToUnsyncedChild() throws {
        let fixture = try EngineFixture()
        try fixture.seedIndex("/Photos", type: .folder, lastSync: synced)
        try fixture.makeLocalFolder("/Photos")
        try fixture.writeLocal("/Photos/new.jpg", "brand new")

        let event = deletionEvent(fixture, "/Photos", itemType: .folder)

        #expect(try check(fixture, event) == .localNewerOrIdentical)
    }

    @Test("A remote folder deletion applies when everything inside it is synced")
    func folderDeletionAppliesWhenClean() throws {
        let fixture = try EngineFixture()
        try fixture.seedIndex("/Photos", type: .folder, lastSync: synced)
        try fixture.seedIndex("/Photos/cat.jpg", lastSync: synced)
        try fixture.writeLocal("/Photos/cat.jpg", "meow")

        let event = deletionEvent(fixture, "/Photos", itemType: .folder)

        #expect(try check(fixture, event) == .remoteNewer)
    }

    /// Junk the engine never syncs cannot make a folder look dirty — otherwise a
    /// single `.DS_Store` would veto every folder deletion Finder has ever
    /// visited.
    @Test("An excluded name inside a folder is not an unsynced change")
    func excludedNamesDoNotCountAsChanges() throws {
        let fixture = try EngineFixture()
        try fixture.seedIndex("/Photos", type: .folder, lastSync: synced)
        try fixture.makeLocalFolder("/Photos")
        try fixture.writeLocal("/Photos/.DS_Store", "finder junk")

        let event = deletionEvent(fixture, "/Photos", itemType: .folder)

        #expect(try check(fixture, event) == .remoteNewer)
    }

    @Test("A child the index knows but the disk has lost vetoes a folder deletion")
    func missingChildCountsAsChange() throws {
        let fixture = try EngineFixture()
        try fixture.seedIndex("/Photos", type: .folder, lastSync: synced)
        try fixture.seedIndex("/Photos/cat.jpg", lastSync: synced)
        try fixture.makeLocalFolder("/Photos")

        let event = deletionEvent(fixture, "/Photos", itemType: .folder)

        #expect(try check(fixture, event) == .localNewerOrIdentical)
    }

    @Test("A nested unsynced file vetoes the deletion of an ancestor folder")
    func nestedChangesAreFound() throws {
        let fixture = try EngineFixture()
        try fixture.seedIndex("/Photos", type: .folder, lastSync: synced)
        try fixture.seedIndex("/Photos/2024", type: .folder, lastSync: synced)
        try fixture.makeLocalFolder("/Photos/2024")
        try fixture.writeLocal("/Photos/2024/new.jpg", "brand new")

        let event = deletionEvent(fixture, "/Photos", itemType: .folder)

        #expect(try check(fixture, event) == .localNewerOrIdentical)
    }
}

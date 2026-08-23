import Foundation
import Testing

@testable import AusterCore

/// `MockDropboxService` is the remote that every later phase's scenario tests
/// run against, so its semantics are themselves under test here: if the fake
/// drifts from real Dropbox, the engine tests all lie.
@Suite("MockDropboxService")
struct MockDropboxServiceTests {

    // MARK: - Helpers

    /// A scratch directory that goes away with the test.
    private struct Scratch: ~Copyable {
        let url: URL

        init() throws {
            url = URL(fileURLWithPath: NSTemporaryDirectory())
                .appending(path: "auster-mock-\(UUID().uuidString)", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }

        func file(named name: String, contents: String) throws -> URL {
            let target = url.appending(path: name)
            try Data(contents.utf8).write(to: target)
            return target
        }

        deinit {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func noProgress(_: Int64) {}

    // MARK: - Listing

    @Test("an uploaded file appears in a subsequent listing")
    func uploadThenList() async throws {
        let scratch = try Scratch()
        let mock = MockDropboxService()

        let uploaded = try await mock.upload(
            from: scratch.file(named: "notes.txt", contents: "hello"),
            to: "/Notes.txt",
            mode: .add,
            autorename: false,
            clientModified: Date(timeIntervalSince1970: 1_000),
            progress: noProgress
        )

        #expect(uploaded.pathLower == "/notes.txt")
        #expect(uploaded.pathDisplay == "/Notes.txt")
        #expect(uploaded.size == 5)

        let page = try await mock.listFolder(path: "", recursive: true)
        #expect(page.entries.map(\.pathLower) == ["/notes.txt"])
        #expect(!page.hasMore)
    }

    @Test("a non-recursive listing stops at the folder's direct children")
    func nonRecursiveListing() async throws {
        let mock = MockDropboxService()
        mock.seedFolder(at: "/Photos")
        try mock.seedFile(at: "/Photos/cat.jpg", contents: "cat")
        try mock.seedFile(at: "/Photos/Trips/rome.jpg", contents: "rome")

        let shallow = try await mock.listFolder(path: "/Photos", recursive: false)
        #expect(Set(shallow.entries.map(\.pathLower)) == ["/photos/cat.jpg", "/photos/trips"])

        let deep = try await mock.listFolder(path: "/Photos", recursive: true)
        #expect(
            Set(deep.entries.map(\.pathLower))
                == ["/photos/cat.jpg", "/photos/trips", "/photos/trips/rome.jpg"]
        )
    }

    @Test("a listing paginates and the final page carries a usable delta cursor")
    func pagination() async throws {
        let mock = MockDropboxService()
        mock.pageSize = 2
        for index in 0..<5 {
            try mock.seedFile(at: "/file\(index).txt", contents: "\(index)")
        }

        var seen: [String] = []
        var page = try await mock.listFolder(path: "", recursive: true)
        seen += page.entries.map(\.pathLower)
        #expect(page.entries.count == 2)
        #expect(page.hasMore)

        while page.hasMore {
            page = try await mock.listFolderContinue(cursor: page.cursor)
            seen += page.entries.map(\.pathLower)
        }

        #expect(Set(seen).count == 5)

        // The cursor that ended the listing is now a delta cursor.
        try mock.seedFile(at: "/late.txt", contents: "late")
        let delta = try await mock.listFolderContinue(cursor: page.cursor)
        #expect(delta.entries.map(\.pathLower) == ["/late.txt"])
    }

    @Test("continue after changes returns only the delta")
    func deltaListing() async throws {
        let mock = MockDropboxService()
        try mock.seedFile(at: "/a.txt", contents: "a")

        let first = try await mock.listFolder(path: "", recursive: true)
        #expect(first.entries.count == 1)

        // Nothing changed: an empty delta, and the cursor still advances.
        let quiet = try await mock.listFolderContinue(cursor: first.cursor)
        #expect(quiet.entries.isEmpty)
        #expect(!quiet.hasMore)

        try mock.seedFile(at: "/b.txt", contents: "b")
        let delta = try await mock.listFolderContinue(cursor: quiet.cursor)
        #expect(delta.entries.map(\.pathLower) == ["/b.txt"])
    }

    @Test("an unknown cursor is reported as a reset, not a generic failure")
    func unknownCursorResets() async throws {
        let mock = MockDropboxService()
        await #expect(throws: DropboxServiceError.cursorReset) {
            try await mock.listFolderContinue(cursor: "not-a-cursor")
        }
    }

    @Test("invalidating cursors forces a full reindex")
    func forcedCursorReset() async throws {
        let mock = MockDropboxService()
        let page = try await mock.listFolder(path: "", recursive: true)
        mock.invalidateCursors()

        await #expect(throws: DropboxServiceError.cursorReset) {
            try await mock.listFolderContinue(cursor: page.cursor)
        }
    }

    // MARK: - Write modes

    @Test("add against an occupied path autorenames the way the server does")
    func addAutorenames() async throws {
        let scratch = try Scratch()
        let mock = MockDropboxService()
        try mock.seedFile(at: "/report.txt", contents: "original")

        let uploaded = try await mock.upload(
            from: scratch.file(named: "report.txt", contents: "second"),
            to: "/report.txt",
            mode: .add,
            autorename: true,
            clientModified: Date(),
            progress: noProgress
        )

        #expect(uploaded.pathDisplay == "/report (2).txt")
        #expect(try mock.contents(at: "/report.txt") == Data("original".utf8))
    }

    @Test("add against an occupied path without autorename is a conflict")
    func addConflicts() async throws {
        let scratch = try Scratch()
        let mock = MockDropboxService()
        try mock.seedFile(at: "/report.txt", contents: "original")

        await #expect(throws: DropboxServiceError.conflict(path: "/report.txt")) {
            try await mock.upload(
                from: scratch.file(named: "report.txt", contents: "second"),
                to: "/report.txt",
                mode: .add,
                autorename: false,
                clientModified: Date(),
                progress: noProgress
            )
        }
    }

    @Test("update with the current rev overwrites in place")
    func updateWithCurrentRev() async throws {
        let scratch = try Scratch()
        let mock = MockDropboxService()
        let seeded = try mock.seedFile(at: "/report.txt", contents: "original")

        let uploaded = try await mock.upload(
            from: scratch.file(named: "report.txt", contents: "revised"),
            to: "/report.txt",
            mode: .update(rev: seeded.rev),
            autorename: true,
            clientModified: Date(),
            progress: noProgress
        )

        #expect(uploaded.pathLower == "/report.txt")
        #expect(uploaded.rev != seeded.rev)
        #expect(try mock.contents(at: "/report.txt") == Data("revised".utf8))
    }

    @Test("update with a stale rev writes a conflicted copy and leaves the original")
    func updateWithStaleRevMakesConflictedCopy() async throws {
        let scratch = try Scratch()
        let mock = MockDropboxService()
        let seeded = try mock.seedFile(at: "/report.txt", contents: "original")
        try mock.seedFile(at: "/report.txt", contents: "somebody else")  // rev moves on

        let uploaded = try await mock.upload(
            from: scratch.file(named: "report.txt", contents: "mine"),
            to: "/report.txt",
            mode: .update(rev: seeded.rev),
            autorename: true,
            clientModified: Date(),
            progress: noProgress
        )

        #expect(uploaded.pathDisplay == "/report (conflicted copy).txt")
        #expect(try mock.contents(at: "/report.txt") == Data("somebody else".utf8))
        #expect(try mock.contents(at: "/report (conflicted copy).txt") == Data("mine".utf8))
    }

    @Test("update with a stale rev and no autorename is a conflict")
    func updateWithStaleRevConflicts() async throws {
        let scratch = try Scratch()
        let mock = MockDropboxService()
        let seeded = try mock.seedFile(at: "/report.txt", contents: "original")
        try mock.seedFile(at: "/report.txt", contents: "somebody else")

        await #expect(throws: DropboxServiceError.conflict(path: "/report.txt")) {
            try await mock.upload(
                from: scratch.file(named: "report.txt", contents: "mine"),
                to: "/report.txt",
                mode: .update(rev: seeded.rev),
                autorename: false,
                clientModified: Date(),
                progress: noProgress
            )
        }
    }

    @Test("uploading into a missing folder creates the parents, as the server does")
    func uploadCreatesParents() async throws {
        let scratch = try Scratch()
        let mock = MockDropboxService()

        _ = try await mock.upload(
            from: scratch.file(named: "rome.jpg", contents: "rome"),
            to: "/Photos/Trips/rome.jpg",
            mode: .add,
            autorename: false,
            clientModified: Date(),
            progress: noProgress
        )

        let page = try await mock.listFolder(path: "", recursive: true)
        #expect(
            Set(page.entries.map(\.pathLower))
                == ["/photos", "/photos/trips", "/photos/trips/rome.jpg"]
        )
    }

    @Test("progress is reported and ends at the file's size")
    func uploadReportsProgress() async throws {
        let scratch = try Scratch()
        let mock = MockDropboxService()
        let reported = Reporter()

        let uploaded = try await mock.upload(
            from: scratch.file(named: "notes.txt", contents: "hello world"),
            to: "/notes.txt",
            mode: .add,
            autorename: false,
            clientModified: Date(),
            progress: { reported.record($0) }
        )

        #expect(reported.last == uploaded.size)
    }

    // MARK: - Deletes

    @Test("delete with the current parentRev removes the file")
    func guardedDeleteSucceeds() async throws {
        let mock = MockDropboxService()
        let seeded = try mock.seedFile(at: "/report.txt", contents: "original")

        try await mock.delete(path: "/report.txt", parentRev: seeded.rev)

        #expect(try await mock.metadata(path: "/report.txt", includeDeleted: false) == nil)
    }

    @Test("delete with a stale parentRev is refused")
    func guardedDeleteRefusesStaleRev() async throws {
        let mock = MockDropboxService()
        let seeded = try mock.seedFile(at: "/report.txt", contents: "original")
        try mock.seedFile(at: "/report.txt", contents: "newer")

        await #expect(throws: DropboxServiceError.conflict(path: "/report.txt")) {
            try await mock.delete(path: "/report.txt", parentRev: seeded.rev)
        }
        #expect(try mock.contents(at: "/report.txt") == Data("newer".utf8))
    }

    @Test("deleting a missing path reports not found")
    func deleteMissingPath() async throws {
        let mock = MockDropboxService()
        await #expect(throws: DropboxServiceError.notFound(path: "/gone.txt")) {
            try await mock.delete(path: "/gone.txt", parentRev: nil)
        }
    }

    @Test("deleting a folder removes its children but reports only the folder")
    func folderDeleteReportsOnlyTheFolder() async throws {
        let mock = MockDropboxService()
        try mock.seedFile(at: "/Photos/cat.jpg", contents: "cat")
        try mock.seedFile(at: "/Photos/dog.jpg", contents: "dog")
        let cursor = try await mock.listFolder(path: "", recursive: true).cursor

        try await mock.delete(path: "/Photos", parentRev: nil)

        let delta = try await mock.listFolderContinue(cursor: cursor)
        #expect(delta.entries.count == 1)
        let tombstone = RemoteDeleted(name: "Photos", pathLower: "/photos", pathDisplay: "/Photos")
        #expect(delta.entries[0] == .deleted(tombstone))
        #expect(try await mock.metadata(path: "/Photos/cat.jpg", includeDeleted: false) == nil)
    }

    // MARK: - Moves

    @Test("a move is reported as a delete plus an add, never as a move")
    func moveReportsDeleteAndAdd() async throws {
        let mock = MockDropboxService()
        try mock.seedFile(at: "/old.txt", contents: "content")
        let cursor = try await mock.listFolder(path: "", recursive: true).cursor

        let moved = try await mock.move(from: "/old.txt", to: "/new.txt", autorename: false)
        #expect(moved.pathLower == "/new.txt")

        let delta = try await mock.listFolderContinue(cursor: cursor)
        #expect(delta.entries.count == 2)
        #expect(delta.entries[0].isDeleted)
        #expect(delta.entries[0].pathLower == "/old.txt")
        #expect(delta.entries[1].pathLower == "/new.txt")
        #expect(try mock.contents(at: "/new.txt") == Data("content".utf8))
    }

    @Test("a move keeps the entry's id, the way Dropbox does")
    func movePreservesIdentity() async throws {
        let mock = MockDropboxService()
        let seeded = try mock.seedFile(at: "/old.txt", contents: "content")

        let moved = try await mock.move(from: "/old.txt", to: "/new.txt", autorename: false)
        #expect(moved.asFile?.id == seeded.id)
    }

    @Test("moving onto an occupied path conflicts unless autorename is asked for")
    func moveConflicts() async throws {
        let mock = MockDropboxService()
        try mock.seedFile(at: "/old.txt", contents: "content")
        try mock.seedFile(at: "/new.txt", contents: "occupied")

        await #expect(throws: DropboxServiceError.conflict(path: "/new.txt")) {
            try await mock.move(from: "/old.txt", to: "/new.txt", autorename: false)
        }

        let renamed = try await mock.move(from: "/old.txt", to: "/new.txt", autorename: true)
        #expect(renamed.pathDisplay == "/new (2).txt")
    }

    @Test("moving a folder brings its children along")
    func moveFolderMovesChildren() async throws {
        let mock = MockDropboxService()
        try mock.seedFile(at: "/Photos/cat.jpg", contents: "cat")

        _ = try await mock.move(from: "/Photos", to: "/Pictures", autorename: false)

        #expect(try mock.contents(at: "/Pictures/cat.jpg") == Data("cat".utf8))
        #expect(try await mock.metadata(path: "/Photos/cat.jpg", includeDeleted: false) == nil)
    }

    // MARK: - Folders

    @Test("creating a folder that exists conflicts, or autorenames on request")
    func createFolderSemantics() async throws {
        let mock = MockDropboxService()
        let created = try await mock.createFolder(path: "/Photos", autorename: false)
        #expect(created.pathLower == "/photos")

        await #expect(throws: DropboxServiceError.conflict(path: "/Photos")) {
            try await mock.createFolder(path: "/Photos", autorename: false)
        }

        let renamed = try await mock.createFolder(path: "/Photos", autorename: true)
        #expect(renamed.pathDisplay == "/Photos (2)")
    }

    // MARK: - Metadata & download

    @Test("metadata returns nil for a path that never existed")
    func metadataMissing() async throws {
        let mock = MockDropboxService()
        #expect(try await mock.metadata(path: "/nope.txt", includeDeleted: true) == nil)
    }

    @Test("metadata surfaces a tombstone only when deleted entries are asked for")
    func metadataTombstone() async throws {
        let mock = MockDropboxService()
        try mock.seedFile(at: "/gone.txt", contents: "bye")
        try await mock.delete(path: "/gone.txt", parentRev: nil)

        #expect(try await mock.metadata(path: "/gone.txt", includeDeleted: false) == nil)
        #expect(try await mock.metadata(path: "/gone.txt", includeDeleted: true)?.isDeleted == true)
    }

    @Test("download fetches the exact revision and reports progress")
    func downloadByRev() async throws {
        let scratch = try Scratch()
        let mock = MockDropboxService()
        let first = try mock.seedFile(at: "/report.txt", contents: "original")
        try mock.seedFile(at: "/report.txt", contents: "revised")

        let destination = scratch.url.appending(path: "downloaded.txt")
        let reported = Reporter()
        let metadata = try await mock.download(
            rev: first.rev,
            to: destination,
            progress: { reported.record($0) }
        )

        #expect(metadata.rev == first.rev)
        #expect(try Data(contentsOf: destination) == Data("original".utf8))
        #expect(reported.last == metadata.size)
    }

    @Test("downloading an unknown revision reports not found")
    func downloadUnknownRev() async throws {
        let scratch = try Scratch()
        let mock = MockDropboxService()

        await #expect(throws: DropboxServiceError.notFound(path: "rev:deadbeef")) {
            try await mock.download(
                rev: "deadbeef",
                to: scratch.url.appending(path: "x"),
                progress: noProgress
            )
        }
    }

    // MARK: - Longpoll

    @Test("longpoll reports whether the change log moved past the cursor")
    func longpollDetectsChanges() async throws {
        let mock = MockDropboxService()
        let page = try await mock.listFolder(path: "", recursive: true)

        var result = try await mock.longpoll(cursor: page.cursor, timeout: 30)
        #expect(!result.changes)

        try mock.seedFile(at: "/new.txt", contents: "new")
        result = try await mock.longpoll(cursor: page.cursor, timeout: 30)
        #expect(result.changes)
    }

    @Test("longpoll passes a configured backoff back to the caller")
    func longpollBackoff() async throws {
        let mock = MockDropboxService()
        mock.longpollBackoff = 15
        let page = try await mock.listFolder(path: "", recursive: true)

        let result = try await mock.longpoll(cursor: page.cursor, timeout: 30)
        #expect(result.backoff == 15)
    }

    // MARK: - Account

    @Test("account and usage come back from the configured fixtures")
    func accountFixtures() async throws {
        let mock = MockDropboxService()
        mock.account = AccountInfo(
            accountId: "dbid:team",
            displayName: "Team Account",
            email: "team@example.com",
            accountType: "business",
            isTeam: true,
            profilePhotoURL: nil
        )
        mock.usage = SpaceUsage(used: 1, allocated: 2)

        #expect(try await mock.currentAccount().isTeam)
        #expect(try await mock.spaceUsage().allocated == 2)
    }

    @Test("revoking the token leaves every later call unauthorized")
    func revokeToken() async throws {
        let mock = MockDropboxService()
        try await mock.revokeToken()

        await #expect(throws: DropboxServiceError.notAuthorized) {
            try await mock.currentAccount()
        }
    }

    // MARK: - Error injection

    @Test("an injected failure applies to the next matching call only")
    func failNextIsConsumed() async throws {
        let mock = MockDropboxService()
        mock.failNext(.listFolder, with: .connection)

        await #expect(throws: DropboxServiceError.connection) {
            try await mock.listFolder(path: "", recursive: true)
        }
        _ = try await mock.listFolder(path: "", recursive: true)  // no longer failing
    }

    @Test("an injected failure can be repeated a fixed number of times")
    func failNextRepeats() async throws {
        let mock = MockDropboxService()
        mock.failNext(.currentAccount, with: .rateLimited(retryAfter: 2), times: 2)

        for _ in 0..<2 {
            await #expect(throws: DropboxServiceError.rateLimited(retryAfter: 2)) {
                try await mock.currentAccount()
            }
        }
        _ = try await mock.currentAccount()
    }

    @Test("injected failures are scoped to the call they were queued against")
    func failNextIsScoped() async throws {
        let mock = MockDropboxService()
        mock.failNext(.upload, with: .insufficientSpace)

        _ = try await mock.listFolder(path: "", recursive: true)  // unaffected

        let scratch = try Scratch()
        await #expect(throws: DropboxServiceError.insufficientSpace) {
            try await mock.upload(
                from: scratch.file(named: "a.txt", contents: "a"),
                to: "/a.txt",
                mode: .add,
                autorename: false,
                clientModified: Date(),
                progress: noProgress
            )
        }
    }
}

/// Collects progress callbacks from the fake, which invokes them synchronously.
private final class Reporter: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Int64] = []

    func record(_ value: Int64) {
        lock.withLock { values.append(value) }
    }

    var last: Int64? {
        lock.withLock { values.last }
    }
}

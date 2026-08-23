import Foundation
import Testing

@testable import AusterCore

/// What the user is told, and when (engine-doc §10, ux §8).
///
/// The rules here are mostly about restraint: a sync client that narrated every
/// file would be unusable, and one that stayed quiet about a conflict would be
/// untrustworthy. The composer is where that judgement lives, and it is pure so
/// that it can be argued with in tests rather than in Notification Centre.
@Suite("Notification composer")
struct NotificationBatchingTests {

    private let ownAccount = "dbid:me"

    private func composer(
        suppressed: Bool = false,
        names: [String: String] = [:]
    ) -> NotificationComposer {
        NotificationComposer(
            ownAccountId: { "dbid:me" },
            displayName: { names[$0] },
            changeNotificationsSuppressed: { suppressed }
        )
    }

    private func download(
        _ path: String,
        _ change: ChangeType = .added,
        type: ItemType = .file,
        by accountId: String? = nil
    ) -> SyncItemEvent {
        SyncItemEvent(
            direction: .down,
            changeType: change,
            itemType: type,
            dbxPath: path,
            dbxPathLower: PathStore.normalize(path),
            localURL: URL(fileURLWithPath: "/tmp/Dropbox" + path),
            changedBy: accountId
        )
    }

    // MARK: - One change

    @Test("a single change names who did what to which file")
    func singleChangeReadsAsASentence() throws {
        let notification = try #require(composer().downloadBatch([download("/Notes/todo.md")]))

        #expect(notification.title == "You added todo.md")
        #expect(notification.action == .revealInFinder(dbxPath: "/Notes/todo.md"))
    }

    @Test("each change type gets its own verb")
    func verbsMatchTheChange() throws {
        func title(_ change: ChangeType) throws -> String {
            try #require(composer().downloadBatch([download("/a.txt", change)])).title
        }

        #expect(try title(.added) == "You added a.txt")
        #expect(try title(.modified) == "You changed a.txt")
        #expect(try title(.removed) == "You removed a.txt")
        #expect(try title(.moved) == "You moved a.txt")
    }

    /// Inside a shared folder Dropbox says who wrote the file. Everywhere else
    /// it does not, and everywhere else it was us — on some other machine.
    @Test("a change by somebody else is attributed to them when their name is known")
    func attributionUsesTheAccountCache() throws {
        let known = composer(names: ["dbid:sam": "Sam Vimes"])
        #expect(
            try #require(known.downloadBatch([download("/Shared/a.txt", by: "dbid:sam")])).title
                == "Sam Vimes added a.txt"
        )

        let unknown = composer()
        #expect(
            try #require(unknown.downloadBatch([download("/Shared/a.txt", by: "dbid:sam")])).title
                == "Someone added a.txt"
        )

        #expect(
            try #require(composer().downloadBatch([download("/a.txt", by: ownAccount)])).title
                == "You added a.txt"
        )
    }

    /// A deleted file has nothing left in Finder to point at, so Show goes where
    /// the copy actually is (ux §8).
    @Test("a deletion points at Dropbox's deleted files page")
    func deletionsLinkToDropbox() throws {
        let notification = try #require(composer().downloadBatch([download("/gone.txt", .removed)]))

        #expect(notification.action == .openURL(NotificationComposer.deletedFilesURL))
    }

    // MARK: - Many changes

    @Test("several changes by one person are counted, not listed")
    func batchesAreCounted() throws {
        let events = (1...12).map { download("/Notes/\($0).md", .modified) }

        let notification = try #require(composer().downloadBatch(events))

        #expect(notification.title == "You changed 12 files")
    }

    @Test("changes by more than one person drop the attribution")
    func mixedAuthorsAreImpersonal() throws {
        let events = [
            download("/Shared/a.txt", by: "dbid:sam"),
            download("/Shared/b.txt", by: "dbid:vetinari"),
        ]

        let notification = try #require(composer().downloadBatch(events))

        #expect(notification.title == "2 files changed")
    }

    @Test("a batch of folders and files is counted as items")
    func mixedTypesAreItems() throws {
        let events = [
            download("/Notes/a.txt"),
            download("/Notes/Archive", type: .folder),
        ]

        #expect(try #require(composer().downloadBatch(events)).title == "You changed 2 items")
    }

    @Test("a batch that is all deletions still points at the deleted files page")
    func batchOfDeletionsLinksToDropbox() throws {
        let events = [download("/a.txt", .removed), download("/b.txt", .removed)]

        #expect(
            try #require(composer().downloadBatch(events)).action
                == .openURL(NotificationComposer.deletedFilesURL)
        )
    }

    /// Show has to land on something that exists, so a mixed batch reveals a
    /// file that is still there rather than the one that is not.
    @Test("a mixed batch reveals an item that is still on disk")
    func mixedBatchRevealsSurvivingItem() throws {
        let events = [download("/gone.txt", .removed), download("/kept.txt", .added)]

        #expect(
            try #require(composer().downloadBatch(events)).action
                == .revealInFinder(dbxPath: "/kept.txt")
        )
    }

    @Test("an empty batch says nothing")
    func emptyBatchIsSilent() {
        #expect(composer().downloadBatch([]) == nil)
    }

    // MARK: - Conflicts and failures

    /// A conflicted copy is the one outcome the user has to look at, so it gets
    /// its own notification however many arrived with it.
    @Test("a conflict is announced on its own")
    func conflictsAreIndividual() throws {
        let notification = try #require(composer().conflict(download("/Notes/todo.md", .modified)))

        #expect(notification.title == "Sync conflict")
        #expect(notification.body.contains("todo.md"))
        #expect(notification.action == .revealInFinder(dbxPath: "/Notes/todo.md"))
    }

    @Test("a failed item names the file and what went wrong")
    func itemErrorsExplainThemselves() throws {
        let error = SyncItemError(
            dbxPath: "/Notes/todo.md",
            dbxPathLower: "/notes/todo.md",
            direction: .up,
            title: "Could not upload file",
            message: "Your Dropbox is full."
        )

        let notification = try #require(composer().itemError(error))

        #expect(notification.title == "Could not upload file")
        #expect(notification.body == "todo.md — Your Dropbox is full.")
        #expect(notification.action == .revealInFinder(dbxPath: "/Notes/todo.md"))
    }

    @Test("a fatal error says that sync has stopped")
    func fatalErrorsAreExplicit() throws {
        let notification = try #require(composer().fatal(.dropboxFolderMissing))

        #expect(notification.title == "Auster stopped syncing")
        #expect(notification.body == SyncFatalError.dropboxFolderMissing.errorDescription)
    }

    // MARK: - Snooze and the master switch (ux §8)

    @Test("snoozing silences changes and conflicts")
    func suppressionSilencesChanges() {
        let quiet = composer(suppressed: true)

        #expect(quiet.downloadBatch([download("/a.txt")]) == nil)
        #expect(quiet.conflict(download("/a.txt", .modified)) == nil)
    }

    /// Errors are never suppressed: a snooze is about noise, and something that
    /// is not syncing is not noise.
    @Test("snoozing never silences errors")
    func suppressionNeverSilencesErrors() {
        let quiet = composer(suppressed: true)
        let error = SyncItemError(
            dbxPath: "/a.txt",
            dbxPathLower: "/a.txt",
            direction: .down,
            title: "Could not download file",
            message: "Auster cannot reach Dropbox."
        )

        #expect(quiet.itemError(error) != nil)
        #expect(quiet.fatal(.notAuthorized) != nil)
    }
}

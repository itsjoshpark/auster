import Foundation
import Testing

@testable import AusterCore

/// `SyncItemEvent` is the one shape both directions of the engine work in, so
/// these tests pin down the translation from Dropbox metadata: what counts as an
/// addition versus a modification, how a tombstone recovers the type Dropbox
/// does not report (api-notes §3), and where the casing of the local path comes
/// from (engine-doc §1.4, §9).
@Suite("SyncItemEvent")
struct SyncItemEventTests {

    private func file(
        _ path: String,
        id: String = "id:remote",
        rev: String = "rev1",
        size: Int64 = 3,
        hash: String? = "remotehash",
        symlinkTarget: String? = nil,
        modifiedBy: String? = nil
    ) -> RemoteMetadata {
        .file(
            RemoteFile(
                id: id,
                name: String(path.split(separator: "/").last ?? ""),
                pathLower: path.lowercased(),
                pathDisplay: path,
                rev: rev,
                size: size,
                contentHash: hash,
                clientModified: Date(timeIntervalSince1970: 500),
                serverModified: Date(timeIntervalSince1970: 900),
                symlinkTarget: symlinkTarget,
                isDownloadable: true,
                modifiedBy: modifiedBy
            )
        )
    }

    private func folder(_ path: String, id: String = "id:folder") -> RemoteMetadata {
        .folder(
            RemoteFolder(
                id: id,
                name: String(path.split(separator: "/").last ?? ""),
                pathLower: path.lowercased(),
                pathDisplay: path
            )
        )
    }

    private func deleted(_ path: String) -> RemoteMetadata {
        .deleted(
            RemoteDeleted(
                name: String(path.split(separator: "/").last ?? ""),
                pathLower: path.lowercased(),
                pathDisplay: path
            )
        )
    }

    @Test("A remote file the index has never seen is an addition")
    func unknownFileIsAdded() async throws {
        let fixture = try EngineFixture()

        let event = try await SyncItemEvent(
            remote: file("/Report.txt", rev: "rev7", size: 42, modifiedBy: "dbid:other"),
            index: fixture.database,
            pathStore: fixture.pathStore
        )

        #expect(event.direction == .down)
        #expect(event.changeType == .added)
        #expect(event.itemType == .file)
        #expect(event.dbxPath == "/Report.txt")
        #expect(event.dbxPathLower == "/report.txt")
        #expect(event.localURL == fixture.dropbox.appendingPathComponent("Report.txt"))
        #expect(event.rev == "rev7")
        #expect(event.contentHash == "remotehash")
        #expect(event.size == 42)
        #expect(event.changedBy == "dbid:other")
        #expect(event.dbxId == "id:remote")
        #expect(event.dbxPathFrom == nil)
    }

    @Test("A remote file already in the index is a modification")
    func knownFileIsModified() async throws {
        let fixture = try EngineFixture()
        try fixture.seedIndex("/Report.txt")

        let event = try await SyncItemEvent(
            remote: file("/Report.txt", rev: "rev8"),
            index: fixture.database,
            pathStore: fixture.pathStore
        )

        #expect(event.changeType == .modified)
        #expect(event.rev == "rev8")
    }

    @Test("A remote folder carries the folder sentinel as its rev and hash")
    func folderSentinels() async throws {
        let fixture = try EngineFixture()

        let event = try await SyncItemEvent(
            remote: folder("/Photos"),
            index: fixture.database,
            pathStore: fixture.pathStore
        )

        #expect(event.itemType == .folder)
        #expect(event.rev == ItemType.folderSentinel)
        #expect(event.contentHash == ItemType.folderSentinel)
        #expect(event.size == 0)
    }

    @Test("A tombstone recovers its item type from the index")
    func deletionTakesTypeFromIndex() async throws {
        let fixture = try EngineFixture()
        try fixture.seedIndex("/Photos", type: .folder, id: "id:known")

        let event = try await SyncItemEvent(
            remote: deleted("/Photos"),
            index: fixture.database,
            pathStore: fixture.pathStore
        )

        #expect(event.changeType == .removed)
        #expect(event.itemType == .folder)
        #expect(event.dbxId == "id:known")
        #expect(event.rev == nil)
    }

    @Test("A tombstone for a path the index does not know has no item type")
    func deletionOfUnknownPath() async throws {
        let fixture = try EngineFixture()

        let event = try await SyncItemEvent(
            remote: deleted("/Gone.txt"),
            index: fixture.database,
            pathStore: fixture.pathStore
        )

        #expect(event.changeType == .removed)
        #expect(event.itemType == nil)
        #expect(event.dbxId == nil)
    }

    /// `path_display` is only trustworthy for the basename, so the ancestors
    /// have to come from the index — otherwise the file would land in a second,
    /// differently-cased folder on a case-sensitive volume (api-notes §3).
    @Test("Ancestor casing comes from the index, the basename from the event")
    func ancestorCasingIsCorrected() async throws {
        let fixture = try EngineFixture()
        try fixture.seedIndex("/Photos", type: .folder)

        let event = try await SyncItemEvent(
            remote: file("/photos/Cat.JPG"),
            index: fixture.database,
            pathStore: fixture.pathStore
        )

        #expect(event.dbxPath == "/Photos/Cat.JPG")
        #expect(event.dbxPathLower == "/photos/cat.jpg")
        #expect(
            event.localURL
                == fixture.dropbox.appendingPathComponent("Photos").appendingPathComponent("Cat.JPG")
        )
    }

    /// A remote rename that only changes case must keep the *event's* basename,
    /// not the index's — otherwise §4.6's case-change step would never fire.
    @Test("A casing-only change keeps the event's basename")
    func casingChangeKeepsEventBasename() async throws {
        let fixture = try EngineFixture()
        try fixture.seedIndex("/report.txt")

        let event = try await SyncItemEvent(
            remote: file("/REPORT.TXT"),
            index: fixture.database,
            pathStore: fixture.pathStore
        )

        #expect(event.dbxPath == "/REPORT.TXT")
        #expect(event.dbxPathLower == "/report.txt")
    }

    @Test("A symlink event carries its target and no download-worthy size")
    func symlinkTarget() async throws {
        let fixture = try EngineFixture()

        let event = try await SyncItemEvent(
            remote: file("/link", symlinkTarget: "/elsewhere/target.txt"),
            index: fixture.database,
            pathStore: fixture.pathStore
        )

        #expect(event.symlinkTarget == "/elsewhere/target.txt")
    }
}

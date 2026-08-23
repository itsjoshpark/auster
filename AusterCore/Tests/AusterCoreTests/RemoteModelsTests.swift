import Foundation
import Testing

@testable import AusterCore

/// The remote domain models are the vocabulary every later phase speaks, so
/// their conveniences (path accessors, equality) are pinned down here.
@Suite("RemoteModels")
struct RemoteModelsTests {

    // MARK: - Fixtures

    private static func file(
        path: String = "/photos/cat.jpg",
        rev: String = "0123456789abcdef",
        contentHash: String? = "aaaa"
    ) -> RemoteFile {
        RemoteFile(
            id: "id:abc123",
            name: (path as NSString).lastPathComponent,
            pathLower: path.lowercased(),
            pathDisplay: path,
            rev: rev,
            size: 42,
            contentHash: contentHash,
            clientModified: Date(timeIntervalSince1970: 1_000),
            serverModified: Date(timeIntervalSince1970: 2_000),
            symlinkTarget: nil,
            isDownloadable: true,
            modifiedBy: nil
        )
    }

    private static func folder(path: String = "/Photos") -> RemoteFolder {
        RemoteFolder(
            id: "id:folder1",
            name: (path as NSString).lastPathComponent,
            pathLower: path.lowercased(),
            pathDisplay: path
        )
    }

    private static func deleted(path: String = "/Photos/Old.jpg") -> RemoteDeleted {
        RemoteDeleted(
            name: (path as NSString).lastPathComponent,
            pathLower: path.lowercased(),
            pathDisplay: path
        )
    }

    // MARK: - Path accessors

    @Test("pathLower is readable through the metadata enum for every case")
    func pathLowerAccessor() {
        #expect(RemoteMetadata.file(Self.file(path: "/Photos/Cat.JPG")).pathLower == "/photos/cat.jpg")
        #expect(RemoteMetadata.folder(Self.folder(path: "/Photos")).pathLower == "/photos")
        #expect(RemoteMetadata.deleted(Self.deleted(path: "/Photos/Old.jpg")).pathLower == "/photos/old.jpg")
    }

    @Test("pathDisplay and name are readable through the metadata enum")
    func displayAccessors() {
        #expect(RemoteMetadata.file(Self.file(path: "/Photos/Cat.JPG")).pathDisplay == "/Photos/Cat.JPG")
        #expect(RemoteMetadata.file(Self.file(path: "/Photos/Cat.JPG")).name == "Cat.JPG")
        #expect(RemoteMetadata.folder(Self.folder(path: "/Photos")).pathDisplay == "/Photos")
        #expect(RemoteMetadata.folder(Self.folder(path: "/Photos")).name == "Photos")
        #expect(RemoteMetadata.deleted(Self.deleted()).name == "Old.jpg")
    }

    @Test("isDeleted distinguishes tombstones from live entries")
    func deletionFlag() {
        #expect(RemoteMetadata.deleted(Self.deleted()).isDeleted)
        #expect(!RemoteMetadata.file(Self.file()).isDeleted)
        #expect(!RemoteMetadata.folder(Self.folder()).isDeleted)
    }

    @Test("file and folder payloads are reachable without pattern matching")
    func payloadAccessors() {
        #expect(RemoteMetadata.file(Self.file()).asFile == Self.file())
        #expect(RemoteMetadata.file(Self.file()).asFolder == nil)
        #expect(RemoteMetadata.folder(Self.folder()).asFolder == Self.folder())
        #expect(RemoteMetadata.folder(Self.folder()).asFile == nil)
    }

    // MARK: - Equality

    @Test("metadata equality compares the payload, not just the case")
    func equality() {
        #expect(RemoteMetadata.file(Self.file()) == RemoteMetadata.file(Self.file()))
        #expect(RemoteMetadata.file(Self.file(rev: "a")) != RemoteMetadata.file(Self.file(rev: "b")))
        #expect(RemoteMetadata.folder(Self.folder()) != RemoteMetadata.file(Self.file()))
    }

    @Test("a deleted tombstone never equals a live entry at the same path")
    func tombstoneInequality() {
        let path = "/photos/cat.jpg"
        let live = RemoteMetadata.file(Self.file(path: path))
        let gone = RemoteMetadata.deleted(Self.deleted(path: path))
        #expect(live != gone)
        #expect(live.pathLower == gone.pathLower)
    }

    // MARK: - Write modes

    @Test("update carries the rev it guards against")
    func writeModeUpdate() {
        #expect(WriteMode.update(rev: "abc") == .update(rev: "abc"))
        #expect(WriteMode.update(rev: "abc") != .update(rev: "def"))
        #expect(WriteMode.add != .overwrite)
    }

    // MARK: - Account

    @Test("space usage reports the remaining allowance")
    func spaceUsageRemaining() {
        let usage = SpaceUsage(used: 250, allocated: 1_000)
        #expect(usage.available == 750)
        #expect(usage.fraction == 0.25)
    }

    @Test("an unlimited allocation reports no remaining allowance rather than a negative one")
    func spaceUsageUnlimited() {
        let usage = SpaceUsage(used: 10, allocated: 0)
        #expect(usage.available == 0)
        #expect(usage.fraction == 0)
    }
}

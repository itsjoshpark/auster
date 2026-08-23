import Foundation
import Testing

@testable import AusterCore

/// Dropbox guarantees that applying a delta's entries *in order* reproduces
/// server state, but applying every entry is wasteful and, when an item changed
/// type, wrong. These tests pin the collapse rules of engine-doc §4.2.
@Suite("RemoteChangeCleaner")
struct RemoteChangeCleanerTests {

    private func file(_ path: String, rev: String) -> RemoteMetadata {
        .file(
            RemoteFile(
                id: "id:\(path)",
                name: String(path.split(separator: "/").last ?? ""),
                pathLower: path.lowercased(),
                pathDisplay: path,
                rev: rev,
                size: 1,
                contentHash: "hash-\(rev)",
                clientModified: Date(timeIntervalSince1970: 0),
                serverModified: Date(timeIntervalSince1970: 0),
                symlinkTarget: nil,
                isDownloadable: true,
                modifiedBy: nil
            )
        )
    }

    private func folder(_ path: String) -> RemoteMetadata {
        .folder(
            RemoteFolder(
                id: "id:\(path)",
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

    @Test("Entries the batch touches only once come through untouched")
    func singleEntriesAreUntouched() throws {
        let fixture = try EngineFixture()
        let entries = [folder("/A"), file("/A/one.txt", rev: "r1"), deleted("/B")]

        let cleaned = try RemoteChangeCleaner.clean(entries, index: fixture.database)

        #expect(cleaned == entries)
    }

    @Test("Repeated writes to one path collapse to the last one")
    func repeatedWritesKeepLast() throws {
        let fixture = try EngineFixture()
        let entries = [file("/a.txt", rev: "r1"), file("/a.txt", rev: "r2"), file("/a.txt", rev: "r3")]

        let cleaned = try RemoteChangeCleaner.clean(entries, index: fixture.database)

        #expect(cleaned == [file("/a.txt", rev: "r3")])
    }

    @Test("A create-then-delete pair collapses to the delete")
    func createThenDeleteKeepsDelete() throws {
        let fixture = try EngineFixture()
        let entries = [file("/a.txt", rev: "r1"), deleted("/a.txt")]

        let cleaned = try RemoteChangeCleaner.clean(entries, index: fixture.database)

        #expect(cleaned == [deleted("/a.txt")])
    }

    @Test("Different paths keep the order of their last entries")
    func orderFollowsLastOccurrence() throws {
        let fixture = try EngineFixture()
        let entries = [file("/a.txt", rev: "r1"), file("/b.txt", rev: "r1"), file("/a.txt", rev: "r2")]

        let cleaned = try RemoteChangeCleaner.clean(entries, index: fixture.database)

        #expect(cleaned == [file("/b.txt", rev: "r1"), file("/a.txt", rev: "r2")])
    }

    /// Replacing a folder with a file has to remove the folder first: a bare
    /// file event would find a directory in the way.
    @Test("A folder that became a file gains a synthetic deletion first")
    func typeChangeSynthesizesDeletion() throws {
        let fixture = try EngineFixture()
        try fixture.seedIndex("/Thing", type: .folder)

        let cleaned = try RemoteChangeCleaner.clean([file("/Thing", rev: "r1")], index: fixture.database)

        #expect(cleaned.count == 2)
        #expect(cleaned.first?.isDeleted == true)
        #expect(cleaned.first?.pathLower == "/thing")
        #expect(cleaned.last == file("/Thing", rev: "r1"))
    }

    @Test("A file that became a folder gains a synthetic deletion first")
    func fileBecameFolder() throws {
        let fixture = try EngineFixture()
        try fixture.seedIndex("/Thing", type: .file)

        let cleaned = try RemoteChangeCleaner.clean([folder("/Thing")], index: fixture.database)

        #expect(cleaned.count == 2)
        #expect(cleaned.first?.isDeleted == true)
        #expect(cleaned.last == folder("/Thing"))
    }

    /// The synthetic tombstone stands in for the item the index knows about, so
    /// it carries that item's casing — which is what the local delete needs in
    /// order to pass the exact-casing guard of §4.8.
    @Test("The synthetic deletion carries the index's casing")
    func syntheticDeletionUsesIndexCasing() throws {
        let fixture = try EngineFixture()
        try fixture.seedIndex("/Photos/Thing", type: .folder)

        let cleaned = try RemoteChangeCleaner.clean([file("/photos/thing", rev: "r1")], index: fixture.database)

        #expect(cleaned.first?.pathDisplay == "/Photos/Thing")
        #expect(cleaned.first?.name == "Thing")
    }

    @Test("A matching type needs no synthetic deletion")
    func matchingTypeIsLeftAlone() throws {
        let fixture = try EngineFixture()
        try fixture.seedIndex("/Thing", type: .file)

        let cleaned = try RemoteChangeCleaner.clean([file("/Thing", rev: "r2")], index: fixture.database)

        #expect(cleaned == [file("/Thing", rev: "r2")])
    }

    @Test("A deletion never gains a synthetic deletion of its own")
    func deletionIsNeverDoubled() throws {
        let fixture = try EngineFixture()
        try fixture.seedIndex("/Thing", type: .folder)

        let cleaned = try RemoteChangeCleaner.clean([deleted("/Thing")], index: fixture.database)

        #expect(cleaned == [deleted("/Thing")])
    }

    @Test("A path the index has never seen needs no synthetic deletion")
    func unknownPathIsLeftAlone() throws {
        let fixture = try EngineFixture()

        let cleaned = try RemoteChangeCleaner.clean([file("/New", rev: "r1")], index: fixture.database)

        #expect(cleaned == [file("/New", rev: "r1")])
    }

    /// The collapse is keyed on the normalized path, so two spellings of the
    /// same Dropbox path are one item, not two.
    @Test("Collapsing is case-insensitive")
    func collapseIsCaseInsensitive() throws {
        let fixture = try EngineFixture()
        let entries = [file("/A.txt", rev: "r1"), file("/a.TXT", rev: "r2")]

        let cleaned = try RemoteChangeCleaner.clean(entries, index: fixture.database)

        #expect(cleaned == [file("/a.TXT", rev: "r2")])
    }
}

import AusterCore
import Foundation
import Testing

/// The suite that checks Auster's model of Dropbox against Dropbox
/// (api-notes §7). Each test names the assumption it is defending; those the
/// mock also simulates keep several hundred fast unit tests honest.
@Suite(
    "Dropbox integration",
    .enabled(if: IntegrationHarness.isEnabled, IntegrationHarness.skipReason),
    .serialized,
    .timeLimit(.minutes(10))
)
struct IntegrationTests {

    // MARK: - Transfers

    /// The cross-check promised in Phase 3: Auster's `ContentHasher` has to
    /// produce the same digest Dropbox does, or every "is this file already the
    /// same?" decision in the engine is wrong.
    @Test("a small file round-trips and its content hash matches ours")
    func smallFileRoundTrip() async throws {
        let scope = try await IntegrationScope.make()
        let bytes = Data("the quick brown fox\n".utf8)

        let uploaded = try await scope.upload("small.txt", contents: bytes)
        let source = scope.local("source.txt")
        try bytes.write(to: source)

        #expect(uploaded.contentHash == (try ContentHasher.hash(fileAt: source)))
        #expect(uploaded.size == Int64(bytes.count))

        let (downloaded, data) = try await scope.download(rev: uploaded.rev, as: "small.txt")
        #expect(data == bytes)
        #expect(downloaded.contentHash == uploaded.contentHash)
    }

    /// Above 4 MiB the service switches to an upload session in chunks
    /// (api-notes §6). `MockDropboxService` cannot tell the two apart (note
    /// N19), so this is the only place the chunked path is exercised.
    @Test("a 12 MiB file goes up through an upload session with its hash intact")
    func largeFileUsesUploadSession() async throws {
        let scope = try await IntegrationScope.make()
        // Pseudo-random rather than zeroes: a run of identical blocks would hash
        // correctly even if the chunks were assembled in the wrong order.
        var generator = SeededGenerator(seed: 0x5EED_1234)
        let bytes = Data((0..<(12 * 1024 * 1024)).map { _ in UInt8.random(in: 0...255, using: &generator) })

        let uploaded = try await scope.upload("large.bin", contents: bytes)
        let source = scope.local("large-source.bin")
        try bytes.write(to: source)

        #expect(uploaded.size == Int64(bytes.count))
        #expect(uploaded.contentHash == (try ContentHasher.hash(fileAt: source)))

        let (_, data) = try await scope.download(rev: uploaded.rev, as: "large.bin")
        #expect(data == bytes)
    }

    // MARK: - Change detection

    /// The steady-state loop's whole premise: a change made elsewhere wakes the
    /// longpoll and is then visible through the same cursor (api-notes §2).
    @Test("longpoll reports a remote edit and the cursor delivers it")
    func longpollSeesARemoteEdit() async throws {
        let scope = try await IntegrationScope.make()
        try await scope.upload("watched.txt", contents: Data("before".utf8))

        let page = try await scope.service.listFolder(path: scope.remotePath, recursive: true)
        var cursor = page.cursor

        try await scope.upload("watched.txt", contents: Data("after".utf8), mode: .overwrite)

        // 30 s is the minimum Dropbox accepts; the change is already in, so this
        // returns almost immediately rather than blocking.
        let result = try await scope.service.longpoll(cursor: cursor, timeout: 30)
        #expect(result.changes)

        let delta = try await scope.service.listFolderContinue(cursor: cursor)
        cursor = delta.cursor
        let changed = try #require(delta.entries.first { $0.pathLower.hasSuffix("/watched.txt") }?.asFile)

        let (_, data) = try await scope.download(rev: changed.rev, as: "watched.txt")
        #expect(String(decoding: data, as: UTF8.self) == "after")
    }

    /// A cursor has to survive being used, or an interrupted index would restart
    /// from the beginning every time (decisions D9.4).
    @Test("a cursor keeps working across successive changes")
    func cursorSurvivesSuccessiveChanges() async throws {
        let scope = try await IntegrationScope.make()
        var cursor = try await scope.service.listFolder(path: scope.remotePath, recursive: true).cursor

        for index in 1...3 {
            try await scope.upload("page-\(index).txt", contents: Data("\(index)".utf8))
            let delta = try await scope.service.listFolderContinue(cursor: cursor)
            cursor = delta.cursor
            #expect(delta.entries.contains { $0.pathLower.hasSuffix("/page-\(index).txt") })
        }

        // And an exhausted cursor reports nothing rather than repeating itself.
        let empty = try await scope.service.listFolderContinue(cursor: cursor)
        #expect(empty.entries.isEmpty)
    }

    // MARK: - The safety guarantees (decisions D9)

    /// The single most important thing Auster relies on: an upload against a
    /// revision the server has moved past writes a conflicted copy beside the
    /// original rather than overwriting it or failing.
    @Test("uploading against a stale rev produces a conflicted copy, not an overwrite")
    func staleRevUploadConflicts() async throws {
        let scope = try await IntegrationScope.make()
        let original = try await scope.upload("contested.txt", contents: Data("first".utf8))

        // Somebody else writes; our rev is now stale.
        let theirs = try await scope.upload(
            "contested.txt",
            contents: Data("theirs".utf8),
            mode: .overwrite
        )
        #expect(theirs.rev != original.rev)

        let ours = try await scope.upload(
            "contested.txt",
            contents: Data("ours".utf8),
            mode: .update(rev: original.rev)
        )

        // The server renamed *our* write and left theirs where it was.
        #expect(ours.pathLower != theirs.pathLower)
        #expect(ours.name.hasPrefix("contested"))
        #expect(ours.name.hasSuffix(".txt"))
        // The shape the mock reproduces: "name (something).ext", never a bare
        // overwrite (engine-doc §4.4).
        #expect(ours.name.contains("("))

        let (_, kept) = try await scope.download(rev: theirs.rev, as: "theirs.txt")
        #expect(String(decoding: kept, as: UTF8.self) == "theirs")
    }

    /// The other half of the same argument, on the delete side: a delete guarded
    /// by a revision the server has moved past must be refused, so a remote edit
    /// we have not seen yet is never destroyed (decisions D9.5).
    @Test("deleting with a stale parentRev is refused")
    func staleParentRevDeleteIsRefused() async throws {
        let scope = try await IntegrationScope.make()
        let original = try await scope.upload("guarded.txt", contents: Data("first".utf8))
        try await scope.upload("guarded.txt", contents: Data("second".utf8), mode: .overwrite)

        await #expect(throws: DropboxServiceError.self) {
            try await scope.service.delete(path: scope.remote("guarded.txt"), parentRev: original.rev)
        }

        let survivor = try await scope.service.metadata(
            path: scope.remote("guarded.txt"),
            includeDeleted: false
        )
        #expect(survivor?.asFile != nil)
    }

    // MARK: - Names

    /// Dropbox normalizes names to NFC and macOS routinely reports NFD, and a
    /// client that treats the two spellings as two files duplicates every
    /// accented name it ever sees (engine-doc §9).
    @Test("emoji, decomposed accents and parenthesised suffixes round-trip")
    func specialFilenamesRoundTrip() async throws {
        let scope = try await IntegrationScope.make()

        let names = [
            "hello 🌍 world.txt",
            // Written decomposed (e + combining acute); Dropbox stores composed.
            "cafe\u{0301}.txt",
            "report (1).txt",
            ".dotfile.txt",
            "spaces   and—dashes.txt",
        ]

        for name in names {
            try await scope.upload(name, contents: Data(name.utf8))
        }

        let listing = try await scope.listing()
        for name in names {
            let expected = PathStore.normalize(scope.remote(name))
            let entry = try #require(
                listing.first { PathStore.normalize($0.key) == expected }?.value,
                "\(name) did not come back from the listing"
            )
            let file = try #require(entry.asFile)
            let (_, data) = try await scope.download(rev: file.rev, as: "roundtrip.bin")
            #expect(String(decoding: data, as: UTF8.self) == name)
        }
    }

    /// A name at the filesystem's byte limit is the one most likely to be
    /// truncated somewhere in the round trip.
    @Test("a 255-byte name round-trips")
    func longNameRoundTrips() async throws {
        let scope = try await IntegrationScope.make()
        let name = String(repeating: "a", count: 251) + ".txt"

        let uploaded = try await scope.upload(name, contents: Data("long".utf8))

        #expect(uploaded.name == name)
        #expect(uploaded.name.utf8.count == 255)
    }
}

/// A reproducible byte source, so a failing large-upload run can be repeated
/// with the same data.
private struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed == 0 ? 0x9E37_79B9_7F4A_7C15 : seed
    }

    mutating func next() -> UInt64 {
        // xorshift64*, which is plenty for test data and needs no dependency.
        state ^= state >> 12
        state ^= state << 25
        state ^= state >> 27
        return state &* 2_685_821_657_736_338_717
    }
}

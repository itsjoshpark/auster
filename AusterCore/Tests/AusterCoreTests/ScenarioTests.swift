import Foundation
import Testing

@testable import AusterCore

/// The engine's acceptance tests: whole scenarios end to end against an
/// in-memory Dropbox and a real local folder (design §6), each ending in the
/// same assertion. Serialized: several drive a live FSEvents stream.
@Suite("Scenarios", .serialized)
struct ScenarioTests {

    private func expectConverged(_ harness: ScenarioHarness, _ comment: Comment? = nil) throws {
        let problems = try harness.convergenceProblems()
        #expect(problems.isEmpty, comment ?? "\(problems)")
    }

    // MARK: - One side at a time

    @Test("Changes made only on Dropbox converge")
    func remoteOnlyChanges() async throws {
        let harness = try ScenarioHarness()
        harness.remoteFolder("/Work")
        try harness.remoteWrite("/Work/notes.txt", "notes")
        try harness.remoteWrite("/top.txt", "top")

        try await harness.syncBothWays()

        #expect(try harness.localContents("/Work/notes.txt") == "notes")
        try expectConverged(harness)
    }

    @Test("Changes made only in the local folder converge")
    func localOnlyChanges() async throws {
        let harness = try ScenarioHarness()
        try harness.localWrite("/Work/notes.txt", "notes")
        try harness.localWrite("/top.txt", "top")

        try await harness.syncBothWays()

        #expect(try String(decoding: harness.service.contents(at: "/Work/notes.txt"), as: UTF8.self) == "notes")
        try expectConverged(harness)
    }

    @Test("A remote deletion and a remote edit both converge")
    func remoteEditAndDelete() async throws {
        let harness = try ScenarioHarness()
        try harness.remoteWrite("/keep.txt", "first")
        try harness.remoteWrite("/drop.txt", "doomed")
        try await harness.syncBothWays()

        try harness.remoteWrite("/keep.txt", "second")
        try await harness.remoteDelete("/drop.txt")
        try await harness.syncBothWays()

        #expect(try harness.localContents("/keep.txt") == "second")
        #expect(!harness.localExists("/drop.txt"))
        try expectConverged(harness)
    }

    // MARK: - The echo test

    /// Every file a download writes lands in a folder that is being watched, so
    /// without the ignore mechanism (§5.2) each one would immediately be seen as
    /// a local change and uploaded straight back — forever.
    @Test("Downloading produces no local events to upload")
    func downloadsDoNotEcho() async throws {
        let harness = try ScenarioHarness()
        harness.remoteFolder("/Photos")
        try harness.remoteWrite("/Photos/cat.jpg", "meow")
        try harness.remoteWrite("/Photos/dog.jpg", "woof")
        try harness.remoteWrite("/top.txt", "top")

        try await harness.startWatching()
        try await harness.runDownloadCycle()
        try await harness.settle()

        let echoes = harness.drainEvents()
        #expect(echoes.isEmpty, "\(echoes.map { "\($0.kind) \($0.url.lastPathComponent)" })")
    }

    /// The other half of the same guarantee: the filter must not be so eager
    /// that it swallows what the user does next.
    @Test("A real local edit after a download is still noticed")
    func realEditsSurviveTheFilter() async throws {
        let harness = try ScenarioHarness()
        try harness.remoteWrite("/a.txt", "downloaded")

        try await harness.startWatching()
        try await harness.runDownloadCycle()
        try await harness.settle()
        _ = harness.drainEvents()

        try harness.localWrite("/a.txt", "edited by the user")
        try await harness.settle()

        #expect(harness.drainEvents().contains { $0.url == harness.local("/a.txt") })
    }

    // MARK: - Conflicts

    /// Neither version is discarded: the local one is preserved beside the
    /// remote one under a conflicted-copy name (decisions D9.1).
    @Test("Editing the same file on both sides keeps both versions")
    func bothSidesEditedKeepsBoth() async throws {
        let harness = try ScenarioHarness()
        try harness.remoteWrite("/report.txt", "original")
        try await harness.syncBothWays()

        try harness.localWrite("/report.txt", "the user's version")
        // Backdate the index so the local edit reads as unsynced.
        var entry = try #require(try harness.database.indexEntry(forPathLower: "/report.txt"))
        entry.lastSync = Date(timeIntervalSince1970: 1_000)
        try harness.database.upsertIndexEntry(entry)
        try harness.remoteWrite("/report.txt", "someone else's version")

        try await harness.syncBothWays()

        let names = try harness.localNames()
        #expect(names.count == 2)
        #expect(names.contains("report.txt"))
        let copy = try #require(names.first { $0.contains("conflicted copy") })
        #expect(try harness.localContents("/report.txt") == "someone else's version")
        #expect(try harness.localContents("/" + copy) == "the user's version")
        try expectConverged(harness)
    }

    /// A remote deletion must never win over work that has not been uploaded
    /// yet — the file stays, and goes back up.
    @Test("A local edit survives a remote deletion")
    func localEditBeatsRemoteDelete() async throws {
        let harness = try ScenarioHarness()
        try harness.remoteWrite("/notes.txt", "original")
        try await harness.syncBothWays()

        try harness.localWrite("/notes.txt", "edited, not yet uploaded")
        var entry = try #require(try harness.database.indexEntry(forPathLower: "/notes.txt"))
        entry.lastSync = Date(timeIntervalSince1970: 1_000)
        try harness.database.upsertIndexEntry(entry)
        try await harness.remoteDelete("/notes.txt")

        try await harness.syncBothWays()

        #expect(try harness.localContents("/notes.txt") == "edited, not yet uploaded")
        try expectConverged(harness)
    }

    /// The mirror image: the local copy is gone, but the remote has a version we
    /// never saw, so the delete is refused and the newer file comes back.
    @Test("A local deletion does not destroy a remote edit we have not seen")
    func remoteEditBeatsLocalDelete() async throws {
        let harness = try ScenarioHarness()
        try harness.remoteWrite("/notes.txt", "original")
        try await harness.syncBothWays()

        try harness.localDelete("/notes.txt")
        try harness.remoteWrite("/notes.txt", "someone else's edit")

        try await harness.runCatchUp()
        try await harness.runDownloadCycle()

        #expect(try harness.localContents("/notes.txt") == "someone else's edit")
        try expectConverged(harness)
    }

    // MARK: - Offline

    @Test("A batch of offline changes converges, deletions included")
    func offlineBatchConverges() async throws {
        let harness = try ScenarioHarness()
        try harness.remoteWrite("/keep.txt", "keep")
        try harness.remoteWrite("/gone.txt", "gone")
        try harness.remoteWrite("/Work/old.txt", "old")
        try await harness.syncBothWays()

        // Now imagine Auster was not running for any of this.
        try harness.localDelete("/gone.txt")
        try harness.localWrite("/Work/new.txt", "new")
        try harness.localWrite("/keep.txt", "edited offline")

        try await harness.runCatchUp()

        #expect(!harness.service.allEntries.contains { $0.pathLower == "/gone.txt" })
        #expect(try String(decoding: harness.service.contents(at: "/Work/new.txt"), as: UTF8.self) == "new")
        #expect(
            try String(decoding: harness.service.contents(at: "/keep.txt"), as: UTF8.self)
                == "edited offline")
        try expectConverged(harness)
    }

    // MARK: - Moves

    /// A folder move is one API call that takes the subtree with it. Doing it as
    /// a delete and a re-upload would work, but would cost a transfer per file
    /// and throw away every file's revision history.
    @Test("Moving a folder locally becomes a single remote move")
    func localFolderMoveIsOneRemoteCall() async throws {
        let harness = try ScenarioHarness()
        harness.remoteFolder("/A")
        try harness.remoteWrite("/A/cat.jpg", "meow")
        try harness.remoteWrite("/A/2024/dog.jpg", "woof")
        try await harness.syncBothWays()

        try await harness.startWatching()
        try harness.localMove("/A", to: "/B")
        try await harness.settle()
        try await harness.runUploadCycle()

        #expect(harness.service.recordedMoves.count == 1)
        #expect(harness.service.recordedUploads.isEmpty)
        #expect(harness.service.allEntries.contains { $0.pathLower == "/b/2024/dog.jpg" })
        try expectConverged(harness)
    }

    @Test("Renaming a file locally becomes a remote move, not a re-upload")
    func localFileRenameIsAMove() async throws {
        let harness = try ScenarioHarness()
        try harness.remoteWrite("/before.txt", "same bytes")
        try await harness.syncBothWays()

        try await harness.startWatching()
        try harness.localMove("/before.txt", to: "/after.txt")
        try await harness.settle()
        try await harness.runUploadCycle()

        #expect(harness.service.allEntries.contains { $0.pathLower == "/after.txt" })
        #expect(!harness.service.allEntries.contains { $0.pathLower == "/before.txt" })
        try expectConverged(harness)
    }

    // MARK: - Exclusions

    @Test("Files Auster never syncs are never uploaded")
    func excludedNamesAreNeverUploaded() async throws {
        let harness = try ScenarioHarness()
        try harness.localWrite("/.DS_Store", "finder junk")
        try harness.localWrite("/Work/Thumbs.db", "windows junk")
        try harness.localWrite("/Work/real.txt", "real")

        try await harness.runCatchUp()

        #expect(harness.service.recordedUploads.map(\.path) == ["/Work/real.txt"])
        try expectConverged(harness)
    }

    @Test("A deselected folder is neither downloaded nor indexed")
    func deselectedFolderStaysAway() async throws {
        let harness = try ScenarioHarness(excluded: ["/private"])
        try harness.remoteWrite("/Private/secret.txt", "secret")
        try harness.remoteWrite("/Public/open.txt", "open")

        try await harness.runDownloadCycle()

        #expect(!harness.localExists("/Private"))
        #expect(try harness.localContents("/Public/open.txt") == "open")
    }

    // MARK: - Transfers

    /// Above 4 MiB `LiveDropboxService` switches to an upload session, which
    /// `DropboxService` hides, so what the engine can be held to here is that a
    /// large file round-trips with its content hash intact.
    @Test("A file larger than the chunk threshold round-trips intact")
    func largeFileRoundTrips() async throws {
        let harness = try ScenarioHarness()
        let payload = Data((0..<(12 * 1024 * 1024)).map { UInt8($0 % 251) })
        let url = harness.local("/big.bin")
        try payload.write(to: url)

        try await harness.runCatchUp()

        #expect(try harness.service.contents(at: "/big.bin") == payload)
        #expect(
            try harness.database.indexEntry(forPathLower: "/big.bin")?.contentHash
                == ContentHasher.hash(data: payload))
        try expectConverged(harness)
    }
}

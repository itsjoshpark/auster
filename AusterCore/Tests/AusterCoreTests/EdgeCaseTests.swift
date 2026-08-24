import Foundation
import Testing

@testable import AusterCore

/// The long tail (engine-doc §9): things that happen to a real Dropbox
/// eventually, and that a syncer either survives quietly or fails at invisibly.
@Suite("Edge cases", .serialized)
struct EdgeCaseTests {

    // MARK: - Names

    /// macOS reports decomposed names and Dropbox stores composed ones. A client
    /// that treats the two spellings as two files uploads the same file forever,
    /// renaming it back and forth (engine-doc §9).
    @Test("a decomposed local name uploads as one file and does not loop")
    func decomposedNamesDoNotLoop() async throws {
        let harness = try ScenarioHarness()
        // "café" written as e + U+0301, the way the filesystem hands it back.
        let decomposed = "/cafe\u{0301}.txt"
        try harness.localWrite(decomposed, "beans")

        try await harness.runCatchUp()

        let remote = harness.service.allEntries.compactMap(\.asFile)
        #expect(remote.count == 1)
        #expect(PathStore.equalButForUnicodeNorm(remote[0].name, "café.txt"))

        // A second pass has nothing to say: if the composed remote name were
        // read as a different file, this is where the second upload would appear.
        let uploadsBefore = harness.service.recordedUploads.count
        try await harness.runDownloadCycle()
        try await harness.runCatchUp()
        #expect(harness.service.recordedUploads.count == uploadsBefore)
        #expect(harness.service.allEntries.compactMap(\.asFile).count == 1)
        #expect(try harness.convergenceProblems().isEmpty)
    }

    @Test("emoji, leading dots and deep paths round-trip both ways")
    func awkwardNamesRoundTrip() async throws {
        let harness = try ScenarioHarness()
        let names = [
            "/hello 🌍 world.txt",
            "/.hidden-but-synced.txt",
            "/report (1).txt",
            "/" + String(repeating: "a", count: 251) + ".txt",
            "/" + (1...20).map { "level\($0)" }.joined(separator: "/") + "/deep.txt",
        ]
        for name in names { try harness.localWrite(name, name) }

        try await harness.runCatchUp()

        for name in names {
            let key = PathStore.normalize(name)
            #expect(
                harness.service.allEntries.contains { PathStore.normalize($0.pathLower) == key },
                "\(name) never reached the remote"
            )
        }
        #expect(try harness.convergenceProblems().isEmpty)
    }

    /// `Icon\r` is Finder's custom-folder-icon file. It is never synced, and it
    /// is the one excluded name with a control character in it — the sort of
    /// thing a path comparison quietly mangles (engine-doc §8).
    @Test("Icon\\r is never uploaded")
    func iconResourceFileIsExcluded() async throws {
        let harness = try ScenarioHarness()
        try harness.localWrite("/Icon\r", "icon")
        try harness.localWrite("/real.txt", "real")

        try await harness.runCatchUp()

        let uploaded = harness.service.recordedUploads.map(\.path)
        #expect(uploaded.contains { $0.hasSuffix("/real.txt") })
        #expect(!uploaded.contains { $0.lowercased().contains("icon") })
    }

    // MARK: - Timestamps

    /// A file whose uploader had a fast clock must not land in the future: a
    /// local mtime ahead of now makes every later "has this changed?" comparison
    /// wrong (engine-doc §4.6 step 6).
    @Test("a client_modified in the future is clamped on the way down")
    func futureTimestampsAreClamped() async throws {
        let fixture = try EngineFixture()
        let future = Date().addingTimeInterval(60 * 60 * 24 * 365)
        try fixture.service.seedFile(at: "/soon.txt", contents: "later", clientModified: future)

        try await fixture.makeEngine().downloadCycle()

        let attributes = try FileManager.default.attributesOfItem(atPath: fixture.local("/soon.txt").path)
        let mtime = try #require(attributes[.modificationDate] as? Date)
        #expect(mtime <= Date().addingTimeInterval(5))
    }

    // MARK: - The filesystem refusing

    /// A folder that cannot be written to is the shape every "disk full" and
    /// "permission denied" failure arrives in: the item becomes a sync issue,
    /// the rest of the cycle lands, and the staging directory is left clean.
    @Test("a file that cannot be written is recorded and does not stop the cycle")
    func unwritableDestinationBecomesASyncIssue() async throws {
        let fixture = try EngineFixture()
        try fixture.makeLocalFolder("/Locked")
        try fixture.service.seedFile(at: "/Locked/blocked.txt", contents: "nope")
        try fixture.service.seedFile(at: "/fine.txt", contents: "yes")

        let locked = fixture.local("/Locked")
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: locked.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: locked.path)
        }

        try await fixture.makeEngine().downloadCycle()

        #expect(try fixture.localContents("/fine.txt") == "yes")
        let errors = try fixture.database.syncErrors()
        #expect(errors.contains { $0.dbxPathLower == "/locked/blocked.txt" })
        #expect(errors.allSatisfy { $0.direction == .down })

        // The staging directory is emptied whatever happened, so an abandoned
        // download does not occupy disk until the next restart.
        #expect(!FileManager.default.fileExists(atPath: fixture.fileOps.cacheDir.path))
    }

    /// Making a file read-only changes its ctime, which is indistinguishable
    /// from editing it, so the engine sets it aside rather than replacing it
    /// (engine-doc §4.4 rule 5). The permission bits go with it.
    @Test("a read-only file is set aside rather than overwritten by a remote update")
    func readOnlyFilesAreNeverOverwritten() async throws {
        let harness = try ScenarioHarness()
        try harness.remoteWrite("/locked.txt", "first")
        try await harness.runDownloadCycle()

        let url = harness.local("/locked.txt")
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: url.path)

        try harness.remoteWrite("/locked.txt", "second")
        try await harness.runDownloadCycle()

        // The remote version landed…
        #expect(try harness.localContents("/locked.txt") == "second")

        // …and the protected one is still here, unmodified and still read-only.
        let names = try harness.localNames()
        let copy = try #require(names.first { $0.contains("conflicted copy") })
        let copyURL = harness.dropbox.appendingPathComponent(copy, isDirectory: false)
        #expect(String(decoding: try Data(contentsOf: copyURL), as: UTF8.self) == "first")

        let mode = try #require(
            (try FileManager.default.attributesOfItem(atPath: copyURL.path))[.posixPermissions] as? NSNumber
        )
        #expect(mode.int16Value == 0o444)
        _ = url
    }

    // MARK: - Symlinks

    /// Dropbox stores a symlink as metadata, not as content. A second machine
    /// has to get a symlink back — not a file containing the target's path, and
    /// not the target's bytes (engine-doc §4.6 step 4).
    @Test("a symlink in Dropbox arrives at a second client as a symlink")
    func symlinksReachASecondClient() async throws {
        let first = try ScenarioHarness()
        try first.remoteWrite("/target.txt", "pointed at")
        first.service.seedSymlink(at: "/link.txt", target: "target.txt")

        try await first.runDownloadCycle()

        let link = first.local("/link.txt")
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == "target.txt")
        #expect(try first.localContents("/target.txt") == "pointed at")

        // The index remembers that it is a link, so a second cycle has nothing
        // to do rather than re-fetching it as content.
        let indexed = try #require(try first.database.indexEntry(forPathLower: "/link.txt"))
        #expect(indexed.symlinkTarget == "target.txt")

        // A third machine, coming to the same Dropbox cold.
        let second = try ScenarioHarness(service: first.service)
        try await second.runDownloadCycle()
        #expect(
            try FileManager.default.destinationOfSymbolicLink(atPath: second.local("/link.txt").path)
                == "target.txt"
        )
    }

    /// `files/upload` cannot create a symlink, so a link made locally goes up as
    /// its target's content. What matters is that this is quiet and stable: no
    /// error, and no second upload on the next pass.
    @Test("a local symlink uploads as its target's content without looping")
    func localSymlinksUploadWithoutLooping() async throws {
        let harness = try ScenarioHarness()
        try harness.localWrite("/target.txt", "pointed at")
        try FileManager.default.createSymbolicLink(
            atPath: harness.local("/link.txt").path,
            withDestinationPath: "target.txt"
        )

        try await harness.runCatchUp()

        let uploaded = try #require(
            harness.service.allEntries.compactMap(\.asFile).first { $0.pathLower == "/link.txt" }
        )
        #expect(uploaded.contentHash == (try harness.hasher.localHash(at: harness.local("/target.txt"))))

        let uploadsAfterFirstPass = harness.service.recordedUploads.count
        try await harness.runDownloadCycle()
        try await harness.runCatchUp()
        #expect(harness.service.recordedUploads.count == uploadsAfterFirstPass)
    }
    // MARK: - Waking up

    /// The longpoll is dead after sleep and FSEvents owes nothing about other
    /// devices, so waking re-checks both sides rather than trusting either loop
    /// to notice (ux §9).
    @Test("waking up re-checks both directions")
    func wakingRunsBothCycles() async throws {
        let fixture = try await SelectiveSyncFixture()
        try fixture.service.seedFile(at: "/before.txt", contents: "before")
        await fixture.startOnce()

        // Two changes made while "asleep": one on each side.
        try fixture.service.seedFile(at: "/remote.txt", contents: "remote")
        try Data("local".utf8).write(to: fixture.local("/local.txt"))

        await fixture.coordinator.syncNow()

        #expect(try fixture.localContents("/remote.txt") == "remote")
        #expect(fixture.service.allEntries.contains { $0.pathLower == "/local.txt" })
    }

    /// Waking a paused laptop is not a request to un-pause it.
    @Test("waking up while paused stays paused")
    func wakingWhilePausedDoesNothing() async throws {
        let fixture = try await SelectiveSyncFixture()
        await fixture.startOnce()
        await fixture.coordinator.pause()

        try fixture.service.seedFile(at: "/ignored.txt", contents: "ignored")
        await fixture.coordinator.syncNow()

        #expect(!fixture.localExists("/ignored.txt"))
        #expect(await MainActor.run { fixture.state.status == .paused })
    }
}

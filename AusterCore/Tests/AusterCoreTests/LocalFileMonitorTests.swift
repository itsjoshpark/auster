import Foundation
import Testing

@testable import AusterCore

/// The FSEvents watcher against a real temp directory: what matters is that
/// macOS delivers what the decoder expects. Serialized, because each test drives
/// a live event stream with real timing.
@Suite("LocalFileMonitor", .serialized)
struct LocalFileMonitorTests {

    /// Long enough for FSEvents' 50 ms latency plus scheduling, short enough not
    /// to dominate the suite.
    private static let settle = Duration.milliseconds(900)

    private struct Harness {
        let root: URL
        let ignore: IgnoreFilter
        let monitor: LocalFileMonitor
    }

    private func withMonitor<T>(_ body: (Harness) async throws -> T) async throws -> T {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("auster-monitor-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let ignore = IgnoreFilter()
        let monitor = LocalFileMonitor(root: root, ignore: ignore)
        defer { monitor.stop() }

        // The monitor reports paths in the vocabulary it was handed, so the
        // harness uses the same unresolved root the engine would.
        return try await body(Harness(root: root.standardizedFileURL, ignore: ignore, monitor: monitor))
    }

    /// Runs `body`, then gathers whatever the monitor reports within the settle
    /// window.
    private func collect(
        _ harness: Harness,
        during body: @escaping @Sendable () throws -> Void
    ) async throws -> [RawFSEvent] {
        try harness.monitor.start()
        // FSEvents needs a moment between starting and being able to see
        // anything; without this the first test operation is routinely missed.
        try await Task.sleep(for: .milliseconds(300))

        let collector = Task {
            var collected: [RawFSEvent] = []
            for await event in harness.monitor.events { collected.append(event) }
            return collected
        }

        try body()
        try await Task.sleep(for: Self.settle)
        collector.cancel()
        return await collector.value
    }

    private func write(_ contents: String, to url: URL) throws {
        try Data(contents.utf8).write(to: url)
    }

    // MARK: - Live events

    @Test("Creating, modifying and deleting a file all reach the stream")
    func basicEventsArrive() async throws {
        try await withMonitor { harness in
            let file = harness.root.appendingPathComponent("a.txt")

            let events = try await collect(harness) {
                try write("one", to: file)
                try write("two", to: file)
                try FileManager.default.removeItem(at: file)
            }

            #expect(!events.isEmpty)
            #expect(events.allSatisfy { $0.url == file })
            // The file is gone by the time the batch is decoded, so the last
            // word on it is a deletion.
            #expect(events.contains { $0.kind == .deleted })
        }
    }

    @Test("A new folder is reported as a directory")
    func folderCreationIsReported() async throws {
        try await withMonitor { harness in
            let folder = harness.root.appendingPathComponent("Photos")

            let events = try await collect(harness) {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            }

            #expect(events.contains { $0.url == folder && $0.isDirectory && $0.kind == .created })
        }
    }

    /// The echo test in miniature, and the reason the filter exists: without it
    /// every download would immediately queue itself for upload.
    @Test("A mutation performed inside an ignore produces no event")
    func ignoredMutationIsSilent() async throws {
        try await withMonitor { harness in
            let file = harness.root.appendingPathComponent("engine-wrote-this.txt")

            let events = try await collect(harness) {
                try harness.ignore.ignoring([
                    ExpectedFSEvent(kind: .created, url: file, isDirectory: false, recursive: false),
                    ExpectedFSEvent(kind: .modified, url: file, isDirectory: false, recursive: false),
                ]) {
                    try write("downloaded", to: file)
                }
            }

            #expect(!events.contains { $0.url == file })
        }
    }

    @Test("An unrelated file is still reported while another is being ignored")
    func ignoringIsScopedToItsPath() async throws {
        try await withMonitor { harness in
            let ignored = harness.root.appendingPathComponent("ignored.txt")
            let watched = harness.root.appendingPathComponent("watched.txt")

            let events = try await collect(harness) {
                try harness.ignore.ignoring([
                    ExpectedFSEvent(kind: .created, url: ignored, isDirectory: false, recursive: false),
                    ExpectedFSEvent(kind: .modified, url: ignored, isDirectory: false, recursive: false),
                ]) {
                    try write("engine", to: ignored)
                }
                try write("user", to: watched)
            }

            #expect(events.contains { $0.url == watched })
            #expect(!events.contains { $0.url == ignored })
        }
    }

    /// A rename should decode as one move, but a split into delete + create is
    /// an acceptable reading — §5.3 recombines what it can and the upload
    /// handlers converge either way.
    @Test("A rename arrives either as a move or as a delete and a create")
    func renameIsReported() async throws {
        try await withMonitor { harness in
            let before = harness.root.appendingPathComponent("before.txt")
            let after = harness.root.appendingPathComponent("after.txt")
            try write("same", to: before)
            try await Task.sleep(for: .milliseconds(200))

            let events = try await collect(harness) {
                try FileManager.default.moveItem(at: before, to: after)
            }

            let asMove = events.contains { $0.url == before && $0.kind == .moved(to: after) }
            let deletedSource = events.contains { $0.url == before && $0.kind == .deleted }
            let createdDestination = events.contains { $0.url == after && $0.kind == .created }
            let asSplit = deletedSource && createdDestination
            #expect(asMove || asSplit)
        }
    }

    // MARK: - Rescans

    @Test("Rescanning a file reports it as modified")
    func rescanFile() async throws {
        let fixture = try EngineFixture()
        let monitor = LocalFileMonitor(root: fixture.dropbox, ignore: IgnoreFilter())
        let file = try fixture.writeLocal("/a.txt", "hello")

        monitor.synthesizeRescan(of: file, index: fixture.database, pathStore: fixture.pathStore)

        var iterator = monitor.events.makeAsyncIterator()
        let event = try #require(await iterator.next())
        #expect(event.kind == .modified)
        #expect(event.url == file.resolvingSymlinksInPath().standardizedFileURL)
    }

    /// A conflicted copy can be a whole folder, and nothing inside it has been
    /// seen by the watcher either.
    @Test("Rescanning a folder reports the folder and everything inside it")
    func rescanFolderWalksIt() async throws {
        let fixture = try EngineFixture()
        let monitor = LocalFileMonitor(root: fixture.dropbox, ignore: IgnoreFilter())
        let folder = try fixture.makeLocalFolder("/Photos")
        try fixture.writeLocal("/Photos/cat.jpg", "meow")
        try fixture.writeLocal("/Photos/2024/dog.jpg", "woof")

        monitor.synthesizeRescan(of: folder, index: fixture.database, pathStore: fixture.pathStore)

        var collected: [RawFSEvent] = []
        var iterator = monitor.events.makeAsyncIterator()
        for _ in 0..<4 {
            guard let event = await iterator.next() else { break }
            collected.append(event)
        }

        let names = collected.map(\.url.lastPathComponent)
        #expect(collected.allSatisfy { $0.kind == .created })
        #expect(names.contains("Photos"))
        #expect(names.contains("cat.jpg"))
        #expect(names.contains("dog.jpg"))
    }

    @Test("Rescanning a path the index knows but the disk lost reports a deletion")
    func rescanMissingIndexedPath() async throws {
        let fixture = try EngineFixture()
        let monitor = LocalFileMonitor(root: fixture.dropbox, ignore: IgnoreFilter())
        try fixture.seedIndex("/gone.txt")

        monitor.synthesizeRescan(
            of: fixture.local("/gone.txt"),
            index: fixture.database,
            pathStore: fixture.pathStore
        )

        var iterator = monitor.events.makeAsyncIterator()
        let event = try #require(await iterator.next())
        #expect(event.kind == .deleted)
    }

    /// Nothing on disk and nothing in the index means there is nothing to tell
    /// Dropbox about — emitting a deletion would be inventing one.
    @Test("Rescanning a path neither side knows reports nothing")
    func rescanMissingUnknownPath() async throws {
        let fixture = try EngineFixture()
        let monitor = LocalFileMonitor(root: fixture.dropbox, ignore: IgnoreFilter())

        monitor.synthesizeRescan(
            of: fixture.local("/never.txt"),
            index: fixture.database,
            pathStore: fixture.pathStore
        )
        // Prove the stream stayed empty by putting a known event behind it.
        monitor.synthesizeRescan(
            of: try fixture.writeLocal("/marker.txt", "x"),
            index: fixture.database,
            pathStore: fixture.pathStore
        )

        var iterator = monitor.events.makeAsyncIterator()
        let event = try #require(await iterator.next())
        #expect(event.url.lastPathComponent == "marker.txt")
    }
}

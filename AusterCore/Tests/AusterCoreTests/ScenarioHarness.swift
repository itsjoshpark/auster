import Foundation

@testable import AusterCore

/// A whole two-way syncer in a temp directory: the in-memory Dropbox, a real
/// database, a real FSEvents watcher wired through the real ignore filter, and
/// the engine on top of them (design §6).
///
/// The scenario tests are the engine's acceptance tests, so this deliberately
/// assembles the *production* object graph rather than test doubles of it. The
/// echo test in particular is only meaningful if the ignore filter and the
/// watcher are the ones the app would use.
final class ScenarioHarness {

    let root: URL
    let dropbox: URL
    let service: MockDropboxService
    let database: SyncDatabase
    let pathStore: PathStore
    let hasher: CachedContentHasher
    let ignore: IgnoreFilter
    let monitor: LocalFileMonitor
    let fileOps: LocalFileOperations
    let engine: SyncEngine

    private let collector: EventCollector
    private var watcher: Task<Void, Never>?

    /// Passing an existing `service` is how a *second* client is simulated: a
    /// fresh local folder and a fresh index over a Dropbox that already has
    /// something in it.
    init(excluded: Set<String> = [], service: MockDropboxService = MockDropboxService()) throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("auster-scenario-\(UUID().uuidString)")
        dropbox = root.appendingPathComponent("Dropbox", isDirectory: false)
        try FileManager.default.createDirectory(at: dropbox, withIntermediateDirectories: true)

        self.service = service
        database = try SyncDatabase(path: root.appendingPathComponent("sync.db").path)
        pathStore = PathStore(dropboxRoot: dropbox, database: database, service: service)
        hasher = CachedContentHasher(database: database)
        ignore = IgnoreFilter()
        monitor = LocalFileMonitor(root: dropbox, ignore: ignore)
        fileOps = LocalFileOperations(root: dropbox, ignore: ignore)
        collector = EventCollector()

        engine = SyncEngine(
            service: service,
            database: database,
            pathStore: pathStore,
            hasher: hasher,
            fileOps: fileOps,
            excludedItems: { excluded },
            events: SyncEngineEvents()
        )
    }

    deinit {
        watcher?.cancel()
        monitor.stop()
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Watching

    /// Starts the real watcher and waits for it to become live.
    func startWatching() async throws {
        try monitor.start()
        let collector = collector
        let events = monitor.events
        watcher = Task {
            for await event in events { collector.append(event) }
        }
        // FSEvents does not see anything until the stream has been running for a
        // moment; without this the first change of a scenario is missed.
        try await Task.sleep(for: .milliseconds(300))
    }

    /// Waits long enough for FSEvents to have delivered whatever is pending.
    func settle() async throws {
        try await Task.sleep(for: .milliseconds(700))
    }

    func drainEvents() -> [RawFSEvent] {
        collector.drain()
    }

    // MARK: - Remote changes

    func remoteWrite(_ path: String, _ contents: String) throws {
        try service.seedFile(at: path, contents: contents)
    }

    func remoteFolder(_ path: String) {
        service.seedFolder(at: path)
    }

    func remoteDelete(_ path: String) async throws {
        try await service.delete(path: path, parentRev: nil)
    }

    // MARK: - Local changes

    func local(_ dbxPath: String) -> URL {
        pathStore.toLocalURL(dbxPathCased: dbxPath)
    }

    @discardableResult
    func localWrite(_ dbxPath: String, _ contents: String) throws -> URL {
        let url = local(dbxPath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(contents.utf8).write(to: url)
        return url
    }

    func localFolder(_ dbxPath: String) throws {
        try FileManager.default.createDirectory(at: local(dbxPath), withIntermediateDirectories: true)
    }

    func localDelete(_ dbxPath: String) throws {
        try FileManager.default.removeItem(at: local(dbxPath))
    }

    func localMove(_ from: String, to destination: String) throws {
        try FileManager.default.moveItem(at: local(from), to: local(destination))
    }

    func localContents(_ dbxPath: String) throws -> String {
        String(decoding: try Data(contentsOf: local(dbxPath)), as: UTF8.self)
    }

    func localExists(_ dbxPath: String) -> Bool {
        FileManager.default.fileExists(atPath: local(dbxPath).path)
    }

    /// Every name directly inside a folder.
    func localNames(in dbxPath: String = "") throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: local(dbxPath).path)
            .filter { !Exclusions.isExcludedName($0) }
            .sorted()
    }

    // MARK: - Cycles

    func runDownloadCycle() async throws {
        try await engine.downloadCycle()
    }

    /// Runs an upload cycle over whatever the watcher has collected.
    func runUploadCycle() async throws {
        try await engine.uploadCycle(rawEvents: drainEvents())
    }

    func runCatchUp() async throws {
        try await engine.catchUpScan()
    }

    /// Both directions until nothing is left to do.
    func syncBothWays() async throws {
        try await runDownloadCycle()
        try await runCatchUp()
    }

    // MARK: - Convergence

    /// Everything the three sources of truth disagree about.
    ///
    /// Convergence is the only assertion that matters for a syncer, and it is
    /// three-way: the disk, the remote, and the index that claims to describe
    /// both. An empty result means a user looking at either side would see the
    /// same thing, and a restart would not undo it.
    func convergenceProblems() throws -> [String] {
        var problems: [String] = []

        let local = try localTree()
        let remote = remoteTree()
        let indexed = try indexTree()

        for path in Set(local.keys).union(remote.keys).union(indexed.keys).sorted() {
            let onDisk = local[path]
            let onRemote = remote[path]
            let inIndex = indexed[path]

            guard let onDisk, let onRemote else {
                problems.append(
                    "\(path): disk=\(onDisk.map(\.description) ?? "absent")"
                        + " remote=\(onRemote.map(\.description) ?? "absent")"
                        + " index=\(inIndex.map(\.description) ?? "absent")"
                )
                continue
            }
            if onDisk != onRemote {
                problems.append("\(path): disk \(onDisk) but remote \(onRemote)")
            }
            guard let inIndex else {
                problems.append("\(path): present on both sides but missing from the index")
                continue
            }
            if inIndex.isDirectory != onDisk.isDirectory {
                problems.append("\(path): index says \(inIndex) but disk says \(onDisk)")
            }
        }
        return problems
    }

    /// What an item looks like, reduced to the two things both sides can agree
    /// on: whether it is a folder, and what its bytes hash to.
    struct Item: Equatable, CustomStringConvertible {
        var isDirectory: Bool
        var contentHash: String?

        var description: String {
            isDirectory ? "folder" : "file(\(contentHash?.prefix(8) ?? "?"))"
        }
    }

    private func localTree() throws -> [String: Item] {
        var tree: [String: Item] = [:]
        var pending = [dropbox]

        while let directory = pending.popLast() {
            for child in DirectoryListing.children(of: directory) {
                guard !Exclusions.isExcludedName(child.url.lastPathComponent) else { continue }
                let path = PathStore.normalize(try pathStore.toDbxPath(localURL: child.url))
                tree[path] = Item(
                    isDirectory: child.isDirectory,
                    contentHash: child.isDirectory ? nil : try hasher.localHash(at: child.url)
                )
                if child.isDirectory { pending.append(child.url) }
            }
        }
        return tree
    }

    private func remoteTree() -> [String: Item] {
        var tree: [String: Item] = [:]
        for entry in service.allEntries {
            switch entry {
            case .file(let file):
                tree[PathStore.normalize(file.pathLower)] = Item(
                    isDirectory: false,
                    contentHash: file.contentHash
                )
            case .folder(let folder):
                tree[PathStore.normalize(folder.pathLower)] = Item(isDirectory: true, contentHash: nil)
            case .deleted:
                break
            }
        }
        return tree
    }

    private func indexTree() throws -> [String: Item] {
        var tree: [String: Item] = [:]
        for entry in try database.allIndexEntries() {
            tree[entry.dbxPathLower] = Item(
                isDirectory: entry.itemType == .folder,
                contentHash: entry.itemType == .folder ? nil : entry.contentHash
            )
        }
        return tree
    }
}

/// Accumulates monitor events off the watcher task.
private final class EventCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [RawFSEvent] = []

    func append(_ event: RawFSEvent) {
        lock.withLock { storage.append(event) }
    }

    func drain() -> [RawFSEvent] {
        lock.withLock {
            defer { storage.removeAll() }
            return storage
        }
    }
}

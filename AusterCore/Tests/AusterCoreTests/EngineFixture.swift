import Foundation

@testable import AusterCore

/// A whole engine environment in a throwaway temp directory: an in-memory
/// remote, a real on-disk database, a local Dropbox folder, and the path/hash
/// helpers built on them.
///
/// A class rather than a struct so `deinit` can remove the directory: Swift
/// Testing runs tests in parallel, so each one needs its own filesystem and its
/// own cleanup, and a `defer` in every test would be one place to forget.
final class EngineFixture {

    /// The temp directory holding everything below.
    let root: URL

    /// The local Dropbox folder.
    let dropbox: URL

    let service: MockDropboxService
    let database: SyncDatabase
    let pathStore: PathStore
    let hasher: CachedContentHasher
    let fileOps: LocalFileOperations

    init() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("auster-engine-\(UUID().uuidString)")
        dropbox = root.appendingPathComponent("Dropbox")
        try FileManager.default.createDirectory(at: dropbox, withIntermediateDirectories: true)

        service = MockDropboxService()
        database = try SyncDatabase(path: root.appendingPathComponent("sync.db").path)
        pathStore = PathStore(dropboxRoot: dropbox, database: database, service: service)
        hasher = CachedContentHasher(database: database)
        fileOps = LocalFileOperations(root: dropbox)
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Local helpers

    /// The local URL for a Dropbox path, without consulting the index.
    func local(_ dbxPath: String) -> URL {
        pathStore.toLocalURL(dbxPathCased: dbxPath)
    }

    /// Writes a local file, creating its parents.
    @discardableResult
    func writeLocal(_ dbxPath: String, _ contents: String) throws -> URL {
        let url = local(dbxPath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(contents.utf8).write(to: url)
        return url
    }

    /// Creates a local folder, including parents.
    @discardableResult
    func makeLocalFolder(_ dbxPath: String) throws -> URL {
        let url = local(dbxPath)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func localContents(_ dbxPath: String) throws -> String {
        String(decoding: try Data(contentsOf: local(dbxPath)), as: UTF8.self)
    }

    func localExists(_ dbxPath: String) -> Bool {
        FileManager.default.fileExists(atPath: local(dbxPath).path)
    }

    // MARK: - Index helpers

    /// Seeds an index row, defaulting the fields a test does not care about.
    @discardableResult
    func seedIndex(
        _ dbxPathCased: String,
        type: ItemType = .file,
        id: String = "id:seed",
        rev: String = "seedrev",
        hash: String? = nil,
        lastSync: Date? = Date(timeIntervalSince1970: 1_000_000),
        symlinkTarget: String? = nil
    ) throws -> IndexEntry {
        let entry = IndexEntry(
            dbxPathLower: PathStore.normalize(dbxPathCased),
            dbxPathCased: dbxPathCased,
            dbxId: id,
            itemType: type,
            lastSync: lastSync,
            rev: type == .folder ? ItemType.folderSentinel : rev,
            contentHash: type == .folder ? ItemType.folderSentinel : hash,
            symlinkTarget: symlinkTarget
        )
        try database.upsertIndexEntry(entry)
        return entry
    }

    func indexEntry(_ dbxPath: String) throws -> IndexEntry? {
        try database.indexEntry(forPathLower: PathStore.normalize(dbxPath))
    }

    // MARK: - Engine helpers

    /// The download event the engine would build for whatever the mock remote
    /// currently holds at `dbxPath`.
    func downloadEvent(_ dbxPath: String, includeDeleted: Bool = false) async throws -> SyncItemEvent {
        guard let metadata = try await service.metadata(path: dbxPath, includeDeleted: includeDeleted) else {
            throw DropboxServiceError.notFound(path: dbxPath)
        }
        return try await SyncItemEvent(remote: metadata, index: database, pathStore: pathStore)
    }

    /// The upload event the engine would build for a local change.
    func uploadEvent(_ raw: RawFSEvent) throws -> SyncItemEvent {
        try SyncItemEvent(local: raw, index: database, pathStore: pathStore, hasher: hasher)
    }

    func makeUploadApplier(
        excludedItems: @escaping @Sendable () -> Set<String> = { [] },
        events: SyncEngineEvents = SyncEngineEvents()
    ) -> UploadApplier {
        UploadApplier(
            service: service,
            database: database,
            pathStore: pathStore,
            hasher: hasher,
            fileOps: fileOps,
            events: events,
            excludedItems: excludedItems,
            stabilityPollInterval: .zero
        )
    }

    func makeEngine(
        excludedItems: @escaping @Sendable () -> Set<String> = { [] },
        events: SyncEngineEvents = SyncEngineEvents()
    ) -> SyncEngine {
        SyncEngine(
            service: service,
            database: database,
            pathStore: pathStore,
            hasher: hasher,
            fileOps: fileOps,
            excludedItems: excludedItems,
            events: events
        )
    }

    func makeApplier(
        ownerName: String? = "Mock User",
        events: SyncEngineEvents = SyncEngineEvents()
    ) -> DownloadApplier {
        DownloadApplier(
            service: service,
            database: database,
            pathStore: pathStore,
            hasher: hasher,
            fileOps: fileOps,
            events: events,
            ownerName: ownerName
        )
    }
}

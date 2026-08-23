import Foundation
import SwiftyDropbox

/// The real Dropbox, behind `DropboxService`.
///
/// Everything SDK-shaped stops here: callbacks become `async`, `CallError`
/// becomes `DropboxServiceError`, `Files.Metadata` becomes `RemoteMetadata`, and
/// transient failures are absorbed by `withRetry` so callers see one call's
/// worth of outcome (api-notes §5).
///
/// Concurrency: this is a plain `final class` with immutable state and no actor
/// isolation on purpose. `DropboxClient` and the SDK's model types are not
/// `Sendable`, so every SDK value is created, awaited and converted inside one
/// non-isolated method — nothing SDK-shaped ever crosses an isolation boundary.
/// The client itself is safe to call concurrently (it owns a `URLSession`), so
/// the `@unchecked Sendable` is on the reference, not on shared mutable state.
public final class LiveDropboxService: DropboxService, @unchecked Sendable {

    private let client: DropboxClient
    private let sleeper: any RetrySleeper
    private let policy: RetryPolicy

    /// Files at or below this size go up in a single call; larger ones use an
    /// upload session in chunks of the same size (api-notes §6). It matches the
    /// content-hash block size, so a chunk is exactly one hash block.
    static let singleCallUploadLimit = ContentHasher.blockSize

    /// `client` must already be authorized: `AuthManager` owns the linking, and
    /// this type only makes calls.
    public init(
        client: DropboxClient,
        policy: RetryPolicy = .standard,
        sleeper: any RetrySleeper = SystemSleeper()
    ) {
        self.client = client
        self.policy = policy
        self.sleeper = sleeper
    }

    // MARK: - Account

    public func currentAccount() async throws -> AccountInfo {
        let account = try await run(path: nil) { client.users.getCurrentAccount() }
        return AccountInfo(
            accountId: account.accountId,
            displayName: account.name.displayName,
            email: account.email,
            accountType: Self.name(of: account.accountType),
            // A personal account has no team; a team member always does. This is
            // the check that rejects team accounts at link time (decisions D4).
            isTeam: account.team != nil,
            profilePhotoURL: account.profilePhotoUrl.flatMap(URL.init(string:))
        )
    }

    public func spaceUsage() async throws -> SpaceUsage {
        let usage = try await run(path: nil) { client.users.getSpaceUsage() }
        let allocated: UInt64 =
            switch usage.allocation {
            case .individual(let individual): individual.allocated
            case .team(let team): team.allocated
            case .other: 0
            }
        return SpaceUsage(used: Int64(usage.used), allocated: Int64(allocated))
    }

    public func revokeToken() async throws {
        _ = try await run(path: nil) { client.auth.tokenRevoke() }
    }

    // MARK: - Listing

    public func listFolder(path: String, recursive: Bool) async throws -> ListPage {
        let result = try await run(path: path) {
            client.files.listFolder(
                path: path,
                recursive: recursive,
                includeDeleted: false,
                limit: 2000
            )
        }
        return Self.page(from: result)
    }

    public func listFolderContinue(cursor: String) async throws -> ListPage {
        let result = try await run(path: nil) { client.files.listFolderContinue(cursor: cursor) }
        return Self.page(from: result)
    }

    public func longpoll(cursor: String, timeout: Int) async throws -> (changes: Bool, backoff: Int?) {
        // Not retried here: the caller owns the longpoll loop and its own
        // backoff, and a retry inside a 30–480 s call would just stack waits.
        let result = try await run(path: nil, policy: .never) {
            client.files.listFolderLongpoll(cursor: cursor, timeout: UInt64(timeout))
        }
        return (result.changes, result.backoff.map(Int.init))
    }

    // MARK: - Single items

    public func metadata(path: String, includeDeleted: Bool) async throws -> RemoteMetadata? {
        do {
            let metadata = try await run(path: path) {
                client.files.getMetadata(path: path, includeDeleted: includeDeleted)
            }
            return Self.convert(metadata)
        } catch DropboxServiceError.notFound {
            // "Never existed" is an answer, not a failure.
            return nil
        }
    }

    // MARK: - Transfers

    public func download(
        rev: String,
        to localURL: URL,
        progress: @escaping @Sendable (Int64) -> Void
    ) async throws -> RemoteFile {
        // Addressed by rev, not path: we get the exact revision the engine
        // decided to apply even if the path has moved on since (api-notes §2).
        let revPath = "rev:\(rev)"

        return try await withRetry(policy: policy, sleeper: sleeper) {
            let metadata: Files.FileMetadata
            do {
                metadata = try await client.files
                    .download(path: revPath, overwrite: true, destination: localURL)
                    .progress { progress($0.completedUnitCount) }
                    .response()
                    .0
            } catch let error as CallError<Files.DownloadError> {
                throw DropboxErrorMapper.map(error, path: revPath)
            }

            // The SDK writes the file itself, so the hash is checked on the
            // written bytes rather than mid-stream. A file that fails is deleted
            // before throwing, so a partial download is never left staged for
            // the atomic move (decisions D9.3).
            if let expected = metadata.contentHash {
                let actual = try ContentHasher.hash(fileAt: localURL)
                guard actual == expected else {
                    try? FileManager.default.removeItem(at: localURL)
                    throw DropboxServiceError.dataCorrupted(path: metadata.pathDisplay ?? revPath)
                }
            }

            guard let file = Self.convert(metadata)?.asFile else {
                throw DropboxServiceError.other(message: "downloaded \(revPath) has no path")
            }
            progress(file.size)
            return file
        }
    }

    public func upload(
        from localURL: URL,
        to dbxPath: String,
        mode: WriteMode,
        autorename: Bool,
        clientModified: Date,
        progress: @escaping @Sendable (Int64) -> Void
    ) async throws -> RemoteFile {
        try await withRetry(policy: policy, sleeper: sleeper) {
            let snapshot = try Self.snapshot(of: localURL)
            let uploaded: Files.FileMetadata =
                if snapshot.size <= Int64(Self.singleCallUploadLimit) {
                    try await uploadInOneCall(
                        from: localURL,
                        to: dbxPath,
                        mode: mode,
                        autorename: autorename,
                        clientModified: clientModified,
                        snapshot: snapshot,
                        progress: progress
                    )
                } else {
                    try await uploadInSession(
                        from: localURL,
                        to: dbxPath,
                        mode: mode,
                        autorename: autorename,
                        clientModified: clientModified,
                        snapshot: snapshot,
                        progress: progress
                    )
                }

            guard let file = Self.convert(uploaded)?.asFile else {
                throw DropboxServiceError.other(message: "uploaded \(dbxPath) has no path")
            }
            return file
        }
    }

    // MARK: - Mutations

    public func delete(path: String, parentRev: String?) async throws {
        _ = try await run(path: path) {
            client.files.deleteV2(path: path, parentRev: parentRev)
        }
    }

    public func move(from: String, to: String, autorename: Bool) async throws -> RemoteMetadata {
        let result = try await run(path: to) {
            client.files.moveV2(fromPath: from, toPath: to, autorename: autorename)
        }
        guard let moved = Self.convert(result.metadata) else {
            throw DropboxServiceError.other(message: "moved \(from) has no path")
        }
        return moved
    }

    public func createFolder(path: String, autorename: Bool) async throws -> RemoteFolder {
        let result = try await run(path: path) {
            client.files.createFolderV2(path: path, autorename: autorename)
        }
        guard let folder = Self.convert(result.metadata)?.asFolder else {
            throw DropboxServiceError.other(message: "created \(path) has no path")
        }
        return folder
    }

    // MARK: - Uploading

    /// What the file looked like when we started, so a change underneath us is
    /// detectable rather than silently committed.
    private struct Snapshot {
        var size: Int64
        var modified: Date
    }

    private static func snapshot(of url: URL) throws -> Snapshot {
        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        } catch {
            throw DropboxServiceError.other(message: "cannot read \(url.path): \(error)")
        }
        return Snapshot(
            size: (attributes[.size] as? NSNumber)?.int64Value ?? 0,
            modified: attributes[.modificationDate] as? Date ?? .distantPast
        )
    }

    /// Throws if the file moved on since `snapshot` — committing a torn read
    /// would put bytes on Dropbox that never existed locally (decisions D9.1).
    private static func verifyUnchanged(_ snapshot: Snapshot, at url: URL, path: String) throws {
        let now = try Self.snapshot(of: url)
        guard now.size == snapshot.size, now.modified == snapshot.modified else {
            throw DropboxServiceError.fileChangedDuringUpload(path: path)
        }
    }

    private func uploadInOneCall(
        from localURL: URL,
        to dbxPath: String,
        mode: WriteMode,
        autorename: Bool,
        clientModified: Date,
        snapshot: Snapshot,
        progress: @escaping @Sendable (Int64) -> Void
    ) async throws -> Files.FileMetadata {
        let data: Data
        do {
            data = try Data(contentsOf: localURL, options: .mappedIfSafe)
        } catch {
            throw DropboxServiceError.other(message: "cannot read \(localURL.path): \(error)")
        }
        try Self.verifyUnchanged(snapshot, at: localURL, path: dbxPath)

        do {
            return try await client.files
                .upload(
                    path: dbxPath,
                    mode: Self.convert(mode),
                    autorename: autorename,
                    clientModified: clientModified,
                    contentHash: ContentHasher.hash(data: data),
                    input: data
                )
                .progress { progress($0.completedUnitCount) }
                .response()
        } catch let error as CallError<Files.UploadError> {
            throw DropboxErrorMapper.map(error, path: dbxPath)
        }
    }

    private func uploadInSession(
        from localURL: URL,
        to dbxPath: String,
        mode: WriteMode,
        autorename: Bool,
        clientModified: Date,
        snapshot: Snapshot,
        progress: @escaping @Sendable (Int64) -> Void
    ) async throws -> Files.FileMetadata {
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: localURL)
        } catch {
            throw DropboxServiceError.other(message: "cannot read \(localURL.path): \(error)")
        }
        defer { try? handle.close() }

        func nextChunk() throws -> Data {
            do {
                return try handle.read(upToCount: Self.singleCallUploadLimit) ?? Data()
            } catch {
                throw DropboxServiceError.other(message: "cannot read \(localURL.path): \(error)")
            }
        }

        var sent: Int64 = 0
        let first = try nextChunk()
        let sessionId: String
        do {
            sessionId = try await client.files
                .uploadSessionStart(contentHash: ContentHasher.hash(data: first), input: first)
                .response()
                .sessionId
        } catch let error as CallError<Files.UploadSessionStartError> {
            throw DropboxErrorMapper.map(error, path: dbxPath)
        }
        sent += Int64(first.count)
        progress(sent)

        // Hold back the final chunk: `uploadSessionFinish` commits it, which
        // saves a round trip and keeps the commit atomic.
        var pending = try nextChunk()
        while true {
            let following = try nextChunk()
            if following.isEmpty { break }
            let cursor = Files.UploadSessionCursor(sessionId: sessionId, offset: UInt64(sent))
            do {
                try await client.files
                    .uploadSessionAppendV2(
                        cursor: cursor,
                        contentHash: ContentHasher.hash(data: pending),
                        input: pending
                    )
                    .response()
            } catch let error as CallError<Files.UploadSessionAppendError> {
                throw DropboxErrorMapper.map(error, path: dbxPath)
            }
            sent += Int64(pending.count)
            progress(sent)
            pending = following
        }

        try Self.verifyUnchanged(snapshot, at: localURL, path: dbxPath)

        let cursor = Files.UploadSessionCursor(sessionId: sessionId, offset: UInt64(sent))
        let commit = Files.CommitInfo(
            path: dbxPath,
            mode: Self.convert(mode),
            autorename: autorename,
            clientModified: clientModified
        )
        do {
            let finished = try await client.files
                .uploadSessionFinish(
                    cursor: cursor,
                    commit: commit,
                    contentHash: ContentHasher.hash(data: pending),
                    input: pending
                )
                .response()
            progress(sent + Int64(pending.count))
            return finished
        } catch let error as CallError<Files.UploadSessionFinishError> {
            throw DropboxErrorMapper.map(error, path: dbxPath)
        }
    }

    // MARK: - Calling

    /// Runs one RPC route with retries and error mapping.
    private func run<R: JSONSerializer, E: JSONSerializer>(
        path: String?,
        policy overridePolicy: RetryPolicy? = nil,
        _ make: () -> RpcRequest<R, E>
    ) async throws -> R.ValueType {
        try await withRetry(policy: overridePolicy ?? policy, sleeper: sleeper) {
            do {
                return try await make().response()
            } catch let error as CallError<E.ValueType> {
                throw DropboxErrorMapper.map(error, path: path)
            }
        }
    }

    // MARK: - Conversion

    private static func page(from result: Files.ListFolderResult) -> ListPage {
        ListPage(
            entries: result.entries.compactMap(convert),
            cursor: result.cursor,
            hasMore: result.hasMore
        )
    }

    /// Converts one SDK metadata value.
    ///
    /// Returns `nil` when Dropbox reports no path — which happens for entries
    /// that are not mounted in this account's namespace. There is nothing the
    /// engine could do with such an entry, so it is dropped from listings.
    private static func convert(_ metadata: Files.Metadata) -> RemoteMetadata? {
        guard let pathLower = metadata.pathLower, let pathDisplay = metadata.pathDisplay else {
            return nil
        }

        switch metadata {
        case let file as Files.FileMetadata:
            return .file(
                RemoteFile(
                    id: file.id,
                    name: file.name,
                    pathLower: pathLower,
                    pathDisplay: pathDisplay,
                    rev: file.rev,
                    size: Int64(file.size),
                    contentHash: file.contentHash,
                    clientModified: file.clientModified,
                    serverModified: file.serverModified,
                    symlinkTarget: file.symlinkInfo?.target,
                    isDownloadable: file.isDownloadable,
                    modifiedBy: file.sharingInfo?.modifiedBy
                )
            )

        case let folder as Files.FolderMetadata:
            return .folder(
                RemoteFolder(
                    id: folder.id,
                    name: folder.name,
                    pathLower: pathLower,
                    pathDisplay: pathDisplay
                )
            )

        default:
            // `DeletedMetadata`, and anything the SDK adds later that we can
            // only treat as a tombstone.
            return .deleted(
                RemoteDeleted(name: metadata.name, pathLower: pathLower, pathDisplay: pathDisplay)
            )
        }
    }

    private static func convert(_ mode: WriteMode) -> Files.WriteMode {
        switch mode {
        case .add: .add
        case .overwrite: .overwrite
        case .update(let rev): .update(rev)
        }
    }

    private static func name(of accountType: UsersCommon.AccountType) -> String {
        switch accountType {
        case .basic: "basic"
        case .pro: "pro"
        case .business: "business"
        }
    }
}

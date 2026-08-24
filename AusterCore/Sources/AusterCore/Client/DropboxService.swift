import Foundation

/// Everything Auster asks of Dropbox. The engine only talks to this protocol,
/// which is what lets it be tested headless against `MockDropboxService`. Every
/// method throws `DropboxServiceError`; retries live behind the implementation.
public protocol DropboxService: Sendable {

    // MARK: Account

    /// The linked account. Also serves as an authentication probe.
    func currentAccount() async throws -> AccountInfo

    func spaceUsage() async throws -> SpaceUsage

    // MARK: Listing

    /// Starts a listing. `path` is `""` for the Dropbox root, never `"/"`.
    func listFolder(path: String, recursive: Bool) async throws -> ListPage

    /// Continues a listing, or fetches changes since `cursor`. Throws
    /// `.cursorReset` when Dropbox invalidates the cursor; the caller must then
    /// discard it and re-index from scratch (api-notes §5).
    func listFolderContinue(cursor: String) async throws -> ListPage

    /// Blocks until something changes after `cursor` or `timeout` seconds pass.
    /// `timeout` must be 30–480 seconds and the server adds up to 90 s of jitter.
    /// The reply carries a server-requested backoff to sleep through.
    func longpoll(cursor: String, timeout: Int) async throws -> (changes: Bool, backoff: Int?)

    // MARK: Single items

    /// Metadata for one path, or `nil` when nothing is (or was) there.
    func metadata(path: String, includeDeleted: Bool) async throws -> RemoteMetadata?

    // MARK: Transfers

    /// Downloads a specific revision to `localURL`, verifying the content hash as
    /// the bytes stream past. `localURL` is a staging path the caller moves into
    /// place atomically (D9.3); a mismatch deletes it and throws `.dataCorrupted`.
    func download(
        rev: String,
        to localURL: URL,
        progress: @escaping @Sendable (Int64) -> Void
    ) async throws -> RemoteFile

    /// Uploads a local file, in one call at or below 4 MiB and through an upload
    /// session above it (api-notes §6). A file that changes mid-read is abandoned
    /// with `.fileChangedDuringUpload` rather than committing a torn snapshot.
    func upload(
        from localURL: URL,
        to dbxPath: String,
        mode: WriteMode,
        autorename: Bool,
        clientModified: Date,
        progress: @escaping @Sendable (Int64) -> Void
    ) async throws -> RemoteFile

    // MARK: Mutations

    /// Deletes a path. `parentRev` makes a file delete conditional on the remote
    /// still being at that revision, so a remote edit we have not seen yet is
    /// never destroyed (decisions D9.5). Folders do not support the guard.
    func delete(path: String, parentRev: String?) async throws

    func move(from: String, to: String, autorename: Bool) async throws -> RemoteMetadata

    func createFolder(path: String, autorename: Bool) async throws -> RemoteFolder

    // MARK: Session

    /// Revokes the access token server-side. Clearing local credentials is the
    /// caller's job.
    func revokeToken() async throws
}

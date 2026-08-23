import Foundation

/// Everything Auster asks of Dropbox.
///
/// The sync engine only ever talks to this protocol, which is what lets the
/// whole engine be tested headless against `MockDropboxService`. Every method
/// throws `DropboxServiceError` and nothing else; retries and backoff live
/// behind the implementation, so callers see one attempt's worth of outcome.
public protocol DropboxService: Sendable {

    // MARK: Account

    /// The linked account. Also serves as an authentication probe.
    func currentAccount() async throws -> AccountInfo

    func spaceUsage() async throws -> SpaceUsage

    // MARK: Listing

    /// Starts a listing. `path` is `""` for the Dropbox root, never `"/"`.
    func listFolder(path: String, recursive: Bool) async throws -> ListPage

    /// Continues a listing, or fetches changes since `cursor`.
    ///
    /// Throws `.cursorReset` when Dropbox invalidates the cursor; the caller
    /// must then discard it and re-index from scratch (api-notes §5).
    func listFolderContinue(cursor: String) async throws -> ListPage

    /// Blocks until something changes after `cursor` or `timeout` seconds pass.
    ///
    /// `timeout` must be 30–480 seconds; the server adds up to 90 s of jitter on
    /// top. The reply says whether there are changes, and carries a
    /// server-requested backoff to sleep through before longpolling again.
    func longpoll(cursor: String, timeout: Int) async throws -> (changes: Bool, backoff: Int?)

    // MARK: Single items

    /// Metadata for one path, or `nil` when nothing is (or was) there.
    func metadata(path: String, includeDeleted: Bool) async throws -> RemoteMetadata?

    // MARK: Transfers

    /// Downloads a specific revision to `localURL`, verifying the content hash
    /// as the bytes stream past.
    ///
    /// Addressing by `rev` rather than path means we get exactly the version the
    /// engine decided to apply, even if the path has moved on since. `localURL`
    /// is a staging path in the cache directory; the caller moves it into place
    /// atomically (decisions D9.3). On an unrecoverable hash mismatch the partial
    /// file is deleted and `.dataCorrupted` is thrown.
    ///
    /// `progress` receives the cumulative bytes written so far.
    func download(
        rev: String,
        to localURL: URL,
        progress: @escaping @Sendable (Int64) -> Void
    ) async throws -> RemoteFile

    /// Uploads a local file, in one call at or below 4 MiB and through an upload
    /// session above it (api-notes §6).
    ///
    /// If the file changes while it is being read, the upload is abandoned with
    /// `.fileChangedDuringUpload` rather than committing a torn snapshot.
    ///
    /// `progress` receives the cumulative bytes sent so far.
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

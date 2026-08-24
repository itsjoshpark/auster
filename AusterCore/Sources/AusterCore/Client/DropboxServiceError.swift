import Foundation

/// Every failure the sync engine has to reason about, named in the engine's own
/// terms rather than the SDK's (api-notes §5). Cases exist only where the engine
/// reacts differently; anything it can only log and skip becomes `.other`.
public enum DropboxServiceError: Error, Sendable, Equatable {

    /// Nothing at that path, and nothing ever was.
    case notFound(path: String)

    /// A file sits where a folder should go, or vice versa (`file`, `folder`,
    /// `file_ancestor` write conflicts).
    case conflict(path: String)

    /// The token was revoked or is invalid. The SDK refreshes expired *access*
    /// tokens on its own, so reaching this means re-linking (api-notes §5).
    case notAuthorized

    /// The account is out of space. Uploads stay pending; nothing is discarded.
    case insufficientSpace

    /// Content the app is not permitted to sync (DMCA takedowns and similar).
    case restrictedContent(path: String)

    /// A name Dropbox refuses, such as a reserved filename.
    case disallowedName(path: String)

    /// The path is not well formed for Dropbox — bad casing of the root, an
    /// illegal character, or a missing leading slash.
    case malformedPath(path: String)

    /// Namespace write contention. Retryable, and common when many writes land
    /// on the same folder at once.
    case tooManyWriteOperations

    /// HTTP 429. Wait `retryAfter` before trying again.
    case rateLimited(retryAfter: TimeInterval)

    /// A transfer's content hash never matched after the retry budget. The
    /// partial file has already been removed.
    case dataCorrupted(path: String)

    /// The local file changed while we were reading it, so the upload would have
    /// committed a torn snapshot. Re-read and retry from the engine.
    case fileChangedDuringUpload(path: String)

    /// Offline, timed out, or 5xx after retries. Sync pauses rather than fails.
    case connection

    /// `list_folder/continue` reported `reset`: the cursor is void and the whole
    /// remote has to be re-indexed.
    case cursorReset

    /// Anything the engine cannot act on specifically.
    case other(message: String)
}

extension DropboxServiceError {

    /// Whether waiting and repeating the same call could plausibly succeed.
    /// `Retry` gates on this rather than spelling out the cases itself, so a new
    /// case is classified once, here.
    public var isRetryable: Bool {
        switch self {
        case .connection, .rateLimited, .tooManyWriteOperations, .dataCorrupted:
            true
        case .notFound, .conflict, .notAuthorized, .insufficientSpace,
            .restrictedContent, .disallowedName, .malformedPath,
            .fileChangedDuringUpload, .cursorReset, .other:
            false
        }
    }
}

extension DropboxServiceError: LocalizedError {

    public var errorDescription: String? {
        switch self {
        case .notFound(let path):
            "\(path) no longer exists on Dropbox."
        case .conflict(let path):
            "Something else already occupies \(path) on Dropbox."
        case .notAuthorized:
            "Auster is no longer connected to your Dropbox account."
        case .insufficientSpace:
            "Your Dropbox is full."
        case .restrictedContent(let path):
            "Dropbox will not sync \(path)."
        case .disallowedName(let path):
            "Dropbox does not allow the name \(path)."
        case .malformedPath(let path):
            "\(path) is not a valid Dropbox path."
        case .tooManyWriteOperations:
            "Too many changes are being written to Dropbox at once."
        case .rateLimited(let retryAfter):
            "Dropbox is rate limiting Auster for another \(Int(retryAfter)) seconds."
        case .dataCorrupted(let path):
            "\(path) could not be transferred without corruption."
        case .fileChangedDuringUpload(let path):
            "\(path) changed while it was being uploaded."
        case .connection:
            "Auster cannot reach Dropbox."
        case .cursorReset:
            "Dropbox asked Auster to rebuild its index."
        case .other(let message):
            message
        }
    }
}

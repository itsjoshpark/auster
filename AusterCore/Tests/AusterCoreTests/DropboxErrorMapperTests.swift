import Foundation
import SwiftyDropbox
import Testing

@testable import AusterCore

/// The mapping from SwiftyDropbox's error unions to `DropboxServiceError`: a
/// wrong case retries something hopeless, or gives up on something transient.
/// Route errors go through `mapRoute`, whose `Box` the SDK keeps internal.
@Suite("DropboxErrorMapper")
struct DropboxErrorMapperTests {

    private let path = "/Photos/cat.jpg"

    private func mapRoute(_ error: Any) -> DropboxServiceError {
        DropboxErrorMapper.mapRoute(error, path: path)
    }

    // MARK: - Transport-level errors

    @Test("a 5xx is treated as a connection problem, so it is retried")
    func internalServerError() {
        let mapped = DropboxErrorMapper.map(
            CallError<Files.DownloadError>.internalServerError(503, "unavailable", "rq"),
            path: path
        )
        #expect(mapped == .connection)
    }

    @Test("a rate limit carries the server's retry-after")
    func rateLimit() {
        let error = Auth.RateLimitError(reason: .tooManyRequests, retryAfter: 42)
        let mapped = DropboxErrorMapper.map(
            CallError<Files.DownloadError>.rateLimitError(error, nil, nil, nil),
            path: path
        )
        #expect(mapped == .rateLimited(retryAfter: 42))
    }

    @Test("write contention is distinguished from a plain rate limit")
    func writeContentionRateLimit() {
        let error = Auth.RateLimitError(reason: .tooManyWriteOperations, retryAfter: 5)
        let mapped = DropboxErrorMapper.map(
            CallError<Files.DownloadError>.rateLimitError(error, nil, nil, nil),
            path: path
        )
        #expect(mapped == .tooManyWriteOperations)
    }

    /// Not a parameterised test: SwiftyDropbox's error enums are not `Sendable`,
    /// so they cannot be passed as `@Test` arguments.
    @Test("every auth failure forces a re-link, including one the SDK should have refreshed")
    func authErrors() {
        let errors: [Auth.AuthError] = [
            .invalidAccessToken,
            .expiredAccessToken,
            .userSuspended,
            .routeAccessDenied,
        ]
        for error in errors {
            let mapped = DropboxErrorMapper.map(
                CallError<Files.DownloadError>.authError(error, nil, nil, nil),
                path: path
            )
            #expect(mapped == .notAuthorized, "\(error)")
        }
    }

    @Test("an unauthorized HTTP status forces a re-link even without a typed auth error")
    func httpUnauthorized() {
        let mapped = DropboxErrorMapper.map(
            CallError<Files.DownloadError>.httpError(401, nil, nil),
            path: path
        )
        #expect(mapped == .notAuthorized)
    }

    @Test("HTTP 429 falls back to a conservative wait when no typed error came with it")
    func httpTooManyRequests() {
        let mapped = DropboxErrorMapper.map(
            CallError<Files.DownloadError>.httpError(429, nil, nil),
            path: path
        )
        #expect(mapped == .rateLimited(retryAfter: 60))
    }

    @Test("a 5xx status is a connection problem, a 4xx status is not")
    func httpStatusSplit() {
        let serverSide = CallError<Files.DownloadError>.httpError(502, nil, nil)
        let clientSide = CallError<Files.DownloadError>.httpError(400, "bad", nil)
        #expect(DropboxErrorMapper.map(serverSide, path: path) == .connection)
        #expect(!DropboxErrorMapper.map(clientSide, path: path).isRetryable)
    }

    @Test("a URL session failure means offline, not a permanent error")
    func urlSessionError() {
        let underlying = URLError(.notConnectedToInternet)
        let mapped = DropboxErrorMapper.map(
            CallError<Files.DownloadError>.clientError(.urlSessionError(underlying)),
            path: path
        )
        #expect(mapped == .connection)
    }

    @Test("an OAuth failure forces a re-link")
    func oauthError() {
        let mapped = DropboxErrorMapper.map(
            CallError<Files.DownloadError>.clientError(.oauthError(URLError(.userAuthenticationRequired))),
            path: path
        )
        #expect(mapped == .notAuthorized)
    }

    @Test("a reconnection failure is retried as a connection problem")
    func reconnectionError() {
        let mapped = DropboxErrorMapper.map(
            CallError<Files.DownloadError>.reconnectionError(URLError(.networkConnectionLost)),
            path: path
        )
        #expect(mapped == .connection)
    }

    @Test("a serialization failure is surfaced verbatim rather than retried")
    func serializationError() {
        let mapped = DropboxErrorMapper.map(
            CallError<Files.DownloadError>.serializationError(SerializationError.missingResultHeader),
            path: path
        )
        #expect(!mapped.isRetryable)
    }

    // MARK: - Lookup errors

    @Test("lookup failures name the path they were about")
    func lookupErrors() {
        #expect(mapRoute(Files.DownloadError.path(.notFound)) == .notFound(path: path))
        #expect(mapRoute(Files.DownloadError.path(.malformedPath("bad"))) == .malformedPath(path: path))
        #expect(mapRoute(Files.DownloadError.path(.restrictedContent)) == .restrictedContent(path: path))
        #expect(mapRoute(Files.DownloadError.path(.notFile)) == .conflict(path: path))
        #expect(mapRoute(Files.DownloadError.path(.notFolder)) == .conflict(path: path))
    }

    @Test("a locked file is reported as something to skip, not to retry")
    func lockedFile() {
        #expect(mapRoute(Files.DownloadError.path(.locked)).isRetryable == false)
        #expect(mapRoute(Files.DownloadError.path(.locked)) != .conflict(path: path))
    }

    // MARK: - Write errors

    @Test("every flavour of write conflict lands on one conflict case")
    func writeConflicts() {
        #expect(mapRoute(Files.CreateFolderError.path(.conflict(.file))) == .conflict(path: path))
        #expect(mapRoute(Files.CreateFolderError.path(.conflict(.folder))) == .conflict(path: path))
        #expect(mapRoute(Files.CreateFolderError.path(.conflict(.fileAncestor))) == .conflict(path: path))
    }

    @Test("a full account and a rejected name are told apart")
    func writeErrorVariants() {
        #expect(mapRoute(Files.CreateFolderError.path(.insufficientSpace)) == .insufficientSpace)
        #expect(mapRoute(Files.CreateFolderError.path(.disallowedName)) == .disallowedName(path: path))
        #expect(mapRoute(Files.CreateFolderError.path(.malformedPath(nil))) == .malformedPath(path: path))
        #expect(mapRoute(Files.CreateFolderError.path(.tooManyWriteOperations)) == .tooManyWriteOperations)
        #expect(mapRoute(Files.CreateFolderError.path(.noWritePermission)).isRetryable == false)
    }

    // MARK: - Upload errors

    @Test("an upload write failure is mapped through its underlying write error")
    func uploadWriteFailed() {
        let failure = Files.UploadWriteFailed(reason: .insufficientSpace, uploadSessionId: "s1")
        #expect(mapRoute(Files.UploadError.path(failure)) == .insufficientSpace)
    }

    @Test("a content hash mismatch is corruption, so it is retried")
    func uploadHashMismatch() {
        #expect(mapRoute(Files.UploadError.contentHashMismatch) == .dataCorrupted(path: path))
        #expect(mapRoute(Files.UploadSessionFinishError.contentHashMismatch) == .dataCorrupted(path: path))
        #expect(mapRoute(Files.UploadSessionAppendError.contentHashMismatch) == .dataCorrupted(path: path))
        #expect(mapRoute(Files.UploadSessionStartError.contentHashMismatch) == .dataCorrupted(path: path))
    }

    @Test("an oversized payload is a bug in our chunking, not something to retry")
    func payloadTooLarge() {
        #expect(mapRoute(Files.UploadError.payloadTooLarge).isRetryable == false)
    }

    @Test("write contention during a session finish stays retryable")
    func sessionFinishContention() {
        #expect(mapRoute(Files.UploadSessionFinishError.tooManyWriteOperations) == .tooManyWriteOperations)
        #expect(mapRoute(Files.UploadSessionFinishError.path(.conflict(.file))) == .conflict(path: path))
    }

    // MARK: - Delete errors

    @Test("delete errors resolve through their lookup or write half")
    func deleteErrors() {
        #expect(mapRoute(Files.DeleteError.pathLookup(.notFound)) == .notFound(path: path))
        #expect(mapRoute(Files.DeleteError.pathWrite(.conflict(.file))) == .conflict(path: path))
        #expect(mapRoute(Files.DeleteError.tooManyWriteOperations) == .tooManyWriteOperations)
    }

    // MARK: - Relocation errors

    @Test("move errors resolve through the half that failed")
    func relocationErrors() {
        #expect(mapRoute(Files.RelocationError.fromLookup(.notFound)) == .notFound(path: path))
        #expect(mapRoute(Files.RelocationError.to(.conflict(.file))) == .conflict(path: path))
        #expect(mapRoute(Files.RelocationError.fromWrite(.tooManyWriteOperations)) == .tooManyWriteOperations)
        #expect(mapRoute(Files.RelocationError.insufficientQuota) == .insufficientSpace)
        #expect(mapRoute(Files.RelocationError.cantMoveFolderIntoItself) == .conflict(path: path))
        #expect(mapRoute(Files.RelocationError.duplicatedOrNestedPaths) == .conflict(path: path))
        #expect(mapRoute(Files.RelocationError.internalError) == .connection)
    }

    // MARK: - Listing errors

    @Test("an invalidated cursor is reported as a reset so the engine reindexes")
    func cursorReset() {
        #expect(mapRoute(Files.ListFolderContinueError.reset) == .cursorReset)
    }

    @Test("a listing error resolves through its lookup half")
    func listFolderErrors() {
        #expect(mapRoute(Files.ListFolderError.path(.notFound)) == .notFound(path: path))
        #expect(mapRoute(Files.ListFolderContinueError.path(.notFound)) == .notFound(path: path))
        #expect(mapRoute(Files.GetMetadataError.path(.notFound)) == .notFound(path: path))
    }

    // MARK: - Fallback

    @Test("an unrecognised route error is described rather than swallowed")
    func unknownRouteError() {
        let mapped = mapRoute(Files.ListFolderError.other)
        guard case .other(let message) = mapped else {
            Issue.record("expected .other, got \(mapped)")
            return
        }
        #expect(!message.isEmpty)
    }
}

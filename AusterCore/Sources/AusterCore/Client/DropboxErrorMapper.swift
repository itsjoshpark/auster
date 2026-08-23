import Foundation
import SwiftyDropbox

/// Translates SwiftyDropbox failures into the engine's vocabulary.
///
/// The SDK reports failures as `CallError<E>`, where `E` is a different union
/// per route. The engine cannot switch on twelve unions, and more importantly
/// should not: what it needs to know is whether to wait, skip, conflict-copy or
/// re-link. That decision is made once, here (api-notes §5).
///
/// The route-specific half is deliberately `Any`-typed. `CallError` boxes its
/// route error in a type the SDK does not let us construct, so a generic switch
/// is the only shape that both `map` and its tests can reach.
enum DropboxErrorMapper {

    /// Maps a whole `CallError`. `path` names the entry the call was about, for
    /// the error cases that carry one.
    static func map<E>(_ error: CallError<E>, path: String?) -> DropboxServiceError {
        switch error {
        case .routeError(let box, _, _, _):
            return mapRoute(box.unboxed, path: path)

        case .authError:
            // Includes `expiredAccessToken`: the SDK refreshes those itself, so
            // seeing one here means refreshing failed and the link is gone.
            return .notAuthorized

        case .rateLimitError(let rateLimit, _, _, _):
            switch rateLimit.reason {
            case .tooManyWriteOperations:
                return .tooManyWriteOperations
            case .tooManyRequests, .other:
                return .rateLimited(retryAfter: TimeInterval(rateLimit.retryAfter))
            }

        case .internalServerError:
            return .connection

        case .httpError(let code, let message, _):
            switch code {
            case 401, 403:
                return .notAuthorized
            case 429:
                // No typed error came with it, so use a conservative wait rather
                // than hammering.
                return .rateLimited(retryAfter: 60)
            case .some(let status) where status >= 500:
                return .connection
            default:
                return .other(message: message ?? "HTTP \(code.map(String.init) ?? "error")")
            }

        case .clientError(let clientError):
            return map(clientError)

        case .reconnectionError:
            return .connection

        case .badInputError(let message, _):
            return .other(message: message ?? "bad input")

        case .accessError(let accessError, _, _, _):
            return .other(message: "\(accessError)")

        case .serializationError(let underlying):
            return .other(message: "\(underlying)")
        }
    }

    private static func map(_ error: ClientError) -> DropboxServiceError {
        switch error {
        case .urlSessionError:
            .connection
        case .oauthError:
            .notAuthorized
        case .requestObjectDeallocated:
            // A lifecycle slip rather than a server verdict; repeating the call
            // is the right response.
            .connection
        case .fileAccessError(let underlying):
            .other(message: "\(underlying)")
        case .unexpectedState:
            .other(message: "unexpected SDK state")
        case .other(let underlying):
            .other(message: "\(underlying)")
        }
    }

    // MARK: - Route errors

    /// Maps one route's error union. Every union bottoms out in `LookupError`,
    /// `WriteError` or a small set of route-specific cases.
    static func mapRoute(_ error: Any, path: String?) -> DropboxServiceError {
        switch error {
        case let error as Files.LookupError:
            return map(lookup: error, path: path)

        case let error as Files.WriteError:
            return map(write: error, path: path)

        case let error as Files.DownloadError:
            switch error {
            case .path(let lookup): return map(lookup: lookup, path: path)
            case .unsupportedFile: return .other(message: "file cannot be downloaded directly")
            case .other: return describe(error)
            }

        case let error as Files.UploadError:
            switch error {
            case .path(let failure): return map(write: failure.reason, path: path)
            case .contentHashMismatch: return .dataCorrupted(path: path ?? "")
            case .payloadTooLarge: return .other(message: "upload payload too large")
            case .propertiesError, .other: return describe(error)
            }

        case let error as Files.UploadSessionFinishError:
            switch error {
            case .path(let write): return map(write: write, path: path)
            case .contentHashMismatch: return .dataCorrupted(path: path ?? "")
            case .tooManyWriteOperations: return .tooManyWriteOperations
            case .payloadTooLarge: return .other(message: "upload payload too large")
            default: return describe(error)
            }

        case let error as Files.UploadSessionAppendError:
            switch error {
            case .contentHashMismatch: return .dataCorrupted(path: path ?? "")
            default: return describe(error)
            }

        case let error as Files.UploadSessionStartError:
            switch error {
            case .contentHashMismatch: return .dataCorrupted(path: path ?? "")
            default: return describe(error)
            }

        case let error as Files.DeleteError:
            switch error {
            case .pathLookup(let lookup): return map(lookup: lookup, path: path)
            case .pathWrite(let write): return map(write: write, path: path)
            case .tooManyWriteOperations: return .tooManyWriteOperations
            case .tooManyFiles, .other: return describe(error)
            }

        case let error as Files.RelocationError:
            switch error {
            case .fromLookup(let lookup): return map(lookup: lookup, path: path)
            case .fromWrite(let write), .to(let write): return map(write: write, path: path)
            case .insufficientQuota: return .insufficientSpace
            case .cantMoveFolderIntoItself, .duplicatedOrNestedPaths: return .conflict(path: path ?? "")
            case .internalError: return .connection
            default: return describe(error)
            }

        case let error as Files.CreateFolderError:
            switch error {
            case .path(let write): return map(write: write, path: path)
            }

        case let error as Files.GetMetadataError:
            switch error {
            case .path(let lookup): return map(lookup: lookup, path: path)
            }

        case let error as Files.ListFolderError:
            switch error {
            case .path(let lookup): return map(lookup: lookup, path: path)
            case .templateError, .other: return describe(error)
            }

        case let error as Files.ListFolderContinueError:
            switch error {
            case .reset: return .cursorReset
            case .path(let lookup): return map(lookup: lookup, path: path)
            case .other: return describe(error)
            }

        case let error as Files.ListFolderLongpollError:
            switch error {
            case .reset: return .cursorReset
            case .other: return describe(error)
            }

        default:
            return describe(error)
        }
    }

    private static func map(lookup error: Files.LookupError, path: String?) -> DropboxServiceError {
        switch error {
        case .notFound:
            .notFound(path: path ?? "")
        case .malformedPath:
            .malformedPath(path: path ?? "")
        case .restrictedContent:
            .restrictedContent(path: path ?? "")
        case .notFile, .notFolder:
            // Something of the wrong kind occupies the path.
            .conflict(path: path ?? "")
        case .locked:
            .other(message: "\(path ?? "the entry") is locked on Dropbox")
        case .unsupportedContentType, .other:
            describe(error)
        }
    }

    private static func map(write error: Files.WriteError, path: String?) -> DropboxServiceError {
        switch error {
        case .conflict:
            .conflict(path: path ?? "")
        case .malformedPath:
            .malformedPath(path: path ?? "")
        case .disallowedName:
            .disallowedName(path: path ?? "")
        case .insufficientSpace:
            .insufficientSpace
        case .tooManyWriteOperations:
            .tooManyWriteOperations
        case .noWritePermission, .teamFolder, .operationSuppressed, .other:
            describe(error)
        }
    }

    /// Keeps the SDK's own description rather than losing the detail; these are
    /// cases the engine can only log and skip.
    private static func describe(_ error: Any) -> DropboxServiceError {
        .other(message: "\(error)")
    }
}

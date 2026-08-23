import Foundation

/// A failure that concerns one path and nothing else (design §5).
///
/// The cycle records these and keeps going: a file Dropbox refuses to name, a
/// download that will not verify, a path the user has no permission for. They
/// land in the `sync_errors` table, show up as sync issues, and are retried on
/// the next pass over that path.
public struct SyncItemError: Error, Sendable, Equatable {

    public var dbxPath: String
    public var dbxPathLower: String
    public var direction: SyncDirection

    /// Short headline, e.g. `"Could not download file"`.
    public var title: String

    /// The user-facing explanation, usually a `DropboxServiceError`'s
    /// description.
    public var message: String

    public init(
        dbxPath: String,
        dbxPathLower: String,
        direction: SyncDirection,
        title: String,
        message: String
    ) {
        self.dbxPath = dbxPath
        self.dbxPathLower = dbxPathLower
        self.direction = direction
        self.title = title
        self.message = message
    }

    /// The database row for this failure, so a cycle can persist it as-is.
    public var entry: SyncErrorEntry {
        SyncErrorEntry(
            dbxPathLower: dbxPathLower,
            dbxPath: dbxPath,
            direction: direction,
            title: title,
            message: message
        )
    }
}

/// A failure that stops sync entirely (design §5).
///
/// Unlike `SyncItemError`, none of these can be worked around by skipping an
/// item: the engine has lost the folder, the account, or its own state, and
/// carrying on would mean guessing at the user's data.
public enum SyncFatalError: Error, Sendable, Equatable {

    /// The local Dropbox folder is gone or was renamed. Never interpreted as a
    /// mass deletion (engine-doc §9).
    case dropboxFolderMissing

    case notAuthorized

    case databaseCorrupted

    case unexpected(String)
}

extension SyncFatalError: LocalizedError {

    public var errorDescription: String? {
        switch self {
        case .dropboxFolderMissing:
            "Auster cannot find your Dropbox folder."
        case .notAuthorized:
            "Auster is no longer connected to your Dropbox account."
        case .databaseCorrupted:
            "Auster's sync database could not be read."
        case .unexpected(let message):
            message
        }
    }
}

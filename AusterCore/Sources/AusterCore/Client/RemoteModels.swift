import Foundation

// MARK: - Metadata

/// A file as Dropbox describes it. A value type independent of `SwiftyDropbox`:
/// the sync engine compares and stores these, and nothing outside
/// `LiveDropboxService` should have to know how the SDK spells them.
public struct RemoteFile: Sendable, Equatable {

    /// Stable across moves and renames (`"id:..."`); the rev is not.
    public let id: String
    public let name: String

    /// Lowercased full path, always starting with `/`. Dropbox paths are
    /// case-insensitive, so this is the join key for the index.
    public let pathLower: String

    /// Cased path for display. Only the basename is guaranteed correctly cased —
    /// parent components can be stale (api-notes §3).
    public let pathDisplay: String

    /// Opaque revision identifier; changes with every write.
    public let rev: String
    public let size: Int64

    /// Dropbox content hash (api-notes §4). Absent on some non-downloadable
    /// entries, so the engine must tolerate `nil`.
    public let contentHash: String?

    /// Modification time reported by whichever client uploaded the file.
    public let clientModified: Date

    /// When Dropbox itself stored the revision.
    public let serverModified: Date

    /// Target path when the entry is a symlink, otherwise `nil`.
    public let symlinkTarget: String?

    /// `false` for Google-Docs-style entries that must be exported, not downloaded.
    public let isDownloadable: Bool

    /// Account id of the last writer; only present inside shared folders.
    public let modifiedBy: String?

    public init(
        id: String,
        name: String,
        pathLower: String,
        pathDisplay: String,
        rev: String,
        size: Int64,
        contentHash: String?,
        clientModified: Date,
        serverModified: Date,
        symlinkTarget: String?,
        isDownloadable: Bool,
        modifiedBy: String?
    ) {
        self.id = id
        self.name = name
        self.pathLower = pathLower
        self.pathDisplay = pathDisplay
        self.rev = rev
        self.size = size
        self.contentHash = contentHash
        self.clientModified = clientModified
        self.serverModified = serverModified
        self.symlinkTarget = symlinkTarget
        self.isDownloadable = isDownloadable
        self.modifiedBy = modifiedBy
    }
}

/// A folder as Dropbox describes it. Folders carry no revision — only identity.
public struct RemoteFolder: Sendable, Equatable {
    public let id: String
    public let name: String
    public let pathLower: String
    public let pathDisplay: String

    public init(id: String, name: String, pathLower: String, pathDisplay: String) {
        self.id = id
        self.name = name
        self.pathLower = pathLower
        self.pathDisplay = pathDisplay
    }
}

/// A tombstone. Dropbox does not say whether the deleted entry was a file or a
/// folder, so the engine has to look the path up in its own index (api-notes §3).
public struct RemoteDeleted: Sendable, Equatable {
    public let name: String
    public let pathLower: String
    public let pathDisplay: String

    public init(name: String, pathLower: String, pathDisplay: String) {
        self.name = name
        self.pathLower = pathLower
        self.pathDisplay = pathDisplay
    }
}

/// One entry from a listing: the three shapes Dropbox's `Metadata` can take.
public enum RemoteMetadata: Sendable, Equatable {
    case file(RemoteFile)
    case folder(RemoteFolder)
    case deleted(RemoteDeleted)

    public var pathLower: String {
        switch self {
        case .file(let file): file.pathLower
        case .folder(let folder): folder.pathLower
        case .deleted(let deleted): deleted.pathLower
        }
    }

    public var pathDisplay: String {
        switch self {
        case .file(let file): file.pathDisplay
        case .folder(let folder): folder.pathDisplay
        case .deleted(let deleted): deleted.pathDisplay
        }
    }

    public var name: String {
        switch self {
        case .file(let file): file.name
        case .folder(let folder): folder.name
        case .deleted(let deleted): deleted.name
        }
    }

    public var isDeleted: Bool {
        if case .deleted = self { return true }
        return false
    }

    /// The file payload, or `nil` for folders and tombstones.
    public var asFile: RemoteFile? {
        if case .file(let file) = self { return file }
        return nil
    }

    /// The folder payload, or `nil` for files and tombstones.
    public var asFolder: RemoteFolder? {
        if case .folder(let folder) = self { return folder }
        return nil
    }
}

// MARK: - Listing

/// One page of `list_folder` / `list_folder/continue`. The cursor is per page,
/// not per listing: it is persisted after each page's entries are applied, so an
/// interrupted index resumes rather than restarts (decisions D9.4).
public struct ListPage: Sendable {
    public let entries: [RemoteMetadata]
    public let cursor: String
    public let hasMore: Bool

    public init(entries: [RemoteMetadata], cursor: String, hasMore: Bool) {
        self.entries = entries
        self.cursor = cursor
        self.hasMore = hasMore
    }
}

// MARK: - Uploads

/// How an upload should behave when something already exists at the path.
public enum WriteMode: Sendable, Equatable {

    /// Never overwrite; the server autorenames on collision.
    case add

    /// Replace whatever is there. Used only when we know we are authoritative.
    case overwrite

    /// Replace only if the server is still at `rev`; otherwise the server writes
    /// a conflicted copy. The default for modified files — this is what makes a
    /// lost update impossible (decisions D9.1).
    case update(rev: String)
}

// MARK: - Account

/// The linked account, as shown in the menu bar and Settings.
public struct AccountInfo: Sendable, Equatable {
    public let accountId: String
    public let displayName: String
    public let email: String

    /// `"basic"`, `"pro"` or `"business"`.
    public let accountType: String

    /// `true` when the account belongs to a Dropbox team. Auster rejects these
    /// at link time and never migrates path roots (decisions D4).
    public let isTeam: Bool

    public let profilePhotoURL: URL?

    public init(
        accountId: String,
        displayName: String,
        email: String,
        accountType: String,
        isTeam: Bool,
        profilePhotoURL: URL?
    ) {
        self.accountId = accountId
        self.displayName = displayName
        self.email = email
        self.accountType = accountType
        self.isTeam = isTeam
        self.profilePhotoURL = profilePhotoURL
    }
}

/// Bytes used against bytes allocated, for the Settings usage readout.
public struct SpaceUsage: Sendable, Equatable {
    public let used: Int64
    public let allocated: Int64

    public init(used: Int64, allocated: Int64) {
        self.used = used
        self.allocated = allocated
    }

    /// Remaining allowance, floored at zero — Dropbox can report a usage above
    /// the allocation, and an unlimited allocation comes back as zero.
    public var available: Int64 {
        max(0, allocated - used)
    }

    /// Fraction of the allocation in use, in `0...1`. Zero when the allocation
    /// is unknown, so a progress bar reads empty rather than dividing by zero.
    public var fraction: Double {
        guard allocated > 0 else { return 0 }
        return min(1, Double(used) / Double(allocated))
    }
}

import Foundation
import GRDB

// MARK: - Public model

/// One row of the sync index: an item both sides agreed on at the last sync
/// (engine-doc §1.1). The key is the lowercased Dropbox path, because Dropbox is
/// case-insensitive and two spellings must never become two rows.
public struct IndexEntry: Sendable, Equatable, Codable {

    /// Primary key. Lowercased and NFC-normalized by `PathStore.normalize`.
    public var dbxPathLower: String

    /// The correctly cased path, from which the local path is derived.
    public var dbxPathCased: String

    /// Dropbox's stable id (`"id:..."`), which survives moves.
    public var dbxId: String

    public var itemType: ItemType

    /// When this item was last synced. Compared against the local ctime to spot
    /// unsynced local changes (engine-doc §4.5); `nil` means "never".
    public var lastSync: Date?

    /// Dropbox revision, or the literal `"folder"` for folders.
    public var rev: String

    /// Dropbox content hash, or `"folder"` for folders. `nil` when not yet
    /// computed — the engine must tolerate that rather than assume a mismatch.
    public var contentHash: String?

    /// Target path when the item is a symlink, otherwise `nil`.
    public var symlinkTarget: String?

    public init(
        dbxPathLower: String,
        dbxPathCased: String,
        dbxId: String,
        itemType: ItemType,
        lastSync: Date?,
        rev: String,
        contentHash: String?,
        symlinkTarget: String?
    ) {
        self.dbxPathLower = dbxPathLower
        self.dbxPathCased = dbxPathCased
        self.dbxId = dbxId
        self.itemType = itemType
        self.lastSync = lastSync
        self.rev = rev
        self.contentHash = contentHash
        self.symlinkTarget = symlinkTarget
    }
}

public enum ItemType: String, Sendable, Codable {
    case file
    case folder

    /// The value `rev` and `contentHash` carry for folders, which have neither.
    public static let folderSentinel = "folder"
}

/// Which way a sync operation was going.
public enum SyncDirection: String, Sendable, Codable {
    case up
    case down
}

/// A path that failed to sync, surfaced in the UI as a "sync issue"
/// (engine-doc §1.3). Keyed by path, so a retry of the same path replaces it.
public struct SyncErrorEntry: Sendable, Equatable, Codable {
    public var dbxPathLower: String
    public var dbxPath: String
    public var direction: SyncDirection

    /// Short headline, e.g. "Could not upload file".
    public var title: String

    /// The user-facing explanation, typically a `DropboxServiceError`'s
    /// description.
    public var message: String

    public init(
        dbxPathLower: String,
        dbxPath: String,
        direction: SyncDirection,
        title: String,
        message: String
    ) {
        self.dbxPathLower = dbxPathLower
        self.dbxPath = dbxPath
        self.direction = direction
        self.title = title
        self.message = message
    }
}

/// A completed sync event, for the "Recent Changes" menu (engine-doc §1.4).
public struct HistoryEntry: Sendable, Equatable, Codable {

    /// Assigned by the database on insert; `nil` before that.
    public var id: Int64?

    public var direction: SyncDirection
    public var changeType: ChangeType
    public var itemType: ItemType
    public var dbxPath: String
    public var size: Int64
    public var timestamp: Date

    public init(
        id: Int64? = nil,
        direction: SyncDirection,
        changeType: ChangeType,
        itemType: ItemType,
        dbxPath: String,
        size: Int64,
        timestamp: Date
    ) {
        self.id = id
        self.direction = direction
        self.changeType = changeType
        self.itemType = itemType
        self.dbxPath = dbxPath
        self.size = size
        self.timestamp = timestamp
    }
}

public enum ChangeType: String, Sendable, Codable {
    case added
    case removed
    case moved
    case modified
}

/// Keys of the small key/value state table: cursors and flags that let an
/// interrupted index resume instead of restarting (engine-doc §1.5).
public enum StateKey: String {

    /// Dropbox `list_folder` cursor. Absent or empty means "never indexed".
    case remoteCursor

    /// Unix timestamp of the last completed upload cycle, used by the offline
    /// catch-up scan.
    case localCursorTimestamp

    /// Whether the first-run index ran to completion.
    case didFinishIndexing

    /// How many items the in-progress index has applied so far.
    case indexingCounter

    /// Selective-sync exclusions, as a JSON array of lowercased paths. The
    /// database is the source of truth; `AppConfig` mirrors it for the UI.
    case excludedItems
}

// MARK: - Storage records

// The public models above stay free of GRDB: these internal records own the
// column names and the on-disk representation. Dates are Unix timestamps, so
// sub-second precision survives comparison against `stat`.

struct IndexRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "index_entry"

    var dbxPathLower: String
    var dbxPathCased: String
    var dbxId: String
    var itemType: String
    var lastSync: Double?
    var rev: String
    var contentHash: String?
    var symlinkTarget: String?

    enum CodingKeys: String, CodingKey {
        case dbxPathLower = "dbx_path_lower"
        case dbxPathCased = "dbx_path_cased"
        case dbxId = "dbx_id"
        case itemType = "item_type"
        case lastSync = "last_sync"
        case rev
        case contentHash = "content_hash"
        case symlinkTarget = "symlink_target"
    }

    init(_ entry: IndexEntry) {
        dbxPathLower = entry.dbxPathLower
        dbxPathCased = entry.dbxPathCased
        dbxId = entry.dbxId
        itemType = entry.itemType.rawValue
        lastSync = entry.lastSync?.timeIntervalSince1970
        rev = entry.rev
        contentHash = entry.contentHash
        symlinkTarget = entry.symlinkTarget
    }

    /// `nil` when the stored `item_type` is not one we know — a row written by a
    /// newer schema, which is better skipped than crashed on.
    var entry: IndexEntry? {
        guard let type = ItemType(rawValue: itemType) else { return nil }
        return IndexEntry(
            dbxPathLower: dbxPathLower,
            dbxPathCased: dbxPathCased,
            dbxId: dbxId,
            itemType: type,
            lastSync: lastSync.map { Date(timeIntervalSince1970: $0) },
            rev: rev,
            contentHash: contentHash,
            symlinkTarget: symlinkTarget
        )
    }
}

struct HashCacheRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "hash_cache"

    /// Stored as a signed integer because that is all SQLite has; the bit
    /// pattern is preserved, so large inode numbers survive the round trip.
    var inode: Int64
    var localPath: String
    var hashStr: String?
    var mtime: Double

    enum CodingKeys: String, CodingKey {
        case inode
        case localPath = "local_path"
        case hashStr = "hash_str"
        case mtime
    }
}

struct SyncErrorRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "sync_error"

    var dbxPathLower: String
    var dbxPath: String
    var direction: String
    var title: String
    var message: String

    enum CodingKeys: String, CodingKey {
        case dbxPathLower = "dbx_path_lower"
        case dbxPath = "dbx_path"
        case direction
        case title
        case message
    }

    init(_ entry: SyncErrorEntry) {
        dbxPathLower = entry.dbxPathLower
        dbxPath = entry.dbxPath
        direction = entry.direction.rawValue
        title = entry.title
        message = entry.message
    }

    var entry: SyncErrorEntry? {
        guard let direction = SyncDirection(rawValue: direction) else { return nil }
        return SyncErrorEntry(
            dbxPathLower: dbxPathLower,
            dbxPath: dbxPath,
            direction: direction,
            title: title,
            message: message
        )
    }
}

struct HistoryRecord: Codable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "history"

    var id: Int64?
    var direction: String
    var changeType: String
    var itemType: String
    var dbxPath: String
    var size: Int64
    var timestamp: Double

    enum CodingKeys: String, CodingKey {
        case id
        case direction
        case changeType = "change_type"
        case itemType = "item_type"
        case dbxPath = "dbx_path"
        case size
        case timestamp
    }

    init(_ entry: HistoryEntry) {
        id = entry.id
        direction = entry.direction.rawValue
        changeType = entry.changeType.rawValue
        itemType = entry.itemType.rawValue
        dbxPath = entry.dbxPath
        size = entry.size
        timestamp = entry.timestamp.timeIntervalSince1970
    }

    var entry: HistoryEntry? {
        guard let direction = SyncDirection(rawValue: direction),
            let changeType = ChangeType(rawValue: changeType),
            let itemType = ItemType(rawValue: itemType)
        else { return nil }
        return HistoryEntry(
            id: id,
            direction: direction,
            changeType: changeType,
            itemType: itemType,
            dbxPath: dbxPath,
            size: size,
            timestamp: Date(timeIntervalSince1970: timestamp)
        )
    }
}

struct StateRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "state"

    var key: String
    var value: String?
}

struct PendingDownloadRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "pending_download"

    var dbxPathLower: String

    enum CodingKeys: String, CodingKey {
        case dbxPathLower = "dbx_path_lower"
    }
}

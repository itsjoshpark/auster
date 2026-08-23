import Foundation

/// One change to apply, in the single shape both directions of the engine work
/// in (engine-doc §1.4).
///
/// Remote and local changes arrive in very different forms — Dropbox metadata on
/// one side, FSEvents on the other — and the conflict table, the ordering rules
/// and the activity display all want to reason about them identically. This is
/// that common shape: everything the engine needs to decide what to do, resolved
/// once at the boundary so nothing downstream has to consult the index again.
public struct SyncItemEvent: Sendable, Equatable {

    public var direction: SyncDirection

    /// Remote events are never `.moved`: Dropbox reports a move as a tombstone
    /// at the old path plus a fresh entry at the new one (api-notes §3).
    public var changeType: ChangeType

    /// `nil` only for a remote deletion of a path the index has never seen —
    /// Dropbox tombstones do not say what they buried.
    public var itemType: ItemType?

    /// The correctly cased Dropbox path; for a move, the destination.
    public var dbxPath: String

    /// The index key: `dbxPath` normalized.
    public var dbxPathLower: String

    public var localURL: URL

    public var dbxPathFrom: String?
    public var dbxPathFromLower: String?
    public var localURLFrom: URL?

    /// The revision to apply, `ItemType.folderSentinel` for a folder, or `nil`
    /// for a deletion.
    public var rev: String?

    /// Dropbox's content hash, or `ItemType.folderSentinel` for a folder.
    public var contentHash: String?

    public var symlinkTarget: String?
    public var dbxId: String?
    public var size: Int64

    /// When the change happened on the far side, for the history log.
    public var changeTime: Date?

    /// Account id of whoever made the change; only Dropbox reports this, and
    /// only inside shared folders.
    public var changedBy: String?

    public init(
        direction: SyncDirection,
        changeType: ChangeType,
        itemType: ItemType?,
        dbxPath: String,
        dbxPathLower: String,
        localURL: URL,
        dbxPathFrom: String? = nil,
        dbxPathFromLower: String? = nil,
        localURLFrom: URL? = nil,
        rev: String? = nil,
        contentHash: String? = nil,
        symlinkTarget: String? = nil,
        dbxId: String? = nil,
        size: Int64 = 0,
        changeTime: Date? = nil,
        changedBy: String? = nil
    ) {
        self.direction = direction
        self.changeType = changeType
        self.itemType = itemType
        self.dbxPath = dbxPath
        self.dbxPathLower = dbxPathLower
        self.localURL = localURL
        self.dbxPathFrom = dbxPathFrom
        self.dbxPathFromLower = dbxPathFromLower
        self.localURLFrom = localURLFrom
        self.rev = rev
        self.contentHash = contentHash
        self.symlinkTarget = symlinkTarget
        self.dbxId = dbxId
        self.size = size
        self.changeTime = changeTime
        self.changedBy = changedBy
    }
}

extension SyncItemEvent {

    /// Builds a download event from one entry of a Dropbox listing.
    ///
    /// Two lookups make this async rather than a plain initializer: the index
    /// decides whether this is an addition or a modification (and, for a
    /// tombstone, what type of thing was deleted), and `correctCase` fills in
    /// the ancestor casing that `path_display` does not guarantee (api-notes §3).
    ///
    /// The *basename* always comes from the event, never from the index: a
    /// remote rename that only changes case would otherwise be erased before
    /// §4.6's case-change step could see it.
    public init(
        remote: RemoteMetadata,
        index: SyncDatabase,
        pathStore: PathStore
    ) async throws {
        let pathLower = PathStore.normalize(remote.pathLower)
        let indexEntry = try index.indexEntry(forPathLower: pathLower)
        let cased = try await pathStore.correctCase(remote.pathDisplay)

        switch remote {
        case .file(let file):
            self.init(
                direction: .down,
                changeType: indexEntry == nil ? .added : .modified,
                itemType: .file,
                dbxPath: cased,
                dbxPathLower: pathLower,
                localURL: pathStore.toLocalURL(dbxPathCased: cased),
                rev: file.rev,
                contentHash: file.contentHash,
                symlinkTarget: file.symlinkTarget,
                dbxId: file.id,
                size: file.size,
                changeTime: file.serverModified,
                changedBy: file.modifiedBy
            )

        case .folder(let folder):
            self.init(
                direction: .down,
                changeType: indexEntry == nil ? .added : .modified,
                itemType: .folder,
                dbxPath: cased,
                dbxPathLower: pathLower,
                localURL: pathStore.toLocalURL(dbxPathCased: cased),
                rev: ItemType.folderSentinel,
                contentHash: ItemType.folderSentinel,
                dbxId: folder.id
            )

        case .deleted:
            self.init(
                direction: .down,
                changeType: .removed,
                itemType: indexEntry?.itemType,
                dbxPath: cased,
                dbxPathLower: pathLower,
                localURL: pathStore.toLocalURL(dbxPathCased: cased),
                dbxId: indexEntry?.dbxId
            )
        }
    }

    /// Builds an upload event from a cleaned filesystem event.
    ///
    /// Everything the far side will need is resolved here, while the file is
    /// still in front of us: its hash, its size, whether it is a symlink, and
    /// what the index last knew about it. The handlers then work from the event
    /// alone, which is what lets a whole batch be hashed in parallel before any
    /// of it is uploaded.
    ///
    /// Unlike the download direction there is nothing to await: local paths need
    /// no case correction, because the disk *is* the authority on how they are
    /// spelled.
    public init(
        local event: RawFSEvent,
        index: SyncDatabase,
        pathStore: PathStore,
        hasher: CachedContentHasher
    ) throws {
        let source = try pathStore.toDbxPath(localURL: event.url)
        let sourceLower = PathStore.normalize(source)

        var destination = source
        var destinationURL = event.url
        if case .moved(let movedTo) = event.kind {
            destination = try pathStore.toDbxPath(localURL: movedTo)
            destinationURL = movedTo
        }
        let destinationLower = PathStore.normalize(destination)

        // A move is a fact about the item at the *source*, which is where the
        // index knows it by.
        let indexEntry = try index.indexEntry(forPathLower: sourceLower)
        let attributes = try? FileManager.default.attributesOfItem(atPath: destinationURL.path)

        let itemType: ItemType
        switch event.kind {
        case .deleted:
            // The item is gone, so the index is a better witness to what it was
            // than an FSEvents flag about something that no longer exists.
            itemType = indexEntry?.itemType ?? (event.isDirectory ? .folder : .file)
        default:
            itemType = event.isDirectory ? .folder : .file
        }

        let changeType: ChangeType
        switch event.kind {
        case .created: changeType = .added
        case .deleted: changeType = .removed
        case .modified: changeType = .modified
        case .moved: changeType = .moved
        }

        let isMove = destinationLower != sourceLower || destination != source
        self.init(
            direction: .up,
            changeType: changeType,
            itemType: itemType,
            dbxPath: destination,
            dbxPathLower: destinationLower,
            localURL: destinationURL,
            dbxPathFrom: isMove ? source : nil,
            dbxPathFromLower: isMove ? sourceLower : nil,
            localURLFrom: isMove ? event.url : nil,
            rev: indexEntry?.rev,
            contentHash: event.kind == .deleted ? nil : try hasher.localHash(at: destinationURL),
            symlinkTarget: try? FileManager.default.destinationOfSymbolicLink(atPath: destinationURL.path),
            dbxId: indexEntry?.dbxId,
            size: (attributes?[.size] as? NSNumber)?.int64Value ?? 0,
            changeTime: attributes?[.modificationDate] as? Date
        )
    }
}

import Foundation

/// `ContentHasher` with the hash cache in front of it (engine-doc §1.2).
///
/// Every sync cycle asks whether each local file still matches its index entry,
/// and answering that by reading every byte of every file would make a scan cost
/// the size of the folder rather than the size of the change. The cache is keyed
/// by inode — so a rename keeps its hash — and invalidated by mtime, which is
/// what actually changes when the bytes do.
public struct CachedContentHasher: Sendable {

    private let database: SyncDatabase

    public init(database: SyncDatabase) {
        self.database = database
    }

    /// The content hash of whatever is at `localURL`.
    ///
    /// Returns `ItemType.folderSentinel` for a directory and `nil` when nothing
    /// is there — including a symlink pointing at nothing, since the engine's
    /// question is about content, and a broken link has none.
    ///
    /// Symlinks are followed: a link's content is its target's content, and the
    /// fact that it *is* a link is recorded separately, in the index entry's
    /// `symlinkTarget`.
    public func localHash(at localURL: URL) throws -> String? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: localURL.path),
            let type = attributes[.type] as? FileAttributeType
        else {
            return nil
        }

        // `attributesOfItem` does not follow symlinks, so a link is resolved and
        // re-asked rather than hashed as its own (link-sized) content.
        if type == .typeSymbolicLink {
            let resolved = localURL.resolvingSymlinksInPath()
            guard resolved.path != localURL.path else { return nil }
            return try localHash(at: resolved)
        }

        if type == .typeDirectory { return ItemType.folderSentinel }
        guard type == .typeRegular else { return nil }

        guard let inode = attributes[.systemFileNumber] as? UInt64,
            let mtime = attributes[.modificationDate] as? Date
        else {
            // No identity to cache against; hashing still has to work.
            return try ContentHasher.hash(fileAt: localURL)
        }

        if let cached = try database.cachedHash(inode: inode, mtime: mtime) { return cached }

        let hash = try ContentHasher.hash(fileAt: localURL)
        // The mtime is re-read after hashing: if the file was written while it
        // was being read, caching the hash under the *old* mtime would pin a
        // hash of torn bytes to a file that has since moved on.
        let mtimeAfterHashing =
            (try? FileManager.default.attributesOfItem(atPath: localURL.path))?[
                .modificationDate] as? Date
        guard mtimeAfterHashing == mtime else { return hash }

        try database.storeHash(inode: inode, localPath: localURL.path, hash: hash, mtime: mtime)
        return hash
    }
}

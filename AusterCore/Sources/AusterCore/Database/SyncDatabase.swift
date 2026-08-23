import Foundation
import GRDB

/// The sync engine's persistent state: the index, the hash cache, sync errors,
/// history, and a small key/value store for cursors and flags (engine-doc §1).
///
/// Everything here is *reconstructible*. That is the premise the whole class
/// leans on: if SQLite cannot open or migrate the file, the right move is to
/// throw the file away and re-index rather than to fail the launch
/// (engine-doc §9), so `init` never surfaces a corruption error — it reports it
/// through `wasResetOnOpen` instead.
///
/// A `DatabasePool` (WAL) backs it, so the download and upload workers can read
/// concurrently while one writes.
public final class SyncDatabase: Sendable {

    private let pool: DatabasePool

    /// `true` when the file on disk was unusable and had to be recreated empty.
    /// The caller must then treat the index as absent and reindex.
    ///
    /// Deviation from the phase file, which spells this `private(set) var`: a
    /// `Sendable` class cannot hold mutable state without isolation, and this is
    /// only ever set during `init`.
    public let wasResetOnOpen: Bool

    /// Opens (or creates) the database at `path`, migrating it to the current
    /// schema.
    ///
    /// - Throws: only if a *fresh* database also cannot be created — at which
    ///   point the problem is the filesystem, not the data.
    public init(path: String) throws {
        var configuration = Configuration()
        // Under contention SQLite would otherwise fail the write immediately;
        // the workers are short-lived writers, so waiting is always better than
        // dropping a change.
        configuration.busyMode = .timeout(5)

        do {
            pool = try Self.open(path: path, configuration: configuration)
            wasResetOnOpen = false
        } catch {
            try Self.removeDatabaseFiles(at: path)
            pool = try Self.open(path: path, configuration: configuration)
            wasResetOnOpen = true
        }
    }

    private static func open(path: String, configuration: Configuration) throws -> DatabasePool {
        let pool = try DatabasePool(path: path, configuration: configuration)
        try migrator.migrate(pool)
        // A corrupt file can survive `open` and even a no-op migration, so force
        // one real read of a table we just guaranteed exists.
        _ = try pool.read { try IndexRecord.fetchCount($0) }
        return pool
    }

    /// SQLite spreads a WAL database over three files; leaving the siblings
    /// behind would resurrect the corruption we are recovering from.
    private static func removeDatabaseFiles(at path: String) throws {
        for suffix in ["", "-wal", "-shm"] {
            let url = URL(fileURLWithPath: path + suffix)
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
        }
    }

    // MARK: - Schema

    private static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1") { db in
            try db.create(table: IndexRecord.databaseTableName) { t in
                t.primaryKey("dbx_path_lower", .text)
                t.column("dbx_path_cased", .text).notNull()
                t.column("dbx_id", .text).notNull()
                t.column("item_type", .text).notNull()
                t.column("last_sync", .double)
                t.column("rev", .text).notNull()
                t.column("content_hash", .text)
                t.column("symlink_target", .text)
            }

            try db.create(table: HashCacheRecord.databaseTableName) { t in
                t.primaryKey("inode", .integer)
                t.column("local_path", .text).notNull()
                t.column("hash_str", .text)
                t.column("mtime", .double).notNull()
            }

            try db.create(table: SyncErrorRecord.databaseTableName) { t in
                t.primaryKey("dbx_path_lower", .text)
                t.column("dbx_path", .text).notNull()
                t.column("direction", .text).notNull()
                t.column("title", .text).notNull()
                t.column("message", .text).notNull()
            }

            try db.create(table: HistoryRecord.databaseTableName) { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("direction", .text).notNull()
                t.column("change_type", .text).notNull()
                t.column("item_type", .text).notNull()
                t.column("dbx_path", .text).notNull()
                t.column("size", .integer).notNull()
                t.column("timestamp", .double).notNull()
            }
            // Every history read is "most recent first", and pruning is a range
            // scan over the same column.
            try db.create(
                index: "history_on_timestamp",
                on: HistoryRecord.databaseTableName,
                columns: ["timestamp"]
            )

            try db.create(table: StateRecord.databaseTableName) { t in
                t.primaryKey("key", .text)
                t.column("value", .text)
            }

            try db.create(table: PendingDownloadRecord.databaseTableName) { t in
                t.primaryKey("dbx_path_lower", .text)
            }
        }

        return migrator
    }

    // MARK: - Index

    public func indexEntry(forPathLower pathLower: String) throws -> IndexEntry? {
        try pool.read { db in
            try IndexRecord.fetchOne(db, key: pathLower)?.entry
        }
    }

    /// Every entry at or beneath `pathLower`, inclusive.
    ///
    /// "Beneath" means a path-component boundary: `/a` covers `/a/b` but never
    /// `/ab`. Passing the root (`""` or `"/"`) returns everything.
    public func indexEntries(underPathLower pathLower: String) throws -> [IndexEntry] {
        try pool.read { db in
            guard let (sql, arguments) = Self.subtreeCondition(pathLower) else {
                return try IndexRecord.fetchAll(db).compactMap(\.entry)
            }
            return try IndexRecord.filter(sql: sql, arguments: arguments)
                .fetchAll(db)
                .compactMap(\.entry)
        }
    }

    public func allIndexEntries() throws -> [IndexEntry] {
        try pool.read { db in
            try IndexRecord.fetchAll(db).compactMap(\.entry)
        }
    }

    public func upsertIndexEntry(_ entry: IndexEntry) throws {
        try pool.write { db in
            try IndexRecord(entry).save(db)
        }
    }

    public func removeIndexSubtree(pathLower: String) throws {
        try pool.write { db in
            guard let (sql, arguments) = Self.subtreeCondition(pathLower) else {
                _ = try IndexRecord.deleteAll(db)
                return
            }
            _ = try IndexRecord.filter(sql: sql, arguments: arguments).deleteAll(db)
        }
    }

    public func indexCount() throws -> Int {
        try pool.read { db in
            try IndexRecord.fetchCount(db)
        }
    }

    /// The `WHERE` fragment selecting a subtree, or `nil` for the root (which
    /// needs no filter at all).
    ///
    /// Paths are user data and routinely contain `%` and `_`, so the descendant
    /// half escapes them: without that, `/100%` would also match `/100x/…`.
    private static func subtreeCondition(_ pathLower: String) -> (String, StatementArguments)? {
        guard pathLower != "", pathLower != "/" else { return nil }
        let prefix = pathLower.hasSuffix("/") ? String(pathLower.dropLast()) : pathLower
        let pattern = escapedForLike(prefix) + "/%"
        return (
            "dbx_path_lower = ? OR dbx_path_lower LIKE ? ESCAPE '\\'",
            [prefix, pattern]
        )
    }

    private static func escapedForLike(_ string: String) -> String {
        string
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }

    // MARK: - Hash cache

    /// The cached content hash for a file, or `nil` when there is none *or* the
    /// file has been written since it was cached (engine-doc §1.2).
    ///
    /// The inode is the key rather than the path so a rename does not throw away
    /// a perfectly good hash; the mtime is what makes the entry stale.
    public func cachedHash(inode: UInt64, mtime: Date) throws -> String? {
        try pool.read { db in
            guard let record = try HashCacheRecord.fetchOne(db, key: Self.column(inode)) else {
                return nil
            }
            guard record.mtime == mtime.timeIntervalSince1970 else { return nil }
            return record.hashStr
        }
    }

    /// Records a file's hash. A `nil` hash forgets the inode instead of caching
    /// an absence — an unknown hash and "we know it has none" would otherwise be
    /// indistinguishable on read.
    public func storeHash(inode: UInt64, localPath: String, hash: String?, mtime: Date) throws {
        try pool.write { db in
            guard let hash else {
                _ = try HashCacheRecord.deleteOne(db, key: Self.column(inode))
                return
            }
            try HashCacheRecord(
                inode: Self.column(inode),
                localPath: localPath,
                hashStr: hash,
                mtime: mtime.timeIntervalSince1970
            ).save(db)
        }
    }

    /// SQLite integers are signed, so inodes above `Int64.max` are stored by bit
    /// pattern and read back the same way.
    private static func column(_ inode: UInt64) -> Int64 {
        Int64(bitPattern: inode)
    }

    // MARK: - Sync errors

    /// Records (or replaces) the failure for a path. Keyed by path, because the
    /// UI shows one issue per item, not one per attempt.
    public func upsertSyncError(_ entry: SyncErrorEntry) throws {
        try pool.write { db in
            try SyncErrorRecord(entry).save(db)
        }
    }

    /// Clears the error for a path and everything under it.
    ///
    /// Subtree semantics matter here: re-syncing a folder should clear the
    /// issues of the children it is about to retry, not just its own.
    public func clearSyncErrors(pathLower: String) throws {
        try pool.write { db in
            guard let (sql, arguments) = Self.subtreeCondition(pathLower) else {
                _ = try SyncErrorRecord.deleteAll(db)
                return
            }
            _ = try SyncErrorRecord.filter(sql: sql, arguments: arguments).deleteAll(db)
        }
    }

    /// Clears every error for one direction, as a sync cycle does before it
    /// retries the paths it is responsible for.
    public func clearSyncErrors(direction: SyncDirection) throws {
        try pool.write { db in
            _ = try SyncErrorRecord.filter(sql: "direction = ?", arguments: [direction.rawValue])
                .deleteAll(db)
        }
    }

    public func syncErrors() throws -> [SyncErrorEntry] {
        try pool.read { db in
            try SyncErrorRecord.fetchAll(db).compactMap(\.entry)
        }
    }

    // MARK: - History

    /// Appends a completed sync event. Unlike every other table here this is a
    /// log: the same path recurs, and the row's identity is its id.
    public func appendHistory(_ entry: HistoryEntry) throws {
        try pool.write { db in
            var record = HistoryRecord(entry)
            try record.insert(db)
        }
    }

    /// The most recent events, newest first.
    public func recentHistory(limit: Int) throws -> [HistoryEntry] {
        try pool.read { db in
            try HistoryRecord
                .order(sql: "timestamp DESC, id DESC")
                .limit(limit)
                .fetchAll(db)
                .compactMap(\.entry)
        }
    }

    /// Trims the log to a retention window and a hard ceiling (engine-doc §1.4:
    /// one week, at most 1000 entries).
    ///
    /// Both bounds are applied — a quiet week must not leave one stale entry
    /// visible, and a busy hour must not leave ten thousand.
    public func pruneHistory(olderThan cutoff: Date, keepAtMost limit: Int) throws {
        try pool.write { db in
            _ = try HistoryRecord.filter(
                sql: "timestamp < ?",
                arguments: [cutoff.timeIntervalSince1970]
            ).deleteAll(db)

            try db.execute(
                sql: """
                    DELETE FROM \(HistoryRecord.databaseTableName)
                    WHERE id NOT IN (
                        SELECT id FROM \(HistoryRecord.databaseTableName)
                        ORDER BY timestamp DESC, id DESC LIMIT ?
                    )
                    """,
                arguments: [limit]
            )
        }
    }

    // MARK: - State

    public func stateString(_ key: StateKey) throws -> String? {
        try pool.read { db in
            try StateRecord.fetchOne(db, key: key.rawValue)?.value
        }
    }

    /// Sets a state value, or removes the key when `value` is `nil`.
    ///
    /// Removing rather than storing an empty string keeps "never set" distinct
    /// from "set to nothing" — the difference between "never indexed" and an
    /// empty cursor is the difference between a full re-index and a no-op.
    public func setState(_ key: StateKey, _ value: String?) throws {
        try pool.write { db in
            guard let value else {
                _ = try StateRecord.deleteOne(db, key: key.rawValue)
                return
            }
            try StateRecord(key: key.rawValue, value: value).save(db)
        }
    }

    // MARK: - Pending downloads

    /// Paths newly included by selective sync that still need fetching
    /// (engine-doc §1.5). Persisted, so a restart mid-download resumes rather
    /// than silently leaving a folder empty.
    public func pendingDownloads() throws -> [String] {
        try pool.read { db in
            try PendingDownloadRecord
                .order(sql: "dbx_path_lower")
                .fetchAll(db)
                .map(\.dbxPathLower)
        }
    }

    public func addPendingDownload(_ pathLower: String) throws {
        try pool.write { db in
            try PendingDownloadRecord(dbxPathLower: pathLower).save(db)
        }
    }

    public func removePendingDownload(_ pathLower: String) throws {
        try pool.write { db in
            _ = try PendingDownloadRecord.deleteOne(db, key: pathLower)
        }
    }
}

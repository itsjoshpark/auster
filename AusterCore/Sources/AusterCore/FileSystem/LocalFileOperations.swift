import Foundation

/// A local change the engine is about to make, declared before it makes it
/// (engine-doc §5.2).
///
/// FSEvents cannot tell the engine's own writes apart from the user's, so every
/// mutation announces itself first and the filter drops the echo. Without this,
/// each download would immediately queue itself for upload.
public struct ExpectedFSEvent: Sendable, Equatable {

    public enum Kind: Sendable, Equatable {
        case created
        case deleted
        case modified
        case moved(to: URL)
    }

    public let kind: Kind
    public let url: URL
    public let isDirectory: Bool

    /// Whether events for descendants of `url` should be dropped too. Set for
    /// directory deletes and moves, which arrive as a shower of child events.
    public let recursive: Bool

    public init(kind: Kind, url: URL, isDirectory: Bool, recursive: Bool) {
        self.kind = kind
        self.url = url
        self.isDirectory = isDirectory
        self.recursive = recursive
    }
}

/// The seam between local mutations and the FS-event filter that has to ignore
/// them. Phase 5 supplies the real implementation; until then `NoFileEventIgnoring`
/// stands in.
public protocol FileEventIgnoring: Sendable {

    /// Registers `expected`, runs `body`, and keeps the registrations alive long
    /// enough afterwards for late deliveries to be matched.
    func ignoring<T>(_ expected: [ExpectedFSEvent], _ body: () throws -> T) rethrows -> T
}

/// The stand-in used before there is an FS watcher to talk to — and in tests
/// that do not care about echoes.
public struct NoFileEventIgnoring: FileEventIgnoring {

    public init() {}

    public func ignoring<T>(_ expected: [ExpectedFSEvent], _ body: () throws -> T) rethrows -> T {
        try body()
    }
}

/// Every local mutation the engine performs (engine-doc §4.6–§4.8).
///
/// Three things make this more than a `FileManager` wrapper, and all three are
/// safety properties from decisions D9:
///
/// - Downloads are staged inside the Dropbox folder and moved into place with
///   `rename(2)`, so a partial file is never visible at the real path.
/// - Deletes can require the on-disk name to match the requested casing, so a
///   remote delete of `A.txt` cannot remove the user's `a.txt` on a
///   case-insensitive volume.
/// - Every mutation is wrapped in an ignore declaration, so it does not echo
///   back as a local change.
public struct LocalFileOperations: Sendable {

    /// The local Dropbox folder.
    public let root: URL

    private let ignore: FileEventIgnoring

    public init(root: URL, ignore: FileEventIgnoring = NoFileEventIgnoring()) {
        self.root = root.standardizedFileURL
        self.ignore = ignore
    }

    // MARK: - Staging

    /// Where downloads are staged.
    ///
    /// Inside the Dropbox folder on purpose: `rename(2)` is only atomic within a
    /// volume, and this is the one directory guaranteed to share the target's.
    /// It is excluded from sync by name (`Exclusions.cacheDirectoryName`).
    public var cacheDir: URL {
        root.appendingPathComponent(Exclusions.cacheDirectoryName)
    }

    /// A unique, not-yet-created path in the cache directory.
    public func newTempFile() throws -> URL {
        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        return cacheDir.appendingPathComponent(UUID().uuidString)
    }

    /// Throws away everything staged. Called when a cycle ends, so an aborted
    /// download does not occupy disk until the next restart.
    ///
    /// Non-throwing: failing to tidy up is never a reason to fail a sync.
    public func cleanCacheDir() {
        try? FileManager.default.removeItem(at: cacheDir)
    }

    // MARK: - Mutations

    /// Moves a staged file over its destination in one atomic step (§4.6 step 9).
    ///
    /// `rename(2)` rather than `FileManager.moveItem`, which refuses an existing
    /// destination: a replacement has to be indivisible, or a reader could catch
    /// the moment where the file is absent.
    ///
    /// With `preservePermissions`, the replaced file's POSIX mode carries over to
    /// the new contents — set it for a content update of a file the user may
    /// have made executable or read-only.
    public func atomicMoveIntoPlace(from source: URL, to destination: URL, preservePermissions: Bool) throws {
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        if preservePermissions,
            let existing = try? FileManager.default.attributesOfItem(atPath: destination.path),
            let mode = existing[.posixPermissions] as? NSNumber
        {
            try? FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: source.path)
        }

        try ignore.ignoring(
            [
                expected(.created, destination, isDirectory: false),
                expected(.modified, destination, isDirectory: false),
            ]
        ) {
            guard rename(source.path, destination.path) == 0 else {
                throw posixError(code: errno, path: destination.path)
            }
        }
    }

    /// Removes an item and, for a directory, everything beneath it (§4.8).
    ///
    /// With `requireExactCasing`, a delete is refused when the on-disk name
    /// differs from the requested one only by case: on a case-insensitive volume
    /// `A.txt` "exists" when the disk holds `a.txt`, and deleting that would
    /// destroy a file the remote never mentioned.
    ///
    /// An item that is already gone is success, not an error: the remote asked
    /// for it to not exist, and it does not.
    public func deleteItem(at url: URL, requireExactCasing: Bool) throws {
        guard let isDirectory = itemIsDirectory(at: url) else { return }
        if requireExactCasing, !nameMatchesExactly(url) { return }

        try ignore.ignoring([expected(.deleted, url, isDirectory: isDirectory, recursive: isDirectory)]) {
            do {
                try FileManager.default.removeItem(at: url)
            } catch CocoaError.fileNoSuchFile {
                // Lost a race with something else removing it; the goal is met.
            }
        }
    }

    /// Renames or relocates an item, creating the destination's parents.
    public func moveItem(from source: URL, to destination: URL) throws {
        guard let isDirectory = itemIsDirectory(at: source) else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: source.path])
        }
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        try ignore.ignoring(
            [
                ExpectedFSEvent(
                    kind: .moved(to: destination),
                    url: source,
                    isDirectory: isDirectory,
                    recursive: isDirectory
                )
            ]
        ) {
            try FileManager.default.moveItem(at: source, to: destination)
        }
    }

    /// Creates a directory and any missing parents. An existing directory is
    /// success (§4.7).
    public func makeDirectory(at url: URL) throws {
        try ignore.ignoring([expected(.created, url, isDirectory: true)]) {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }

    /// Reproduces a remote symlink locally (§4.6 step 4). No content is
    /// transferred: a symlink's content is its target's, which syncs separately.
    ///
    /// An existing symlink at the path is replaced. Anything else in the way is
    /// left alone — deciding to destroy a real file is the conflict resolver's
    /// call, not this function's.
    public func createSymlink(at url: URL, target: String) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        try ignore.ignoring(
            [expected(.deleted, url, isDirectory: false), expected(.created, url, isDirectory: false)]
        ) {
            if (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil {
                try FileManager.default.removeItem(at: url)
            }
            try FileManager.default.createSymbolicLink(atPath: url.path, withDestinationPath: target)
        }
    }

    /// Stamps a downloaded file with the modification date the uploader recorded
    /// (§4.6 step 6).
    public func setModificationDate(_ date: Date, at url: URL) throws {
        try ignore.ignoring([expected(.modified, url, isDirectory: false)]) {
            try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
        }
    }

    // MARK: - Guards

    /// Verifies the Dropbox folder is still there, under exactly that name
    /// (engine-doc §9).
    ///
    /// Checked before every cycle. A folder the user renamed or moved would
    /// otherwise look like a deletion of everything in it, and the engine would
    /// dutifully delete it all on the remote.
    ///
    /// - Throws: `SyncFatalError.dropboxFolderMissing`.
    public func ensureRootPresent() throws {
        guard itemIsDirectory(at: root) == true, nameMatchesExactly(root) else {
            throw SyncFatalError.dropboxFolderMissing
        }
    }

    // MARK: - Internals

    /// Whether the item at `url` is a directory, or `nil` when nothing is there.
    /// Symlinks are not followed — a link to a folder is still a link.
    private func itemIsDirectory(at url: URL) -> Bool? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else {
            return nil
        }
        return attributes[.type] as? FileAttributeType == .typeDirectory
    }

    /// Whether the parent directory actually holds an entry spelled exactly like
    /// `url`'s last component.
    ///
    /// Asks the directory rather than the path, because `fileExists` on a
    /// case-insensitive volume answers about a *different* file than the one
    /// being named.
    private func nameMatchesExactly(_ url: URL) -> Bool {
        let name = url.lastPathComponent
        guard
            let siblings = try? FileManager.default.contentsOfDirectory(
                atPath: url.deletingLastPathComponent().path
            )
        else {
            return false
        }
        // Unicode normalization differs between what Dropbox stores and what the
        // filesystem reports, and that difference is not a casing drift.
        return siblings.contains { PathStore.equalButForUnicodeNorm($0, name) }
    }

    private func expected(
        _ kind: ExpectedFSEvent.Kind,
        _ url: URL,
        isDirectory: Bool,
        recursive: Bool = false
    ) -> ExpectedFSEvent {
        ExpectedFSEvent(kind: kind, url: url, isDirectory: isDirectory, recursive: recursive)
    }

    private func posixError(code: Int32, path: String) -> Error {
        NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(code),
            userInfo: [
                NSFilePathErrorKey: path,
                NSLocalizedDescriptionKey: String(cString: strerror(code)),
            ]
        )
    }
}

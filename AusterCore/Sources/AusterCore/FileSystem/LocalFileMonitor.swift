import CoreServices
import Foundation

/// Watches the local Dropbox folder and reports what the *user* changed
/// (engine-doc §5.1).
///
/// Everything the engine itself writes is filtered out on the way through, so
/// the stream a consumer sees is already free of echoes. What remains is
/// deliberately imprecise: FSEvents coalesces, batches, and can tag one entry
/// created *and* modified *and* renamed at once, so the monitor picks the most
/// useful single reading of each entry — checking the disk whenever the flags
/// are ambiguous — and leaves the reconciling to the cleaning stage (§5.3).
public final class LocalFileMonitor: @unchecked Sendable {

    /// How long FSEvents may batch before delivering. Short, because the upload
    /// worker debounces on its own anyway and a slow first event just delays
    /// every sync.
    static let latency: CFTimeInterval = 0.05

    /// The user's changes, echoes already removed.
    public let events: AsyncStream<RawFSEvent>

    private let continuation: AsyncStream<RawFSEvent>.Continuation

    /// The folder as the rest of the engine spells it — what `PathStore` and
    /// `LocalFileOperations` derive their URLs from.
    private let root: URL

    /// The same folder with every symlink resolved, which is the only spelling
    /// FSEvents ever uses.
    private let resolvedRoot: URL

    private let ignore: IgnoreFilter
    private let queue: DispatchQueue

    private let lock = NSLock()
    private var stream: FSEventStreamRef?

    public init(root: URL, ignore: IgnoreFilter) {
        // Two spellings of one folder, both needed. FSEvents only ever reports
        // fully resolved paths (`/private/var/…`, never `/var/…`), while the
        // engine declares its own mutations in the unresolved form it was
        // configured with. Every incoming path is translated from the first into
        // the second, so the ignore filter is comparing like with like.
        self.root = root.standardizedFileURL
        self.resolvedRoot = Self.fullyResolved(root)
        self.ignore = ignore
        self.queue = DispatchQueue(label: "com.auster.fsevents")
        (events, continuation) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
    }

    deinit {
        tearDown()
    }

    // MARK: - Lifecycle

    /// - Throws: `SyncFatalError.unexpected` if the stream cannot be created or
    ///   started — without a watcher there is no upload half, so this is not
    ///   something to carry on past.
    public func start() throws {
        lock.lock()
        defer { lock.unlock() }
        guard stream == nil else { return }

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        // `FileEvents` gives per-item rather than per-directory reporting;
        // `NoDefer` delivers the first event of a burst immediately;
        // `WatchRoot` is how a renamed or deleted Dropbox folder is noticed
        // at all (§9).
        let flags = UInt32(
            kFSEventStreamCreateFlagUseCFTypes
                | kFSEventStreamCreateFlagFileEvents
                | kFSEventStreamCreateFlagNoDefer
                | kFSEventStreamCreateFlagWatchRoot
        )

        guard
            let created = FSEventStreamCreate(
                kCFAllocatorDefault,
                fsEventsCallback,
                &context,
                [resolvedRoot.path] as CFArray,
                FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                Self.latency,
                flags
            )
        else {
            throw SyncFatalError.unexpected("Auster could not watch \(root.path) for changes.")
        }

        FSEventStreamSetDispatchQueue(created, queue)
        guard FSEventStreamStart(created) else {
            FSEventStreamInvalidate(created)
            FSEventStreamRelease(created)
            throw SyncFatalError.unexpected("Auster could not start watching \(root.path).")
        }
        stream = created
    }

    public func stop() {
        tearDown()
    }

    private func tearDown() {
        lock.lock()
        defer { lock.unlock() }
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    // MARK: - Rescans (§4.4, §5.6)

    /// Feeds a path back in as if the user had just produced it.
    ///
    /// The engine renames items behind the watcher's back — a conflicted copy, a
    /// selective-sync rename — inside an ignore, which means the real events are
    /// swallowed. Something has to put the result back into the queue or the new
    /// file would sit there forever, never uploaded.
    ///
    /// These are synthetic by construction, so they bypass the ignore filter.
    public func synthesizeRescan(of url: URL, index: SyncDatabase, pathStore: PathStore) {
        let target = url.standardizedFileURL

        guard let attributes = try? FileManager.default.attributesOfItem(atPath: target.path),
            let type = attributes[.type] as? FileAttributeType
        else {
            synthesizeDeletion(of: target, index: index, pathStore: pathStore)
            return
        }

        guard type == .typeDirectory else {
            continuation.yield(RawFSEvent(kind: .modified, url: target, isDirectory: false))
            return
        }

        continuation.yield(RawFSEvent(kind: .created, url: target, isDirectory: true))
        guard
            let walker = FileManager.default.enumerator(
                at: target,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: []
            )
        else {
            return
        }
        for case let child as URL in walker {
            let isDirectory = (try? child.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            continuation.yield(
                RawFSEvent(
                    kind: .created,
                    url: URL(fileURLWithPath: child.path, isDirectory: false),
                    isDirectory: isDirectory
                )
            )
        }
    }

    /// A rescan of something that is not there is only a deletion if the index
    /// thought it existed; otherwise there is nothing to tell Dropbox about.
    private func synthesizeDeletion(of url: URL, index: SyncDatabase, pathStore: PathStore) {
        guard let dbxPath = try? pathStore.toDbxPath(localURL: url),
            let entry = try? index.indexEntry(forPathLower: PathStore.normalize(dbxPath))
        else {
            return
        }
        continuation.yield(
            RawFSEvent(kind: .deleted, url: url, isDirectory: entry.itemType == .folder)
        )
    }

    // MARK: - Event decoding

    fileprivate func handle(entries: [(path: String, flags: FSEventStreamEventFlags, id: FSEventStreamEventId)]) {
        ignore.expireStale()

        var index = 0
        while index < entries.count {
            let entry = entries[index]

            // The Dropbox folder itself moved or vanished. Nothing inside it is
            // meaningful any more; the coordinator's root guard handles it (§9).
            if entry.flags & UInt32(kFSEventStreamEventFlagRootChanged) != 0 {
                index += 1
                continue
            }

            // The folder itself is not an item inside itself; a change to it is
            // the root guard's business, not the upload queue's.
            guard let url = localURL(for: entry.path) else {
                index += 1
                continue
            }
            let isDirectory = entry.flags & UInt32(kFSEventStreamEventFlagItemIsDir) != 0

            // A rename arrives as two entries, old path then new. Pairing them
            // is what turns a whole folder move into one remote call instead of
            // a delete and a re-upload of everything in it.
            if Self.isRename(entry.flags), index + 1 < entries.count,
                Self.isRename(entries[index + 1].flags),
                let paired = pairedMove(entry, entries[index + 1])
            {
                emit(RawFSEvent(kind: .moved(to: paired.destination), url: paired.source, isDirectory: isDirectory))
                index += 2
                continue
            }

            emit(
                RawFSEvent(
                    kind: Self.kind(for: entry.flags, at: URL(fileURLWithPath: entry.path)),
                    url: url,
                    isDirectory: isDirectory
                )
            )
            index += 1
        }
    }

    private func emit(_ event: RawFSEvent) {
        guard !ignore.shouldDrop(event) else { return }
        continuation.yield(event)
    }

    private static func isRename(_ flags: FSEventStreamEventFlags) -> Bool {
        flags & UInt32(kFSEventStreamEventFlagItemRenamed) != 0
    }

    /// Two adjacent rename entries are the two halves of one move when exactly
    /// one of the paths is still on disk.
    ///
    /// Disk state rather than the event ids: the ids are an implementation
    /// detail that has changed across releases, whereas "the source is gone and
    /// the destination is there" is what a move actually *is*. When the shape
    /// does not hold, both entries fall through to be decoded separately — the
    /// cleaner turns that into a delete plus a create, which still converges.
    private func pairedMove(
        _ first: (path: String, flags: FSEventStreamEventFlags, id: FSEventStreamEventId),
        _ second: (path: String, flags: FSEventStreamEventFlags, id: FSEventStreamEventId)
    ) -> (source: URL, destination: URL)? {
        guard first.path != second.path,
            let firstURL = localURL(for: first.path),
            let secondURL = localURL(for: second.path)
        else {
            return nil
        }

        let firstExists = FileManager.default.fileExists(atPath: first.path)
        let secondExists = FileManager.default.fileExists(atPath: second.path)

        if !firstExists, secondExists { return (firstURL, secondURL) }
        if firstExists, !secondExists { return (secondURL, firstURL) }
        return nil
    }

    /// The path with every symlink resolved and the `/private` prefix *kept*.
    ///
    /// `resolvingSymlinksInPath()` cannot be used here: it helpfully strips
    /// `/private` again, which is the one part of the path FSEvents always
    /// includes. `realpath(3)` is the only thing that agrees with the watcher.
    private static func fullyResolved(_ url: URL) -> URL {
        guard let resolved = realpath(url.path, nil) else { return url.standardizedFileURL }
        defer { free(resolved) }
        return URL(fileURLWithPath: String(cString: resolved), isDirectory: false)
    }

    /// Translates a path FSEvents reported into the engine's own spelling of it.
    ///
    /// - Returns: `nil` for the watched folder itself and for anything outside
    ///   it, neither of which is an item to sync.
    private func localURL(for path: String) -> URL? {
        // No `isDirectory:` inference: `URL(fileURLWithPath:)` stats the path and
        // appends a trailing slash for directories, which would make the URL of
        // one item differ depending on whether it still exists.
        let components = URL(fileURLWithPath: path, isDirectory: false).pathComponents
        let rootComponents = resolvedRoot.pathComponents

        guard components.count > rootComponents.count,
            Array(components.prefix(rootComponents.count)) == rootComponents
        else {
            return nil
        }
        // `isDirectory: false` on every join: the one-argument overload stats the
        // path to decide whether to append a trailing slash, so the same item
        // would produce two different URLs depending on whether it exists yet.
        return components.dropFirst(rootComponents.count)
            .reduce(root) { $0.appendingPathComponent($1, isDirectory: false) }
    }

    /// The single most useful reading of a combined flag set.
    ///
    /// Disk state settles every ambiguity: a batch tagged created-and-removed
    /// means something different depending on whether the file is there now, and
    /// the flags alone cannot say which happened last.
    private static func kind(for flags: FSEventStreamEventFlags, at url: URL) -> RawFSEvent.Kind {
        guard FileManager.default.fileExists(atPath: url.path) else { return .deleted }
        if flags & UInt32(kFSEventStreamEventFlagItemCreated) != 0 { return .created }
        return .modified
    }
}

/// The C entry point FSEvents calls, which does nothing but repackage its
/// parallel arrays and hand them to the monitor.
private let fsEventsCallback: FSEventStreamCallback = { _, info, count, paths, flags, ids in
    guard let info, let cfPaths = unsafeBitCast(paths, to: NSArray.self) as? [String] else { return }
    let monitor = Unmanaged<LocalFileMonitor>.fromOpaque(info).takeUnretainedValue()

    var entries: [(path: String, flags: FSEventStreamEventFlags, id: FSEventStreamEventId)] = []
    entries.reserveCapacity(count)
    for offset in 0..<count where offset < cfPaths.count {
        entries.append((cfPaths[offset], flags[offset], ids[offset]))
    }
    monitor.handle(entries: entries)
}

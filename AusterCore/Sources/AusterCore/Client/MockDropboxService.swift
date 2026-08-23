import Foundation

/// An in-memory Dropbox.
///
/// This is the remote the whole engine is tested against, so it aims for
/// *behavioural* fidelity to the real service rather than completeness — the
/// places where Dropbox is surprising are exactly the places the engine has to
/// get right (api-notes §2, §3):
///
/// - Moves are never reported as moves. The change log gets a tombstone at the
///   old path and a fresh entry at the new one.
/// - A folder delete reports only the folder. Children vanish without their own
///   tombstones, so a client has to consult its own index to know what went.
/// - A tombstone says nothing about whether the deleted entry was a file or a
///   folder.
/// - `.update(rev:)` against a moved-on revision does not fail: with
///   `autorename`, the server writes a conflicted copy and leaves the original
///   alone. That is what makes a lost update impossible (decisions D9.1).
/// - Uploading into a folder that does not exist creates the parents.
///
/// It lives in the main target rather than the test target so later phases can
/// grow scenario helpers on it.
///
/// Thread safety: every operation takes one lock for its whole duration, which
/// makes each call atomic with respect to the others — matching the guarantee a
/// single Dropbox API call gives.
public final class MockDropboxService: DropboxService, @unchecked Sendable {

    /// The routes a test can inject a failure into.
    public enum Call: Sendable, Hashable, CaseIterable {
        case currentAccount
        case spaceUsage
        case listFolder
        case listFolderContinue
        case longpoll
        case metadata
        case download
        case upload
        case delete
        case move
        case createFolder
        case revokeToken
    }

    // MARK: - Stored state

    /// A live entry: its metadata plus, for files, its bytes.
    private struct Node {
        var metadata: RemoteMetadata
        var data: Data
    }

    /// What a cursor points at. A listing cursor turns into a delta cursor once
    /// the listing is exhausted, exactly as Dropbox's does.
    private enum CursorState {
        case listing(remaining: [RemoteMetadata], logPosition: Int, root: String, recursive: Bool)
        case delta(logPosition: Int, root: String, recursive: Bool)
    }

    private let lock = NSLock()

    /// pathLower → node. Folders and files only; tombstones live separately.
    private var nodes: [String: Node] = [:]

    /// Every revision ever written, so `download(rev:)` can still fetch a
    /// version that has since been overwritten.
    private var revisions: [String: (file: RemoteFile, data: Data)] = [:]

    /// pathLower → the tombstone `metadata(includeDeleted: true)` should return.
    private var tombstones: [String: RemoteDeleted] = [:]

    /// Append-only; a cursor is a position in this log.
    private var changeLog: [RemoteMetadata] = []

    private var cursors: [String: CursorState] = [:]

    private var revCounter = 0
    private var idCounter = 0
    private var cursorCounter = 0

    private var pendingFailures: [Call: [DropboxServiceError]] = [:]
    private var recorded: [Call] = []
    private var uploads: [(path: String, mode: WriteMode, clientModified: Date)] = []
    private var deletes: [(path: String, parentRev: String?)] = []
    private var moves: [(from: String, to: String)] = []
    private var folderCreations: [String] = []
    private var isAuthorized = true

    private var storedAccount = AccountInfo(
        accountId: "dbid:mock",
        displayName: "Mock User",
        email: "mock@example.com",
        accountType: "basic",
        isTeam: false,
        profilePhotoURL: nil
    )
    private var storedUsage = SpaceUsage(used: 0, allocated: 2_000_000_000)
    private var storedPageSize: Int?
    private var storedLongpollBackoff: Int?
    private var storedReversesListingOrder = false

    public init() {}

    // MARK: - Test configuration

    /// The account `currentAccount()` reports. Set `isTeam` to exercise the
    /// team-account rejection at link time (decisions D4).
    public var account: AccountInfo {
        get { lock.withLock { storedAccount } }
        set { lock.withLock { storedAccount = newValue } }
    }

    /// The figures `spaceUsage()` reports.
    public var usage: SpaceUsage {
        get { lock.withLock { storedUsage } }
        set { lock.withLock { storedUsage = newValue } }
    }

    /// Entries per listing page. `nil` (the default) returns everything at once;
    /// set it to force the paging path through `listFolderContinue`.
    public var pageSize: Int? {
        get { lock.withLock { storedPageSize } }
        set { lock.withLock { storedPageSize = newValue } }
    }

    /// The `backoff` every `longpoll` reports back.
    public var longpollBackoff: Int? {
        get { lock.withLock { storedLongpollBackoff } }
        set { lock.withLock { storedLongpollBackoff = newValue } }
    }

    /// Emits every page's entries back to front.
    ///
    /// Dropbox promises only that applying a page *in order* reproduces server
    /// state — not that parents precede their children. Setting this proves the
    /// engine's own ordering (engine-doc §4.3) is what puts folders first,
    /// rather than the listing happening to arrive that way.
    public var reversesListingOrder: Bool {
        get { lock.withLock { storedReversesListingOrder } }
        set { lock.withLock { storedReversesListingOrder = newValue } }
    }

    /// Routes called so far, in order — for asserting that a code path did (or
    /// did not) reach the network.
    public var recordedCalls: [Call] {
        lock.withLock { recorded }
    }

    /// Every upload, with the arguments the engine chose.
    ///
    /// The write mode is the whole safety story of an upload (api-notes §2), so
    /// asserting on it is asserting that a lost update is impossible.
    public var recordedUploads: [(path: String, mode: WriteMode, clientModified: Date)] {
        lock.withLock { uploads }
    }

    /// Every delete, with the revision guard the engine attached (decisions D9.5).
    public var recordedDeletes: [(path: String, parentRev: String?)] {
        lock.withLock { deletes }
    }

    /// Every move, source then destination.
    public var recordedMoves: [(from: String, to: String)] {
        lock.withLock { moves }
    }

    /// Every folder creation, in order — enough to assert that parents were
    /// created before their children (engine-doc §5.5).
    public var recordedFolderCreations: [String] {
        lock.withLock { folderCreations }
    }

    /// Makes the next `times` calls to `call` throw `error`.
    ///
    /// Failures are queued per route, so injecting an upload failure leaves
    /// listings alone.
    public func failNext(_ call: Call, with error: DropboxServiceError, times: Int = 1) {
        lock.withLock {
            pendingFailures[call, default: []].append(contentsOf: Array(repeating: error, count: times))
        }
    }

    /// Drops every queued failure.
    public func clearInjectedFailures() {
        lock.withLock { pendingFailures.removeAll() }
    }

    /// Invalidates every outstanding cursor, so the next `listFolderContinue`
    /// throws `.cursorReset` and the caller has to re-index.
    public func invalidateCursors() {
        lock.withLock { cursors.removeAll() }
    }

    /// Simulates a revoked or invalid token: every later call fails with
    /// `.notAuthorized`.
    public func deauthorize() {
        lock.withLock { isAuthorized = false }
    }

    // MARK: - Seeding & inspection

    /// Puts a file into the remote without going through the upload path.
    @discardableResult
    public func seedFile(at path: String, contents: String, clientModified: Date = Date()) throws -> RemoteFile {
        try seedFile(at: path, data: Data(contents.utf8), clientModified: clientModified)
    }

    /// Puts a file into the remote without going through the upload path.
    @discardableResult
    public func seedFile(at path: String, data: Data, clientModified: Date = Date()) throws -> RemoteFile {
        try lock.withLock {
            try write(data: data, to: path, mode: .overwrite, autorename: false, clientModified: clientModified)
        }
    }

    /// Puts a symlink into the remote.
    ///
    /// Dropbox stores a symlink as file metadata carrying `symlink_info`, with
    /// no content worth downloading — which is what lets the engine reproduce it
    /// without a transfer (engine-doc §4.6 step 4).
    @discardableResult
    public func seedSymlink(at path: String, target: String) -> RemoteFile {
        lock.withLock {
            createParents(of: path)
            let display = Self.normalized(path)
            let file = RemoteFile(
                id: nodes[display.lowercased()]?.metadata.asFile?.id ?? nextID(),
                name: Self.basename(of: display),
                pathLower: display.lowercased(),
                pathDisplay: display,
                rev: nextRev(),
                size: 0,
                contentHash: ContentHasher.hash(data: Data()),
                clientModified: Date(),
                serverModified: Date(),
                symlinkTarget: target,
                isDownloadable: true,
                modifiedBy: nil
            )
            nodes[file.pathLower] = Node(metadata: .file(file), data: Data())
            revisions[file.rev] = (file, Data())
            tombstones[file.pathLower] = nil
            changeLog.append(.file(file))
            return file
        }
    }

    /// Puts a folder (and any missing parents) into the remote.
    @discardableResult
    public func seedFolder(at path: String) -> RemoteFolder {
        lock.withLock {
            let key = Self.key(for: path)
            if let existing = nodes[key]?.metadata.asFolder { return existing }
            createParents(of: path)
            return makeFolder(at: path)
        }
    }

    /// The bytes stored at `path`.
    public func contents(at path: String) throws -> Data {
        try lock.withLock {
            let key = Self.key(for: path)
            guard let node = nodes[key], node.metadata.asFile != nil else {
                throw DropboxServiceError.notFound(path: path)
            }
            return node.data
        }
    }

    /// Every live entry, sorted by path — a convenient whole-remote assertion.
    public var allEntries: [RemoteMetadata] {
        lock.withLock { nodes.keys.sorted().compactMap { nodes[$0]?.metadata } }
    }

    // MARK: - DropboxService: account

    public func currentAccount() async throws -> AccountInfo {
        try lock.withLock {
            try enter(.currentAccount)
            return storedAccount
        }
    }

    public func spaceUsage() async throws -> SpaceUsage {
        try lock.withLock {
            try enter(.spaceUsage)
            return storedUsage
        }
    }

    public func revokeToken() async throws {
        try lock.withLock {
            try enter(.revokeToken)
            isAuthorized = false
        }
    }

    // MARK: - DropboxService: listing

    public func listFolder(path: String, recursive: Bool) async throws -> ListPage {
        try lock.withLock {
            try enter(.listFolder)
            let root = Self.key(for: path)
            // Dropbox answers a listing of a path that is not a folder with
            // `path/not_found` or `path/not_folder`; it does not treat "no
            // entries under this prefix" as an empty folder. An engine tested
            // only against the lenient answer would never meet the strict one
            // (found by the integration suite, note N39). The root is the one
            // path that always exists, even on an empty account.
            if !root.isEmpty {
                guard let node = nodes[root] else {
                    throw DropboxServiceError.notFound(path: Self.normalized(path))
                }
                guard node.metadata.asFolder != nil else {
                    throw DropboxServiceError.conflict(path: Self.normalized(path))
                }
            }
            let matching = nodes.keys
                .filter { Self.isDescendant($0, of: root, recursive: recursive) }
                .sorted()
                .compactMap { nodes[$0]?.metadata }
            return page(from: matching, logPosition: changeLog.count, root: root, recursive: recursive)
        }
    }

    public func listFolderContinue(cursor: String) async throws -> ListPage {
        try lock.withLock {
            try enter(.listFolderContinue)
            guard let state = cursors[cursor] else { throw DropboxServiceError.cursorReset }
            cursors[cursor] = nil

            switch state {
            case .listing(let remaining, let logPosition, let root, let recursive):
                return page(from: remaining, logPosition: logPosition, root: root, recursive: recursive)

            case .delta(let logPosition, let root, let recursive):
                var delta = changeLog[logPosition...]
                    .filter { Self.isDescendant($0.pathLower, of: root, recursive: recursive) }
                if storedReversesListingOrder { delta.reverse() }
                return ListPage(
                    entries: delta,
                    cursor: makeCursor(.delta(logPosition: changeLog.count, root: root, recursive: recursive)),
                    hasMore: false
                )
            }
        }
    }

    public func longpoll(cursor: String, timeout: Int) async throws -> (changes: Bool, backoff: Int?) {
        try lock.withLock {
            try enter(.longpoll)
            guard let state = cursors[cursor] else { throw DropboxServiceError.cursorReset }
            let changes: Bool
            switch state {
            case .listing:
                changes = true  // an unfinished listing always has more to fetch
            case .delta(let logPosition, let root, let recursive):
                changes = changeLog[logPosition...]
                    .contains { Self.isDescendant($0.pathLower, of: root, recursive: recursive) }
            }
            return (changes, storedLongpollBackoff)
        }
    }

    // MARK: - DropboxService: single items

    public func metadata(path: String, includeDeleted: Bool) async throws -> RemoteMetadata? {
        try lock.withLock {
            try enter(.metadata)
            let key = Self.key(for: path)
            if let node = nodes[key] { return node.metadata }
            if includeDeleted, let tombstone = tombstones[key] { return .deleted(tombstone) }
            return nil
        }
    }

    // MARK: - DropboxService: transfers

    public func download(
        rev: String,
        to localURL: URL,
        progress: @escaping @Sendable (Int64) -> Void
    ) async throws -> RemoteFile {
        let revision: (file: RemoteFile, data: Data) = try lock.withLock {
            try enter(.download)
            guard let revision = revisions[rev] else {
                throw DropboxServiceError.notFound(path: "rev:\(rev)")
            }
            return revision
        }

        try FileManager.default.createDirectory(
            at: localURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        do {
            try revision.data.write(to: localURL, options: .atomic)
        } catch {
            throw DropboxServiceError.other(message: "mock download could not write: \(error)")
        }
        progress(Int64(revision.data.count))
        return revision.file
    }

    public func upload(
        from localURL: URL,
        to dbxPath: String,
        mode: WriteMode,
        autorename: Bool,
        clientModified: Date,
        progress: @escaping @Sendable (Int64) -> Void
    ) async throws -> RemoteFile {
        let data: Data
        do {
            data = try Data(contentsOf: localURL)
        } catch {
            throw DropboxServiceError.other(message: "mock upload could not read \(localURL.path): \(error)")
        }

        let uploaded: RemoteFile = try lock.withLock {
            try enter(.upload)
            uploads.append((Self.normalized(dbxPath), mode, clientModified))
            return try write(
                data: data,
                to: dbxPath,
                mode: mode,
                autorename: autorename,
                clientModified: clientModified
            )
        }
        progress(uploaded.size)
        return uploaded
    }

    // MARK: - DropboxService: mutations

    public func delete(path: String, parentRev: String?) async throws {
        try lock.withLock {
            try enter(.delete)
            deletes.append((Self.normalized(path), parentRev))
            let key = Self.key(for: path)
            guard let node = nodes[key] else { throw DropboxServiceError.notFound(path: path) }

            if let parentRev, let file = node.metadata.asFile, file.rev != parentRev {
                throw DropboxServiceError.conflict(path: path)
            }

            remove(subtreeAt: key)
            let tombstone = RemoteDeleted(
                name: node.metadata.name,
                pathLower: node.metadata.pathLower,
                pathDisplay: node.metadata.pathDisplay
            )
            tombstones[key] = tombstone
            // Only the folder itself is reported; children go silently.
            changeLog.append(.deleted(tombstone))
        }
    }

    public func move(from: String, to: String, autorename: Bool) async throws -> RemoteMetadata {
        try lock.withLock {
            try enter(.move)
            moves.append((Self.normalized(from), Self.normalized(to)))
            let sourceKey = Self.key(for: from)
            guard let source = nodes[sourceKey] else { throw DropboxServiceError.notFound(path: from) }

            var destination = to
            // A move that only changes casing lands on its own key, and Dropbox
            // allows it — it is how a rename to `Report.TXT` is expressed.
            if nodes[Self.key(for: to)] != nil, Self.key(for: to) != sourceKey {
                guard autorename else { throw DropboxServiceError.conflict(path: to) }
                destination = availablePath(basedOn: to)
            }

            let descendants = remove(subtreeAt: sourceKey)

            let moved = reparent(source.metadata, to: destination)
            nodes[moved.pathLower] = Node(metadata: moved, data: source.data)
            tombstones[moved.pathLower] = nil
            if let file = moved.asFile { revisions[file.rev] = (file, source.data) }

            for (descendantKey, node) in descendants.sorted(by: { $0.key < $1.key }) {
                let depth = descendantKey.dropFirst(sourceKey.count)
                let newPath = destination + Self.displaySuffix(of: node.metadata.pathDisplay, depth: depth)
                let relocated = reparent(node.metadata, to: newPath)
                nodes[relocated.pathLower] = Node(metadata: relocated, data: node.data)
                tombstones[relocated.pathLower] = nil
                if let file = relocated.asFile { revisions[file.rev] = (file, node.data) }
            }

            // A case-only rename has nothing to bury: the entry is still there,
            // just spelled differently.
            if moved.pathLower != sourceKey {
                let tombstone = RemoteDeleted(
                    name: source.metadata.name,
                    pathLower: source.metadata.pathLower,
                    pathDisplay: source.metadata.pathDisplay
                )
                tombstones[sourceKey] = tombstone
                changeLog.append(.deleted(tombstone))
            }
            changeLog.append(moved)
            return moved
        }
    }

    public func createFolder(path: String, autorename: Bool) async throws -> RemoteFolder {
        try lock.withLock {
            try enter(.createFolder)
            folderCreations.append(Self.normalized(path))
            var target = path
            if nodes[Self.key(for: path)] != nil {
                guard autorename else { throw DropboxServiceError.conflict(path: path) }
                target = availablePath(basedOn: path)
            }
            createParents(of: target)
            return makeFolder(at: target)
        }
    }

    // MARK: - Internals: preconditions

    /// Records the call, applies any injected failure, and enforces the token.
    /// Call this first in every route, under the lock.
    private func enter(_ call: Call) throws {
        recorded.append(call)
        if var queued = pendingFailures[call], !queued.isEmpty {
            let error = queued.removeFirst()
            pendingFailures[call] = queued.isEmpty ? nil : queued
            throw error
        }
        guard isAuthorized else { throw DropboxServiceError.notAuthorized }
    }

    // MARK: - Internals: writing

    /// Shared by uploads and seeding: applies a write mode and records the
    /// revision. Must be called under the lock.
    private func write(
        data: Data,
        to path: String,
        mode: WriteMode,
        autorename: Bool,
        clientModified: Date
    ) throws -> RemoteFile {
        var target = path
        let existing = nodes[Self.key(for: path)]?.metadata

        switch mode {
        case .overwrite:
            break

        case .add:
            if existing != nil {
                guard autorename else { throw DropboxServiceError.conflict(path: path) }
                target = availablePath(basedOn: path)
            }

        case .update(let rev):
            // A missing entry is not a conflict: `update` writes it. A rev that
            // has moved on is, and with autorename the server parks our version
            // beside the original rather than replacing it.
            if let existing, existing.asFile?.rev != rev {
                guard autorename else { throw DropboxServiceError.conflict(path: path) }
                target = availablePath(basedOn: Self.conflictedCopyPath(for: path))
            }
        }

        if existing != nil, existing?.asFile == nil, target == path {
            // A folder occupies the path; a file cannot replace it.
            throw DropboxServiceError.conflict(path: path)
        }

        createParents(of: target)

        let key = Self.key(for: target)
        let id = nodes[key]?.metadata.asFile?.id ?? nextID()
        let file = RemoteFile(
            id: id,
            name: Self.basename(of: target),
            pathLower: key,
            pathDisplay: Self.normalized(target),
            rev: nextRev(),
            size: Int64(data.count),
            contentHash: ContentHasher.hash(data: data),
            clientModified: clientModified,
            serverModified: Date(),
            symlinkTarget: nil,
            isDownloadable: true,
            modifiedBy: nil
        )

        nodes[key] = Node(metadata: .file(file), data: data)
        revisions[file.rev] = (file, data)
        tombstones[key] = nil
        changeLog.append(.file(file))
        return file
    }

    /// Creates any missing ancestors of `path`, as the server does on upload.
    private func createParents(of path: String) {
        let normalized = Self.normalized(path)
        var components = normalized.split(separator: "/").map(String.init)
        guard components.count > 1 else { return }
        components.removeLast()

        var prefix = ""
        for component in components {
            prefix += "/" + component
            guard nodes[prefix.lowercased()] == nil else { continue }
            _ = makeFolder(at: prefix)
        }
    }

    /// Inserts a folder at `path` and logs it. Must be called under the lock.
    @discardableResult
    private func makeFolder(at path: String) -> RemoteFolder {
        let display = Self.normalized(path)
        let folder = RemoteFolder(
            id: nextID(),
            name: Self.basename(of: display),
            pathLower: display.lowercased(),
            pathDisplay: display
        )
        nodes[folder.pathLower] = Node(metadata: .folder(folder), data: Data())
        tombstones[folder.pathLower] = nil
        changeLog.append(.folder(folder))
        return folder
    }

    /// Removes an entry and everything beneath it, leaving tombstones for the
    /// children.
    ///
    /// - Returns: the removed descendants, keyed by path, so a move can put the
    ///   subtree back down under its new parent.
    @discardableResult
    private func remove(subtreeAt key: String) -> [String: Node] {
        var descendants: [String: Node] = [:]
        for (candidate, node) in nodes where candidate == key || candidate.hasPrefix(key + "/") {
            nodes[candidate] = nil
            guard candidate != key else { continue }
            descendants[candidate] = node
            tombstones[candidate] = RemoteDeleted(
                name: node.metadata.name,
                pathLower: node.metadata.pathLower,
                pathDisplay: node.metadata.pathDisplay
            )
        }
        return descendants
    }

    /// Rewrites an entry's paths for a new location, keeping its id — Dropbox
    /// ids survive moves, revs and paths do not.
    private func reparent(_ metadata: RemoteMetadata, to path: String) -> RemoteMetadata {
        let display = Self.normalized(path)
        let name = Self.basename(of: display)
        switch metadata {
        case .file(let file):
            return .file(
                RemoteFile(
                    id: file.id,
                    name: name,
                    pathLower: display.lowercased(),
                    pathDisplay: display,
                    rev: file.rev,
                    size: file.size,
                    contentHash: file.contentHash,
                    clientModified: file.clientModified,
                    serverModified: Date(),
                    symlinkTarget: file.symlinkTarget,
                    isDownloadable: file.isDownloadable,
                    modifiedBy: file.modifiedBy
                )
            )
        case .folder(let folder):
            return .folder(
                RemoteFolder(
                    id: folder.id,
                    name: name,
                    pathLower: display.lowercased(),
                    pathDisplay: display
                )
            )
        case .deleted:
            return metadata
        }
    }

    // MARK: - Internals: paging

    private func page(
        from entries: [RemoteMetadata],
        logPosition: Int,
        root: String,
        recursive: Bool
    ) -> ListPage {
        let entries = storedReversesListingOrder ? entries.reversed() : entries
        guard let limit = storedPageSize, entries.count > limit else {
            return ListPage(
                entries: entries,
                cursor: makeCursor(.delta(logPosition: logPosition, root: root, recursive: recursive)),
                hasMore: false
            )
        }
        let head = Array(entries.prefix(limit))
        let tail = Array(entries.dropFirst(limit))
        let cursor = makeCursor(
            .listing(remaining: tail, logPosition: logPosition, root: root, recursive: recursive)
        )
        return ListPage(entries: head, cursor: cursor, hasMore: true)
    }

    private func makeCursor(_ state: CursorState) -> String {
        cursorCounter += 1
        let cursor = "auster-mock-cursor-\(cursorCounter)"
        cursors[cursor] = state
        return cursor
    }

    // MARK: - Internals: naming

    private func nextRev() -> String {
        revCounter += 1
        return String(format: "%016x", revCounter)
    }

    private func nextID() -> String {
        idCounter += 1
        return "id:mock\(idCounter)"
    }

    /// The first free `"name (n).ext"` at or after `path`.
    private func availablePath(basedOn path: String) -> String {
        guard nodes[Self.key(for: path)] != nil else { return Self.normalized(path) }
        var suffix = 2
        while true {
            let candidate = Self.suffixed(path, with: " (\(suffix))")
            if nodes[Self.key(for: candidate)] == nil { return candidate }
            suffix += 1
        }
    }

    // MARK: - Internals: path arithmetic

    /// `""` for the root, otherwise a leading-slash path with no trailing slash.
    static func normalized(_ path: String) -> String {
        var trimmed = path
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        guard !trimmed.isEmpty else { return "" }
        return trimmed.hasPrefix("/") ? trimmed : "/" + trimmed
    }

    /// The case-insensitive lookup key for a path.
    static func key(for path: String) -> String {
        normalized(path).lowercased()
    }

    static func basename(of path: String) -> String {
        String(normalized(path).split(separator: "/").last ?? "")
    }

    /// Whether `key` sits under `root` — directly, or at any depth when recursive.
    static func isDescendant(_ key: String, of root: String, recursive: Bool) -> Bool {
        guard key.hasPrefix(root + "/") else { return false }
        let remainder = key.dropFirst(root.count + 1)
        return recursive || !remainder.contains("/")
    }

    /// Inserts `suffix` before the extension: `/a/report.txt` + `" (2)"` →
    /// `/a/report (2).txt`.
    static func suffixed(_ path: String, with suffix: String) -> String {
        let normalized = normalized(path)
        let name = basename(of: normalized)
        let parent = String(normalized.dropLast(name.count))
        let dot = name.lastIndex(of: ".")
        guard let dot, dot != name.startIndex else { return normalized + suffix }
        return parent + name[name.startIndex..<dot] + suffix + name[dot...]
    }

    /// The name the server gives a losing `.update(rev:)` write.
    static func conflictedCopyPath(for path: String) -> String {
        suffixed(path, with: " (conflicted copy)")
    }

    /// The trailing path of a descendant, preserving its own display casing.
    static func displaySuffix(of display: String, depth: Substring) -> String {
        let components = normalized(display).split(separator: "/")
        let depthCount = depth.split(separator: "/").count
        return components.suffix(depthCount).map { "/" + $0 }.joined()
    }
}

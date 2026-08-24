import Foundation
import Synchronization

/// Why a local path could not be expressed as a Dropbox path.
public enum PathStoreError: Error, Sendable, Equatable {

    /// The URL is not inside the Dropbox folder. The engine must never derive a
    /// Dropbox path for something it does not own.
    case outsideDropboxFolder(path: String)
}

/// Translates between local file URLs and Dropbox paths. The two namespaces
/// disagree about case, Unicode form and display casing (engine-doc §9), and
/// every method here exists because of one of them.
public struct PathStore: Sendable {

    private let root: URL
    private let database: SyncDatabase
    private let service: DropboxService
    private let caseCache: CaseCache

    public init(dropboxRoot: URL, database: SyncDatabase, service: DropboxService) {
        self.root = dropboxRoot.standardizedFileURL
        self.database = database
        self.service = service
        self.caseCache = CaseCache()
    }

    // MARK: - Normalization

    /// The index key for a Dropbox path: lowercased, then NFC-composed.
    /// Lowercasing first, because it can itself produce decomposed output —
    /// U+212B (ANGSTROM SIGN) lowercases to a decomposed "å".
    public static func normalize(_ dbxPath: String) -> String {
        dbxPath.lowercased().precomposedStringWithCanonicalMapping
    }

    /// Whether two names are the same once Unicode normalization is accounted
    /// for. Case is *not* normalized away: a case change is a real rename on
    /// disk, a normalization change is not.
    public static func equalButForUnicodeNorm(_ a: String, _ b: String) -> Bool {
        a.precomposedStringWithCanonicalMapping == b.precomposedStringWithCanonicalMapping
    }

    // MARK: - Local ↔ Dropbox

    /// The Dropbox path for a local URL, preserving the on-disk casing. The
    /// Dropbox root is `""`, not `"/"` (api-notes §2). Throws
    /// `PathStoreError.outsideDropboxFolder`, checked component-wise.
    public func toDbxPath(localURL: URL) throws -> String {
        let components = localURL.standardizedFileURL.pathComponents
        let rootComponents = root.pathComponents

        guard components.count >= rootComponents.count,
            Array(components.prefix(rootComponents.count)) == rootComponents
        else {
            throw PathStoreError.outsideDropboxFolder(path: localURL.path)
        }

        let relative = components.dropFirst(rootComponents.count)
        guard !relative.isEmpty else { return "" }
        return "/" + relative.joined(separator: "/").precomposedStringWithCanonicalMapping
    }

    /// The local URL for a correctly cased Dropbox path, built lexically: the
    /// one-argument `appendingPathComponent` stats the path, and would give a
    /// folder one URL before it exists and a different one after.
    public func toLocalURL(dbxPathCased: String) -> URL {
        let relative = dbxPathCased.split(separator: "/", omittingEmptySubsequences: true)
        return relative.reduce(root) { $0.appendingPathComponent(String($1), isDirectory: false) }
    }

    // MARK: - Case correction

    /// Fills in the casing of a path's parent components, given a correctly cased
    /// basename: cache → index → one `metadata` call (engine-doc §9), each result
    /// cached. An unknown ancestor keeps the casing it arrived with.
    public func correctCase(_ dbxPathBasenameCased: String) async throws -> String {
        let components = dbxPathBasenameCased.split(separator: "/", omittingEmptySubsequences: true)
        guard components.count > 1 else { return dbxPathBasenameCased }

        var cased = ""
        for component in components.dropLast() {
            cased = try await correctedComponent(parentCased: cased, name: String(component))
        }
        return cased + "/" + String(components[components.count - 1])
    }

    /// One ancestor's correctly cased path, given its already-corrected parent.
    private func correctedComponent(parentCased: String, name: String) async throws -> String {
        let candidate = parentCased + "/" + name
        let key = Self.normalize(candidate)

        if let cached = caseCache.value(forKey: key) { return cached }

        if let entry = try database.indexEntry(forPathLower: key) {
            caseCache.insert(entry.dbxPathCased, forKey: key)
            return entry.dbxPathCased
        }

        // Only the basename of `path_display` is authoritative, which is exactly
        // the part being resolved here — the rest comes from the already-correct
        // parent.
        if let metadata = try await service.metadata(path: key, includeDeleted: false) {
            let resolved = parentCased + "/" + metadata.name
            caseCache.insert(resolved, forKey: key)
            return resolved
        }

        return candidate
    }

    // MARK: - Volume probing

    /// Whether the volume holding `url` distinguishes `A` from `a`. Asked rather
    /// than assumed, by writing a file and asking for it under another casing; an
    /// unwritable probe answers `false`, the conservative direction.
    public static func isCaseSensitiveVolume(at url: URL) -> Bool {
        let probe = url.appendingPathComponent(".auster-case-probe-\(UUID().uuidString)")
        guard (try? Data().write(to: probe)) != nil else { return false }
        defer { try? FileManager.default.removeItem(at: probe) }

        let alternate = probe.deletingLastPathComponent()
            .appendingPathComponent(probe.lastPathComponent.uppercased())
        return !FileManager.default.fileExists(atPath: alternate.path)
    }

    // MARK: - Conflicted copies

    /// A free name for a Dropbox-style conflicted copy: `"name (suffix).ext"`,
    /// gaining ` (1)`, ` (2)`… until nothing is in the way (engine-doc §4.4). A
    /// leading dot is part of the name, not an extension.
    public static func conflictedCopyName(for localURL: URL, suffix: String) -> URL {
        let directory = localURL.deletingLastPathComponent()
        let (stem, dotExtension) = splitName(localURL.lastPathComponent)

        var counter = 0
        while true {
            let infix = counter == 0 ? " (\(suffix))" : " (\(suffix)) (\(counter))"
            let candidate = directory.appendingPathComponent(stem + infix + dotExtension)
            // `fileExists` rather than a reachability check: a directory in the
            // way is just as much of a collision as a file.
            if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            counter += 1
        }
    }

    /// Splits a filename into its stem and its extension *including* the dot
    /// (`""` when there is none).
    private static func splitName(_ name: String) -> (stem: String, dotExtension: String) {
        // A dot at index 0 belongs to the name; only a later one starts an
        // extension, and only the last such one.
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else {
            return (name, "")
        }
        return (String(name[name.startIndex..<dot]), String(name[dot...]))
    }
}

/// The bounded cache behind `PathStore.correctCase`. A reference type so every
/// copy of a `PathStore` shares one, and `Mutex`-guarded because the download
/// workers resolve paths concurrently. Eviction is oldest-insertion-first.
final class CaseCache: Sendable {

    /// Roughly the ceiling Maestral used (engine-doc §9). Large enough that a
    /// normal sync never evicts, small enough to bound a pathological tree.
    static let capacity = 5_000

    private struct Storage {
        var entries: [String: String] = [:]
        var order: [String] = []
    }

    private let storage = Mutex(Storage())

    func value(forKey key: String) -> String? {
        storage.withLock { $0.entries[key] }
    }

    func insert(_ value: String, forKey key: String) {
        storage.withLock { storage in
            if storage.entries.updateValue(value, forKey: key) == nil {
                storage.order.append(key)
            }
            guard storage.order.count > Self.capacity else { return }
            let evicted = storage.order.removeFirst()
            storage.entries.removeValue(forKey: evicted)
        }
    }
}

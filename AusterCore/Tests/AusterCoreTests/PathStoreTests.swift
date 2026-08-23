import Foundation
import Testing

@testable import AusterCore

/// `PathStore` is the translation layer between two filesystems that disagree
/// about identity: Dropbox is case-insensitive and NFC, macOS is
/// case-preserving and hands back NFD. Every rule here exists because getting it
/// wrong duplicates a user's file rather than syncing it (engine-doc §9).
@Suite("PathStore")
struct PathStoreTests {

    // MARK: - Fixtures

    /// A store rooted in a fresh temp directory.
    ///
    /// The root is symlink-resolved because `/tmp` is itself a symlink on macOS,
    /// and a store that disagreed with the caller about its own root would fail
    /// every containment check.
    private func withStore<T>(
        _ body: (PathStore, MockDropboxService, SyncDatabase, URL) async throws -> T
    ) async throws -> T {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("auster-paths-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let root = directory.appendingPathComponent("Dropbox")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let database = try SyncDatabase(path: directory.appendingPathComponent("sync.db").path)
        let service = MockDropboxService()
        let store = PathStore(dropboxRoot: root, database: database, service: service)
        return try await body(store, service, database, root)
    }

    private func indexEntry(lower: String, cased: String, type: ItemType = .folder) -> IndexEntry {
        IndexEntry(
            dbxPathLower: lower,
            dbxPathCased: cased,
            dbxId: "id:\(lower)",
            itemType: type,
            lastSync: nil,
            rev: ItemType.folderSentinel,
            contentHash: ItemType.folderSentinel,
            symlinkTarget: nil
        )
    }

    // MARK: - Normalization

    @Test("Normalizing lowercases the path")
    func normalizeLowercases() {
        #expect(PathStore.normalize("/Photos/Cat.JPG") == "/photos/cat.jpg")
    }

    @Test("Normalizing composes decomposed characters")
    func normalizeComposes() {
        // "é" as e + U+0301, which is what macOS hands back for a file called "café".
        let decomposed = "/caf\u{65}\u{301}"
        #expect(PathStore.normalize(decomposed) == "/caf\u{e9}")
    }

    @Test("Normalizing is idempotent")
    func normalizeIsIdempotent() {
        let once = PathStore.normalize("/Caf\u{65}\u{301}/\u{c5}ngstr\u{f6}m.txt")
        #expect(PathStore.normalize(once) == once)
    }

    @Test("Normalizing lowercases characters whose lowercase form decomposes")
    func normalizeLowercasesAndRecomposes() {
        // U+212B ANGSTROM SIGN lowercases to "å", which must end up composed.
        #expect(PathStore.normalize("/\u{212b}") == "/\u{e5}")
    }

    @Test("The root normalizes to itself")
    func normalizeRoot() {
        #expect(PathStore.normalize("") == "")
        #expect(PathStore.normalize("/") == "/")
    }

    // MARK: - Unicode comparison

    @Test("Strings differing only by normalization compare equal")
    func unicodeNormComparison() {
        #expect(PathStore.equalButForUnicodeNorm("caf\u{e9}", "caf\u{65}\u{301}"))
        #expect(PathStore.equalButForUnicodeNorm("caf\u{e9}", "caf\u{e9}"))
    }

    @Test("Genuinely different strings do not compare equal")
    func unicodeNormComparisonRejectsDifferences() {
        #expect(!PathStore.equalButForUnicodeNorm("cafe", "caf\u{e9}"))
        // Case is a real difference on disk, so it is not a normalization one.
        #expect(!PathStore.equalButForUnicodeNorm("Caf\u{e9}", "caf\u{e9}"))
    }

    // MARK: - Local ↔ Dropbox paths

    @Test("A local URL under the root becomes a Dropbox path")
    func toDbxPath() async throws {
        try await withStore { store, _, _, root in
            let url = root.appendingPathComponent("Photos").appendingPathComponent("Cat.jpg")

            try #expect(store.toDbxPath(localURL: url) == "/Photos/Cat.jpg")
        }
    }

    @Test("The root itself is the empty Dropbox path, never \"/\"")
    func toDbxPathOfRoot() async throws {
        try await withStore { store, _, _, root in
            try #expect(store.toDbxPath(localURL: root) == "")
        }
    }

    @Test("A URL outside the root throws instead of producing a path")
    func toDbxPathOutsideRoot() async throws {
        try await withStore { store, _, _, root in
            let outside = root.deletingLastPathComponent().appendingPathComponent("elsewhere.txt")

            #expect(throws: PathStoreError.self) {
                try store.toDbxPath(localURL: outside)
            }
        }
    }

    @Test("A sibling directory sharing the root's name prefix is outside the root")
    func toDbxPathSiblingPrefix() async throws {
        try await withStore { store, _, _, root in
            let sibling = root.deletingLastPathComponent()
                .appendingPathComponent("DropboxOther")
                .appendingPathComponent("a.txt")

            #expect(throws: PathStoreError.self) {
                try store.toDbxPath(localURL: sibling)
            }
        }
    }

    @Test("Unnormalized local paths are still resolved against the root")
    func toDbxPathStandardizes() async throws {
        try await withStore { store, _, _, root in
            let messy = root.appendingPathComponent("Photos/../Photos/Cat.jpg")

            try #expect(store.toDbxPath(localURL: messy) == "/Photos/Cat.jpg")
        }
    }

    @Test("A decomposed local name becomes a composed Dropbox path")
    func toDbxPathComposes() async throws {
        try await withStore { store, _, _, root in
            let url = root.appendingPathComponent("caf\u{65}\u{301}.txt")

            try #expect(store.toDbxPath(localURL: url) == "/caf\u{e9}.txt")
        }
    }

    @Test("A Dropbox path becomes a local URL under the root")
    func toLocalURL() async throws {
        try await withStore { store, _, _, root in
            let expected = root.appendingPathComponent("Photos").appendingPathComponent("Cat.jpg")

            #expect(store.toLocalURL(dbxPathCased: "/Photos/Cat.jpg").path == expected.path)
        }
    }

    @Test("The empty Dropbox path is the root itself")
    func toLocalURLOfRoot() async throws {
        try await withStore { store, _, _, root in
            #expect(store.toLocalURL(dbxPathCased: "").path == root.path)
            #expect(store.toLocalURL(dbxPathCased: "/").path == root.path)
        }
    }

    @Test("Local and Dropbox paths round trip")
    func pathRoundTrip() async throws {
        try await withStore { store, _, _, _ in
            let dbxPath = "/Photos/Holiday 2024/IMG_0001.JPG"

            let url = store.toLocalURL(dbxPathCased: dbxPath)
            try #expect(store.toDbxPath(localURL: url) == dbxPath)
        }
    }

    // MARK: - Case correction

    @Test("Casing comes from the index without touching the network")
    func correctCaseFromIndex() async throws {
        try await withStore { store, service, database, _ in
            try database.upsertIndexEntry(indexEntry(lower: "/photos", cased: "/Photos"))
            try database.upsertIndexEntry(
                indexEntry(lower: "/photos/holiday", cased: "/Photos/Holiday")
            )

            let corrected = try await store.correctCase("/photos/holiday/IMG_1.JPG")

            #expect(corrected == "/Photos/Holiday/IMG_1.JPG")
            #expect(service.recordedCalls.isEmpty)
        }
    }

    @Test("An unknown parent costs one metadata call, and only one")
    func correctCaseFallsBackToMetadata() async throws {
        try await withStore { store, service, _, _ in
            service.seedFolder(at: "/Photos")

            let first = try await store.correctCase("/photos/IMG_1.JPG")
            let second = try await store.correctCase("/photos/IMG_2.JPG")

            #expect(first == "/Photos/IMG_1.JPG")
            #expect(second == "/Photos/IMG_2.JPG")
            #expect(service.recordedCalls == [.metadata])
        }
    }

    @Test("The basename's casing is taken as given, never looked up")
    func correctCaseTrustsBasename() async throws {
        try await withStore { store, service, database, _ in
            try database.upsertIndexEntry(indexEntry(lower: "/photos", cased: "/Photos"))
            // The index disagrees with the caller about the file's casing; the
            // caller is right, because `path_display` is authoritative for the
            // basename (api-notes §3).
            try database.upsertIndexEntry(
                indexEntry(lower: "/photos/img_1.jpg", cased: "/Photos/old.JPG", type: .file)
            )

            let corrected = try await store.correctCase("/photos/IMG_1.JPG")

            #expect(corrected == "/Photos/IMG_1.JPG")
            #expect(service.recordedCalls.isEmpty)
        }
    }

    @Test("A parent that exists nowhere keeps the casing it arrived with")
    func correctCaseUnknownParent() async throws {
        try await withStore { store, _, _, _ in
            let corrected = try await store.correctCase("/gone/IMG_1.JPG")

            #expect(corrected == "/gone/IMG_1.JPG")
        }
    }

    @Test("A top-level path needs no resolution at all")
    func correctCaseTopLevel() async throws {
        try await withStore { store, service, _, _ in
            try await #expect(store.correctCase("/README.md") == "/README.md")
            #expect(service.recordedCalls.isEmpty)
        }
    }

    @Test("A connection failure surfaces rather than producing a wrong path")
    func correctCasePropagatesErrors() async throws {
        try await withStore { store, service, _, _ in
            service.failNext(.metadata, with: .connection)

            await #expect(throws: DropboxServiceError.connection) {
                try await store.correctCase("/photos/IMG_1.JPG")
            }
        }
    }

    // MARK: - Case-sensitivity probe

    @Test("A temp directory on the boot volume is reported case-insensitively")
    func caseSensitivityProbe() async throws {
        try await withStore { _, _, _, root in
            // APFS is formatted case-insensitive by default on macOS, so this is
            // an assertion about the probe agreeing with the filesystem, checked
            // directly rather than assumed.
            let probe = root.appendingPathComponent("CaseProbe.tmp")
            try Data().write(to: probe)
            defer { try? FileManager.default.removeItem(at: probe) }
            let insensitive = FileManager.default.fileExists(
                atPath: root.appendingPathComponent("caseprobe.tmp").path
            )

            #expect(PathStore.isCaseSensitiveVolume(at: root) == !insensitive)
        }
    }

    @Test("The probe leaves nothing behind")
    func caseSensitivityProbeCleansUp() async throws {
        try await withStore { _, _, _, root in
            let before = try FileManager.default.contentsOfDirectory(atPath: root.path)

            _ = PathStore.isCaseSensitiveVolume(at: root)

            try #expect(FileManager.default.contentsOfDirectory(atPath: root.path) == before)
        }
    }

    // MARK: - Conflicted copies

    @Test("A conflicted copy keeps the extension and carries the suffix")
    func conflictedCopyName() async throws {
        try await withStore { _, _, _, root in
            let original = root.appendingPathComponent("report.txt")

            let copy = PathStore.conflictedCopyName(for: original, suffix: "conflicted copy 2026-08-22")

            #expect(copy.lastPathComponent == "report (conflicted copy 2026-08-22).txt")
            #expect(copy.deletingLastPathComponent().path == root.path)
        }
    }

    @Test("Only the last extension is treated as the extension")
    func conflictedCopyNameMultipleExtensions() async throws {
        try await withStore { _, _, _, root in
            let original = root.appendingPathComponent("archive.tar.gz")

            let copy = PathStore.conflictedCopyName(for: original, suffix: "copy")

            #expect(copy.lastPathComponent == "archive.tar (copy).gz")
        }
    }

    @Test("A file with no extension gets the suffix appended")
    func conflictedCopyNameNoExtension() async throws {
        try await withStore { _, _, _, root in
            let original = root.appendingPathComponent("Makefile")

            let copy = PathStore.conflictedCopyName(for: original, suffix: "copy")

            #expect(copy.lastPathComponent == "Makefile (copy)")
        }
    }

    @Test("A dotfile's leading dot is part of the name, not an extension")
    func conflictedCopyNameDotfile() async throws {
        try await withStore { _, _, _, root in
            let original = root.appendingPathComponent(".bashrc")

            let copy = PathStore.conflictedCopyName(for: original, suffix: "copy")

            #expect(copy.lastPathComponent == ".bashrc (copy)")
        }
    }

    @Test("A dotfile with an extension keeps that extension")
    func conflictedCopyNameDotfileWithExtension() async throws {
        try await withStore { _, _, _, root in
            let original = root.appendingPathComponent(".config.json")

            let copy = PathStore.conflictedCopyName(for: original, suffix: "copy")

            #expect(copy.lastPathComponent == ".config (copy).json")
        }
    }

    @Test("A folder gets the suffix appended without inventing an extension")
    func conflictedCopyNameFolder() async throws {
        try await withStore { _, _, _, root in
            let original = root.appendingPathComponent("Holiday 2024")

            let copy = PathStore.conflictedCopyName(for: original, suffix: "copy")

            #expect(copy.lastPathComponent == "Holiday 2024 (copy)")
        }
    }

    @Test("A taken name gets a counter, and a taken counter gets the next one")
    func conflictedCopyNameCollisions() async throws {
        try await withStore { _, _, _, root in
            let original = root.appendingPathComponent("report.txt")
            try Data().write(to: root.appendingPathComponent("report (copy).txt"))
            try Data().write(to: root.appendingPathComponent("report (copy) (1).txt"))

            let copy = PathStore.conflictedCopyName(for: original, suffix: "copy")

            #expect(copy.lastPathComponent == "report (copy) (2).txt")
        }
    }

    @Test("A directory occupying the name counts as taken")
    func conflictedCopyNameCollidesWithDirectory() async throws {
        try await withStore { _, _, _, root in
            let original = root.appendingPathComponent("report.txt")
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent("report (copy).txt"),
                withIntermediateDirectories: true
            )

            let copy = PathStore.conflictedCopyName(for: original, suffix: "copy")

            #expect(copy.lastPathComponent == "report (copy) (1).txt")
        }
    }
}

import Foundation
import Observation

/// The lazily loaded, tri-state folder tree the selective-sync UI draws (ux §5).
/// The model keeps one piece of state — the excluded set — and every node's
/// appearance is derived from it, so the boxes cannot drift from the selection.
@MainActor
@Observable
public final class FolderTreeModel {

    /// A checkbox's three appearances.
    public enum CheckState: Sendable, Equatable {

        /// The folder and everything under it syncs.
        case on

        /// The folder is excluded — it, or an ancestor, is in the set.
        case off

        /// The folder syncs but something beneath it does not.
        case mixed
    }

    /// One folder in the tree. A class because the view holds nodes across
    /// reloads and expansion mutates one in place; `@Observable` so expanding a
    /// branch redraws that branch rather than the whole tree.
    @MainActor
    @Observable
    public final class Node: Identifiable {

        /// The normalized Dropbox path, which is also the identity: Dropbox
        /// paths are case-insensitive, so there is exactly one node per path.
        public let dbxPathLower: String

        /// The correctly cased basename, for display.
        public let name: String

        public internal(set) var checkState: CheckState = .on

        /// `nil` until the level has been loaded — distinct from `[]`, which
        /// means a folder with no subfolders.
        public internal(set) var children: [Node]?

        public internal(set) var isLoading = false

        /// `nonisolated` so the conformance itself does not need the main actor:
        /// the path is a `let`, and SwiftUI reads ids off the main actor anyway.
        public nonisolated var id: String { dbxPathLower }

        init(dbxPathLower: String, name: String) {
            self.dbxPathLower = dbxPathLower
            self.name = name
        }
    }

    private let service: any DropboxService

    /// The selection under edit: normalized, minimal, and the single source of
    /// every node's `checkState`.
    private var excluded: Set<String>

    /// What the engine currently has, to compare against for `hasChanges`.
    private let initialExcluded: Set<String>

    public private(set) var roots: [Node] = []

    /// `true` while the top level is being fetched, for the initial spinner.
    public private(set) var isLoadingRoots = false

    /// The last listing failure, or `nil`. Shown instead of an empty tree: a
    /// Dropbox that looks empty because the network is down is an invitation to
    /// deselect everything.
    public private(set) var loadError: String?

    public init(service: any DropboxService, excluded: Set<String>) {
        let normalized = SelectiveSync.normalized(excluded)
        self.service = service
        self.excluded = normalized
        self.initialExcluded = normalized
    }

    // MARK: - Loading

    /// Fetches the top-level folders.
    public func loadRoot() async {
        guard !isLoadingRoots else { return }
        isLoadingRoots = true
        defer { isLoadingRoots = false }

        guard let folders = await folders(under: "") else { return }
        roots = folders
        refreshStates()
    }

    /// Fetches one level of subfolders, once. A whole level, not a subtree:
    /// `toggle` relies on a node's children being complete once loaded, which is
    /// what lets it push a parent's exclusion onto a re-checked child's siblings.
    public func expand(_ node: Node) async {
        guard node.children == nil, !node.isLoading else { return }
        node.isLoading = true
        defer { node.isLoading = false }

        guard let folders = await folders(under: node.dbxPathLower) else { return }
        node.children = folders
        refreshStates()
    }

    /// The direct subfolders of a path, or `nil` when the listing failed.
    private func folders(under pathLower: String) async -> [Node]? {
        do {
            // The API spells the Dropbox root `""`, never `"/"` (api-notes §2).
            var page = try await service.listFolder(path: pathLower == "/" ? "" : pathLower, recursive: false)
            var entries = page.entries
            while page.hasMore {
                page = try await service.listFolderContinue(cursor: page.cursor)
                entries.append(contentsOf: page.entries)
            }
            loadError = nil

            return
                entries
                .compactMap(\.asFolder)
                .filter { !Exclusions.isExcludedName($0.name) }
                .map { Node(dbxPathLower: PathStore.normalize($0.pathLower), name: $0.name) }
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        } catch {
            loadError = (error as? DropboxServiceError)?.errorDescription ?? error.localizedDescription
            return nil
        }
    }

    // MARK: - Selection

    /// Flips one folder, cascading to everything loaded beneath it. `mixed`
    /// counts as "not fully included", so tapping it includes rather than
    /// excludes — the direction that cannot lose a folder by accident.
    public func toggle(_ node: Node) {
        if node.checkState == .on {
            exclude(node.dbxPathLower)
        } else {
            include(node.dbxPathLower)
        }
        refreshStates()
    }

    /// The selection to hand to `SyncCoordinator.setExcluded(items:)`.
    /// Already minimal, and never contains the root.
    public func resultingExcludedSet() -> Set<String> {
        excluded
    }

    public var hasChanges: Bool {
        excluded != initialExcluded
    }

    private func exclude(_ pathLower: String) {
        // Anything beneath it is now redundant: the folder covers it.
        excluded = excluded.filter { !isAtOrUnder($0, pathLower) }
        excluded.insert(pathLower)
    }

    /// Stops excluding a path, preserving every exclusion that is not about it.
    /// An ancestor's exclusion stands for its other children too, so it is pushed
    /// down a level at a time, re-excluding each sibling off the path.
    private func include(_ pathLower: String) {
        excluded = excluded.filter { !isAtOrUnder($0, pathLower) }

        while let ancestor = excluded.first(where: { isAtOrUnder(pathLower, $0) }) {
            excluded.remove(ancestor)
            guard let children = node(at: ancestor)?.children else {
                // The level was never loaded, so there are no siblings to name.
                // Including more than asked is the recoverable direction.
                break
            }
            for child in children where !isAtOrUnder(pathLower, child.dbxPathLower) {
                excluded.insert(child.dbxPathLower)
            }
        }
    }

    // MARK: - Derived state

    /// Rewrites every loaded node's checkbox from the selection.
    private func refreshStates() {
        for root in roots { refreshStates(from: root) }
    }

    private func refreshStates(from node: Node) {
        node.checkState = state(of: node.dbxPathLower)
        for child in node.children ?? [] { refreshStates(from: child) }
    }

    private func state(of pathLower: String) -> CheckState {
        if Exclusions.isExcluded(byUser: pathLower, excluded: excluded) { return .off }
        // Not "some child is off" but "something below is off": an exclusion
        // several levels down, in a branch nobody has expanded, still has to
        // show up at the top.
        if excluded.contains(where: { isAtOrUnder($0, pathLower) }) { return .mixed }
        return .on
    }

    private func node(at pathLower: String) -> Node? {
        var pending = roots
        while let node = pending.popLast() {
            if node.dbxPathLower == pathLower { return node }
            pending.append(contentsOf: node.children ?? [])
        }
        return nil
    }

    /// Whether `path` is `ancestor` or lives inside it, on a component boundary.
    private func isAtOrUnder(_ path: String, _ ancestor: String) -> Bool {
        path == ancestor || path.hasPrefix(ancestor + "/")
    }
}

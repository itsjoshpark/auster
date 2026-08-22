# Phase 7 — Selective Sync

**Goal:** Exclude/include remote folders, engine-side semantics + the tri-state
folder tree UI component (used by Settings and later by onboarding).

**Reference:** engine-doc §8 (semantics), maestral-ux §5 (UI behavior).
**Definition of done:** excluding a synced folder removes it locally and stops
its syncing; re-including downloads it; conflicts on excluded paths handled;
tree UI drives it all.

### Task 7.1: Engine operations

**Files:** create `Coordination/SelectiveSync.swift` (logic used by
`SyncCoordinator.setExcluded(items:)`); tests `Tests/.../SelectiveSyncTests.swift`.

Behavior (engine-doc §8): computes delta vs current excluded set.
Newly excluded: normalize paths, drop entries that are children of other
excluded entries, persist set (DB `StateKey.excludedItems` + `AppConfig` mirror),
delete local copies (ignored FS ops), prune index subtrees.
Newly included: remove from set (and remove child entries), enqueue each on the
persistent pending-downloads queue; coordinator's drain task picks them up
(`fetchRemoteItem`). Root (`"/"`) may not be excluded. Download filtering + the
upload-side "(selective sync conflict)" rename already exist (Phases 4/5) and
read the same set.

- [ ] TDD: exclude removes local + index, set persisted lowercased/minimal;
  include triggers queued download (assert via pending queue + drained mock);
  nested exclude/include set algebra; scenario: exclude → remote edits under it
  ignored → include → full subtree restored converged; restart mid-include
  resumes from persisted queue. Commit.

### Task 7.2: Folder tree model + view

**Files:** create `Auster/SettingsUI/SelectiveSyncTree.swift` (view) and
`AusterCore/Sources/AusterCore/State/FolderTreeModel.swift` (logic, UI-free);
tests `Tests/.../FolderTreeModelTests.swift`.

**Interfaces produced:**

```swift
@MainActor @Observable public final class FolderTreeModel {
    public enum CheckState { case on, off, mixed }     // ux §5 tri-state rules
    public final class Node: Identifiable { public let dbxPathLower: String; public let name: String
        public internal(set) var checkState: CheckState
        public internal(set) var children: [Node]?      // nil = not loaded yet
        public internal(set) var isLoading: Bool }
    public init(service: DropboxService, excluded: Set<String>)
    public private(set) var roots: [Node]
    public func loadRoot() async; public func expand(_ node: Node) async  // lazy listFolder(recursive:false), folders only
    public func toggle(_ node: Node)                    // cascades down; recomputes ancestors to mixed
    public func resultingExcludedSet() -> Set<String>   // minimal set (no redundant children)
    public var hasChanges: Bool { get }
}
```

- [ ] TDD model with mock service: initial states derive from excluded set
  (off / mixed ancestors); toggle cascades + ancestor recompute; unloaded
  children inherit parent state on load; `resultingExcludedSet` minimal; root
  not excludable (toggling all roots off still yields per-root entries, never "/").
- [ ] View: `List`/`OutlineGroup`-style tree with checkbox images
  (`checkmark.square.fill` / `square` / `minus.square.fill`), lazy expansion
  spinner, Apply + Revert buttons calling
  `coordinator.setExcluded(items: model.resultingExcludedSet())`. Manual check
  against live account. Commit.

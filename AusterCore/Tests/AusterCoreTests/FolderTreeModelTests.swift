import Foundation
import Testing

@testable import AusterCore

/// The tri-state folder tree behind selective sync (ux §5). The model is the
/// whole behaviour: what the user sees is the selection the engine would act on,
/// and an unexpanded level is not assumed empty.
@MainActor
@Suite("Folder tree model")
struct FolderTreeModelTests {

    private func service(_ folders: [String]) -> MockDropboxService {
        let service = MockDropboxService()
        for folder in folders { service.seedFolder(at: folder) }
        return service
    }

    // MARK: - Loading

    @Test("the root lists top-level folders, in order, and only folders")
    func rootListsFolders() async throws {
        let service = service(["/Photos", "/Docs", "/Docs/Tax"])
        try service.seedFile(at: "/loose.txt", contents: "x")
        let model = FolderTreeModel(service: service, excluded: [])

        await model.loadRoot()

        #expect(model.roots.map(\.name) == ["Docs", "Photos"])
        #expect(model.roots.allSatisfy { $0.children == nil })
    }

    @Test("expanding a node loads its direct subfolders once")
    func expandingLoadsChildren() async throws {
        let service = service(["/Docs", "/Docs/Tax", "/Docs/Tax/2024", "/Photos"])
        let model = FolderTreeModel(service: service, excluded: [])
        await model.loadRoot()
        let docs = try #require(model.roots.first { $0.name == "Docs" })

        await model.expand(docs)

        #expect(docs.children?.map(\.name) == ["Tax"])
        #expect(docs.isLoading == false)

        // A second expansion is a no-op: the level is already complete.
        let before = service.recordedCalls.filter { $0 == .listFolder }.count
        await model.expand(docs)
        #expect(service.recordedCalls.filter { $0 == .listFolder }.count == before)
    }

    // MARK: - Initial state

    @Test("initial states come from the excluded set, with mixed ancestors")
    func initialStatesDeriveFromExclusions() async throws {
        let service = service(["/Docs", "/Docs/Tax", "/Docs/Notes", "/Photos"])
        let model = FolderTreeModel(service: service, excluded: ["/photos", "/docs/tax"])
        await model.loadRoot()

        let docs = try #require(model.roots.first { $0.name == "Docs" })
        let photos = try #require(model.roots.first { $0.name == "Photos" })
        #expect(docs.checkState == .mixed)
        #expect(photos.checkState == .off)

        await model.expand(docs)
        #expect(docs.children?.first { $0.name == "Tax" }?.checkState == .off)
        #expect(docs.children?.first { $0.name == "Notes" }?.checkState == .on)
        #expect(model.hasChanges == false)
    }

    /// A folder nobody has expanded has no children to give a state to, so the
    /// state has to arrive with them.
    @Test("children loaded under an excluded parent inherit its state")
    func unloadedChildrenInheritOnLoad() async throws {
        let service = service(["/Photos", "/Photos/2024", "/Photos/2025"])
        let model = FolderTreeModel(service: service, excluded: ["/photos"])
        await model.loadRoot()
        let photos = try #require(model.roots.first)

        await model.expand(photos)

        #expect(photos.children?.allSatisfy { $0.checkState == .off } == true)
    }

    // MARK: - Toggling

    @Test("unchecking a folder cascades down and leaves its ancestors mixed")
    func toggleCascadesAndRecomputesAncestors() async throws {
        let service = service(["/Docs", "/Docs/Tax", "/Docs/Tax/2024", "/Docs/Notes"])
        let model = FolderTreeModel(service: service, excluded: [])
        await model.loadRoot()
        let docs = try #require(model.roots.first)
        await model.expand(docs)
        let tax = try #require(docs.children?.first { $0.name == "Tax" })
        await model.expand(tax)

        model.toggle(tax)

        #expect(tax.checkState == .off)
        #expect(tax.children?.allSatisfy { $0.checkState == .off } == true)
        #expect(docs.checkState == .mixed)
        #expect(model.resultingExcludedSet() == ["/docs/tax"])
        #expect(model.hasChanges)
    }

    /// The awkward direction: re-checking one child of an excluded parent has to
    /// keep the parent's *other* children excluded, which is only possible
    /// because expanding a level loads all of it.
    @Test("re-checking a child of an excluded parent pushes the exclusion down to its siblings")
    func includingOneChildKeepsSiblingsExcluded() async throws {
        let service = service(["/Photos", "/Photos/2024", "/Photos/2025", "/Photos/Raw"])
        let model = FolderTreeModel(service: service, excluded: ["/photos"])
        await model.loadRoot()
        let photos = try #require(model.roots.first)
        await model.expand(photos)
        let recent = try #require(photos.children?.first { $0.name == "2025" })

        model.toggle(recent)

        #expect(recent.checkState == .on)
        #expect(photos.checkState == .mixed)
        #expect(model.resultingExcludedSet() == ["/photos/2024", "/photos/raw"])
    }

    @Test("re-checking a folder clears every exclusion beneath it")
    func includingAParentClearsDescendants() async throws {
        let service = service(["/Docs", "/Docs/Tax", "/Docs/Notes"])
        let model = FolderTreeModel(service: service, excluded: ["/docs/tax", "/docs/notes"])
        await model.loadRoot()
        let docs = try #require(model.roots.first)
        #expect(docs.checkState == .mixed)

        model.toggle(docs)

        #expect(docs.checkState == .on)
        #expect(model.resultingExcludedSet().isEmpty)
    }

    /// A mixed box includes rather than excludes, like every other tri-state
    /// checkbox — and the direction that cannot drop a folder by accident.
    @Test("excluding a parent replaces the exclusions beneath it with one entry")
    func resultingSetIsMinimal() async throws {
        let service = service(["/Docs", "/Docs/Tax", "/Docs/Notes"])
        let model = FolderTreeModel(service: service, excluded: ["/docs/tax"])
        await model.loadRoot()
        let docs = try #require(model.roots.first)
        await model.expand(docs)
        #expect(docs.checkState == .mixed)

        model.toggle(docs)
        #expect(docs.checkState == .on)

        model.toggle(docs)

        #expect(docs.checkState == .off)
        #expect(docs.children?.allSatisfy { $0.checkState == .off } == true)
        #expect(model.resultingExcludedSet() == ["/docs"])
    }

    /// Excluding everything is allowed; excluding the account is not (ux §5).
    @Test("unchecking every top-level folder yields one entry each, never the root")
    func rootIsNeverExcludable() async throws {
        let service = service(["/Docs", "/Photos"])
        let model = FolderTreeModel(service: service, excluded: [])
        await model.loadRoot()

        for root in model.roots { model.toggle(root) }

        #expect(model.resultingExcludedSet() == ["/docs", "/photos"])
    }

    // MARK: - Failure

    @Test("a listing that fails is reported rather than shown as an empty Dropbox")
    func loadFailureIsReported() async throws {
        let service = service(["/Docs"])
        service.failNext(.listFolder, with: .connection)
        let model = FolderTreeModel(service: service, excluded: [])

        await model.loadRoot()

        #expect(model.roots.isEmpty)
        #expect(model.loadError != nil)
    }
}

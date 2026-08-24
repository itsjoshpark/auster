import Foundation
import Testing

@testable import AusterCore

/// The setup wizard's state machine (ux §3). Two transitions are irreversible in
/// opposite directions: finishing writes the folder the engine treats as theirs,
/// cancelling throws away credentials that took a browser round trip.
@MainActor
@Suite("Onboarding model")
struct OnboardingModelTests {

    // MARK: - Doubles

    /// A link store that authorizes on demand, so the wizard can be walked
    /// without a browser.
    private final class FakeLinkStore: DropboxLinkStore {
        var result: AuthorizationResult = .authorized
        let mock = MockDropboxService()
        var storedService: MockDropboxService?
        private(set) var clearCount = 0
        private(set) var beganAuthorization = false

        var hasStoredCredentials: Bool { storedService != nil }
        func makeService() -> (any DropboxService)? { storedService }
        func beginAuthorization(scopes: [String]) { beganAuthorization = true }

        func completeAuthorization(url: URL) async -> AuthorizationResult {
            if case .authorized = result { storedService = mock }
            return result
        }

        func clearCredentials() {
            clearCount += 1
            storedService = nil
        }
    }

    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [(URL, Set<String>)] = []

        var finishes: [(URL, Set<String>)] { lock.withLock { storage } }
        func record(_ folder: URL, _ excluded: Set<String>) {
            lock.withLock { storage.append((folder, excluded)) }
        }
    }

    private let redirect = URL(string: "db-appkey://2/token?code=abc")!

    private func fixture(
        team: Bool = false
    ) -> (OnboardingModel, FakeLinkStore, AuthManager, Recorder, URL) {
        let store = FakeLinkStore()
        store.mock.account = AccountInfo(
            accountId: "dbid:josh",
            displayName: "Josh Park",
            email: "josh@example.com",
            accountType: "pro",
            isTeam: team,
            profilePhotoURL: nil
        )
        let auth = AuthManager(store: store)
        let recorder = Recorder()
        let home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("auster-onboarding-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)

        let model = OnboardingModel(
            auth: auth,
            defaultLocation: home,
            onFinish: { folder, excluded in recorder.record(folder, excluded) }
        )
        return (model, store, auth, recorder, home)
    }

    // MARK: - Linking

    @Test("the wizard starts on welcome and opens the browser to link")
    func welcomeStartsTheLink() {
        let (model, store, _, _, _) = fixture()
        #expect(model.page == .welcome)

        model.beginLink()

        #expect(model.page == .link)
        #expect(model.linkState == .waiting)
        #expect(store.beganAuthorization)
    }

    @Test("a successful link moves on to choosing a folder")
    func linkingAdvancesToFolder() async {
        let (model, _, auth, _, _) = fixture()
        model.beginLink()

        model.handle(await auth.handleRedirect(url: redirect))

        #expect(model.page == .folder)
        #expect(model.linkState == .idle)
        #expect(model.accountName == "Josh Park")
    }

    /// Exact copy from decisions D4 — never "not yet supported".
    @Test("a team account is refused with the copy the decision fixes")
    func teamAccountsAreRefused() async {
        let (model, _, auth, _, _) = fixture(team: true)
        model.beginLink()

        model.handle(await auth.handleRedirect(url: redirect))

        #expect(model.page == .link)
        #expect(
            model.linkState
                == .failed("Not supported: Auster does not support Dropbox team accounts.")
        )
    }

    @Test("a failed link offers another try rather than moving on")
    func failedLinkStaysPut() {
        let (model, store, _, _, _) = fixture()
        store.result = .failed("Dropbox said no.")
        model.beginLink()

        model.handle(.failed("Dropbox said no."))
        #expect(model.page == .link)
        #expect(model.linkState == .failed("Dropbox said no."))

        model.beginLink()
        #expect(model.linkState == .waiting)
    }

    /// Backing out of the browser is not a failure worth an error page.
    @Test("a cancelled authorization returns to the welcome page")
    func cancellingReturnsToWelcome() {
        let (model, _, _, _, _) = fixture()
        model.beginLink()

        model.handle(.cancelled)

        #expect(model.page == .welcome)
        #expect(model.linkState == .idle)
    }

    // MARK: - Choosing a folder

    @Test("the proposed folder is a Dropbox folder inside the chosen location")
    func proposedFolderIsInsideTheChosenLocation() {
        let (model, _, _, _, home) = fixture()

        #expect(model.folderURL == home.appendingPathComponent("Dropbox"))
        #expect(model.proposedFolder(in: home.appendingPathComponent("Elsewhere")).lastPathComponent == "Dropbox")
    }

    @Test("a missing or empty target needs no confirmation")
    func emptyTargetIsReady() throws {
        let (model, _, _, _, home) = fixture()
        let empty = home.appendingPathComponent("Empty")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)

        #expect(model.decision(for: home.appendingPathComponent("Missing")) == .ready)
        #expect(model.decision(for: empty) == .ready)
    }

    /// Merging is safe — the engine compares content hashes, so nothing
    /// identical is transferred — but it is still the user's call (ux §3.3).
    @Test("an existing folder with files in it has to be confirmed as a merge")
    func nonEmptyTargetNeedsConfirmation() throws {
        let (model, _, _, _, home) = fixture()
        let occupied = home.appendingPathComponent("Occupied")
        try FileManager.default.createDirectory(at: occupied, withIntermediateDirectories: true)
        try Data("hello".utf8).write(to: occupied.appendingPathComponent("a.txt"))

        #expect(model.decision(for: occupied) == .needsMergeConfirmation)
    }

    @Test("confirming a folder advances to selective sync and remembers it")
    func confirmingAdvances() async {
        let (model, _, auth, _, home) = fixture()
        model.beginLink()
        model.handle(await auth.handleRedirect(url: redirect))
        let chosen = home.appendingPathComponent("Dropbox")

        model.confirmFolder(chosen)

        #expect(model.page == .selective)
        #expect(model.folderURL == chosen)
    }

    /// The escape hatch of ux §3.3: the credentials go with the wizard, so a
    /// user who changes their mind is not left half-linked.
    @Test("cancelling from the folder page unlinks and returns to welcome")
    func cancellingUnlinks() async {
        let (model, store, auth, _, _) = fixture()
        model.beginLink()
        model.handle(await auth.handleRedirect(url: redirect))
        #expect(model.page == .folder)

        await model.cancelAndUnlink()

        #expect(model.page == .welcome)
        #expect(store.clearCount == 1)
        #expect(auth.isLinked == false)
    }

    // MARK: - Selective sync and finishing

    @Test("going back from selective sync returns to the folder page")
    func backFromSelective() async {
        let (model, _, auth, _, home) = fixture()
        model.beginLink()
        model.handle(await auth.handleRedirect(url: redirect))
        model.confirmFolder(home.appendingPathComponent("Dropbox"))

        model.back()

        #expect(model.page == .folder)
    }

    /// Nothing is applied until the last page: the selection is carried and
    /// handed over with the folder, so an abandoned wizard changes nothing.
    @Test("the selection is carried to the done page and applied on finish")
    func selectionIsAppliedOnFinish() async {
        let (model, _, auth, recorder, home) = fixture()
        model.beginLink()
        model.handle(await auth.handleRedirect(url: redirect))
        let chosen = home.appendingPathComponent("Dropbox")
        model.confirmFolder(chosen)

        model.confirmSelection(["/photos"])
        #expect(model.page == .done)
        #expect(recorder.finishes.isEmpty)

        await model.finish()

        #expect(recorder.finishes.count == 1)
        #expect(recorder.finishes[0].0 == chosen)
        #expect(recorder.finishes[0].1 == ["/photos"])
    }

    @Test("finishing twice starts sync once")
    func finishIsIdempotent() async {
        let (model, _, auth, recorder, home) = fixture()
        model.beginLink()
        model.handle(await auth.handleRedirect(url: redirect))
        model.confirmFolder(home.appendingPathComponent("Dropbox"))
        model.confirmSelection([])

        await model.finish()
        await model.finish()

        #expect(recorder.finishes.count == 1)
    }
}

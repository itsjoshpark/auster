import Foundation
import Observation

/// The setup wizard, as a state machine (ux §3).
///
/// UI-free for the usual reason — `AusterCore` never imports SwiftUI — but also
/// because of what the wizard *is*: the sequence in which Auster acquires the
/// two things it cannot work without, an account and a folder. Getting the order
/// wrong strands the user half-linked, and that is worth being able to test
/// without a browser or a window.
///
/// Nothing the wizard collects is applied until the last page. The folder and
/// the selective-sync choice are carried in memory and handed over together, so
/// a wizard the user abandons leaves no trace beyond credentials they can unlink.
@MainActor
@Observable
public final class OnboardingModel {

    /// The five pages of ux §3.
    public enum Page: Equatable, Sendable {
        case welcome
        case link
        case folder
        case selective
        case done
    }

    /// What the link page is showing.
    public enum LinkState: Equatable, Sendable {

        /// Nothing in flight.
        case idle

        /// The browser is open and the redirect has not come back yet.
        case waiting

        /// Something to read and try again from — including a team account,
        /// which is a permanent refusal rather than a retryable failure
        /// (decisions D4).
        case failed(String)
    }

    /// Whether a chosen folder can be used as-is.
    public enum FolderDecision: Equatable, Sendable {

        /// Nothing is there, or nothing that matters.
        case ready

        /// Files are already in it. Merging is safe — the engine compares
        /// content hashes, so nothing identical is ever transferred — but it is
        /// the user's decision to make (ux §3.3).
        case needsMergeConfirmation
    }

    public private(set) var page: Page = .welcome
    public private(set) var linkState: LinkState = .idle

    /// Where the Dropbox folder will go. Starts as `~/Dropbox` (decisions D3).
    public private(set) var folderURL: URL

    /// The selection made on the selective-sync page, applied on `finish()`.
    public private(set) var excludedItems: Set<String> = []

    private let auth: AuthManager?
    private let onFinish: (URL, Set<String>) async -> Void
    private var hasFinished = false

    /// - Parameters:
    ///   - auth: the link manager, or `nil` in a build with no app key — the
    ///     wizard then shows its pages but cannot get past the first.
    ///   - defaultLocation: where the proposed Dropbox folder is created.
    ///   - onFinish: persists the folder and the selection, and starts sync.
    public init(
        auth: AuthManager?,
        defaultLocation: URL = FileManager.default.homeDirectoryForCurrentUser,
        onFinish: @escaping (URL, Set<String>) async -> Void
    ) {
        self.auth = auth
        self.onFinish = onFinish
        self.folderURL = Self.folder(in: defaultLocation)
    }

    /// The account's display name, once the link has produced one.
    public var accountName: String? { auth?.account?.displayName }

    public var accountEmail: String? { auth?.account?.email }

    /// Whether linking is possible at all (decisions N6: a build with no app key
    /// cannot).
    public var canLink: Bool { auth != nil }

    // MARK: - Linking (ux §3.2)

    /// Opens the browser. The answer arrives at `handle(_:)`.
    public func beginLink() {
        page = .link
        linkState = .waiting
        auth?.beginLink()
    }

    /// Consumes the outcome of an OAuth redirect.
    public func handle(_ outcome: LinkOutcome) {
        switch outcome {
        case .linked:
            linkState = .idle
            page = .folder

        case .cancelled:
            // Backing out of the browser is not an error worth a page of its own.
            linkState = .idle
            page = .welcome

        case .teamAccountNotSupported:
            // Exact copy from decisions D4 — never "not yet supported".
            linkState = .failed("Not supported: Auster does not support Dropbox team accounts.")

        case .failed(let message):
            linkState = .failed(message)
        }
    }

    // MARK: - The folder (ux §3.3)

    /// The folder Auster would create inside a location the user picked.
    public func proposedFolder(in location: URL) -> URL {
        Self.folder(in: location)
    }

    /// Whether `url` can be adopted without asking anything further.
    ///
    /// "Empty" ignores the names that never sync — a `.DS_Store` Finder left
    /// behind is not a reason to ask the user about merging (engine-doc §8).
    public func decision(for url: URL) -> FolderDecision {
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
        let meaningful = contents.filter { !Exclusions.isExcludedName($0) }
        return meaningful.isEmpty ? .ready : .needsMergeConfirmation
    }

    /// Adopts a folder and moves on. Merging, when it applies, has already been
    /// agreed to: it needs nothing special here, because the engine's
    /// content-hash comparison is what makes a merge correct.
    public func confirmFolder(_ url: URL) {
        folderURL = url
        page = .selective
    }

    /// Leaves the wizard with nothing kept: the credentials go too, so the user
    /// is not left linked to an account they decided against (ux §3.3).
    public func cancelAndUnlink() async {
        await auth?.unlink()
        excludedItems = []
        linkState = .idle
        page = .welcome
    }

    // MARK: - Selective sync and finishing (ux §3.4, §3.5)

    /// Records the tree's selection and moves to the last page. Nothing is
    /// applied yet.
    public func confirmSelection(_ excluded: Set<String>) {
        excludedItems = excluded
        page = .done
    }

    /// One step back, wherever that means something.
    public func back() {
        switch page {
        case .selective: page = .folder
        case .folder, .link: page = .welcome
        case .welcome, .done: break
        }
    }

    /// Writes the choices down and starts sync.
    ///
    /// Guarded because the done page's button is the one users double-click:
    /// starting the engine twice would build a second object graph over the same
    /// database.
    public func finish() async {
        guard !hasFinished else { return }
        hasFinished = true
        await onFinish(folderURL, excludedItems)
    }

    private static func folder(in location: URL) -> URL {
        // Lexical, never statted: the folder may not exist yet, and a URL that
        // changes shape once it does would not compare equal to itself
        // (implementation note N16).
        location.appendingPathComponent("Dropbox", isDirectory: false)
    }
}

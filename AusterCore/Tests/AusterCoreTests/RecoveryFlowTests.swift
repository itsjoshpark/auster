import Foundation
import Testing

@testable import AusterCore

/// What Auster offers when sync has stopped, and what each answer does
/// (engine-doc §9, ux §9). The order of "adopt the folder, then rebuild" is a
/// correctness property, not a UI detail.
@Suite("Recovery flows")
struct RecoveryFlowTests {

    private let configured = URL(fileURLWithPath: "/Users/josh/Dropbox")

    // MARK: - What each fatal error offers

    /// A missing folder is never a mass deletion. It is a question, and the
    /// three answers are the only ones that cannot lose data.
    @Test("a missing folder asks the user where it went")
    func folderMissingAsks() {
        #expect(RecoveryModel.presentation(for: .dropboxFolderMissing) == .folderMissingDialog)
    }

    /// A revoked token cannot be fixed by a dialog — only by a browser — so the
    /// menu carries the invitation rather than a modal interrupting whatever the
    /// user was doing.
    @Test("a revoked token asks for a re-link from the menu")
    func notAuthorizedPromptsRelink() {
        #expect(RecoveryModel.presentation(for: .notAuthorized) == .relinkPrompt)
    }

    /// The index is not data: everything in it can be recomputed, so the right
    /// move is to get on with it rather than to ask permission (engine-doc §9).
    @Test("a corrupted database rebuilds itself without asking")
    func databaseCorruptionRebuildsSilently() {
        #expect(RecoveryModel.presentation(for: .databaseCorrupted) == .automaticReindex)
    }

    @Test("anything unrecognised is reported rather than acted on")
    func unexpectedErrorsAreReported() {
        #expect(RecoveryModel.presentation(for: .unexpected("disk on fire")) == .message("disk on fire"))
    }

    // MARK: - The folder-missing answers

    /// Adopting a folder full of the user's files is safe only because the
    /// rebuild follows it: identical files are skipped on content hash, and
    /// differing ones become conflicted copies rather than overwrites.
    @Test("locating a folder adopts it and then rebuilds the index")
    func locateAdoptsThenRebuilds() {
        let picked = URL(fileURLWithPath: "/Volumes/External/Dropbox")

        let plan = RecoveryModel.plan(for: .locate(picked), configuredFolder: configured)

        #expect(plan == [.adoptFolder(picked), .rebuildIndex])
    }

    @Test("recreating makes an empty folder at the configured path and rebuilds")
    func recreateMakesTheFolderThenRebuilds() {
        let plan = RecoveryModel.plan(for: .recreate, configuredFolder: configured)

        #expect(plan == [.createFolder(configured), .rebuildIndex])
    }

    /// Order matters both ways round: rebuilding before the folder exists would
    /// hit the same missing-folder guard that raised the dialog.
    @Test("every folder-missing plan puts the folder back before rebuilding")
    func theFolderAlwaysComesFirst() {
        for choice in [RecoveryModel.FolderMissingChoice.locate(configured), .recreate] {
            let plan = RecoveryModel.plan(for: choice, configuredFolder: configured)
            let rebuildAt = plan.firstIndex(of: .rebuildIndex)
            #expect(rebuildAt == plan.count - 1, "rebuild is not last in \(plan)")
            #expect(plan.count == 2)
        }
    }

    @Test("quitting does exactly that and nothing else")
    func quitDoesNothingElse() {
        #expect(RecoveryModel.plan(for: .quit, configuredFolder: configured) == [.quit])
    }

    // MARK: - Single instance (ux §9)

    @Test("a second launch defers to the instance already running")
    func secondInstanceDefers() {
        #expect(SingleInstance.decision(otherProcessIdentifiers: [4321], current: 1234) == .deferToExisting(4321))
    }

    @Test("the only instance carries on")
    func firstInstanceProceeds() {
        #expect(SingleInstance.decision(otherProcessIdentifiers: [], current: 1234) == .proceed)
    }

    /// The running-applications list includes us, and mistaking ourselves for a
    /// rival would make Auster impossible to launch at all.
    @Test("seeing only ourselves is not seeing another instance")
    func ownProcessIsNotARival() {
        #expect(SingleInstance.decision(otherProcessIdentifiers: [1234], current: 1234) == .proceed)
    }

    /// Whichever instance started first is the one that keeps running, so two
    /// simultaneous launches cannot both stand aside.
    @Test("the oldest instance is the one deferred to")
    func theOldestInstanceWins() {
        #expect(
            SingleInstance.decision(otherProcessIdentifiers: [9000, 4321, 7000], current: 1234)
                == .deferToExisting(4321)
        )
    }
}

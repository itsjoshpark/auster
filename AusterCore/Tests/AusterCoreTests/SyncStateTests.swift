import Foundation
import Testing

@testable import AusterCore

/// The one object the UI reads (design §2). The precedence between its facts is
/// the substance: a paused client that also cannot reach Dropbox says "Paused",
/// because that is what the user did and can undo.
@Suite("SyncState")
@MainActor
struct SyncStateTests {

    private func linked() -> SyncState {
        let state = SyncState()
        state.setAccount(
            AccountInfo(
                accountId: "dbid:1",
                displayName: "Ada",
                email: "ada@example.com",
                accountType: "basic",
                isTeam: false,
                profilePhotoURL: nil
            )
        )
        return state
    }

    private func event(_ path: String, direction: SyncDirection = .down, size: Int64 = 100) -> SyncItemEvent {
        SyncItemEvent(
            direction: direction,
            changeType: .added,
            itemType: .file,
            dbxPath: path,
            dbxPathLower: PathStore.normalize(path),
            localURL: URL(fileURLWithPath: "/Dropbox\(path)"),
            size: size
        )
    }

    // MARK: - Status precedence

    @Test("A fresh state needs setting up")
    func startsNeedingSetup() {
        #expect(SyncState().status == .needsSetup)
    }

    @Test("An account with nothing happening is idle")
    func linkedAndQuietIsIdle() {
        #expect(linked().status == .idle)
    }

    /// Nothing else is meaningful without an account, so this outranks
    /// everything — including a fatal error, which re-linking would clear.
    @Test("Needing setup outranks everything else")
    func needsSetupWins() {
        let state = SyncState()
        state.setFatalError(.dropboxFolderMissing)
        state.setPaused(true)

        #expect(state.status == .needsSetup)
    }

    @Test("A fatal error outranks a pause")
    func fatalErrorBeatsPaused() {
        let state = linked()
        state.setPaused(true)
        state.setFatalError(.dropboxFolderMissing)

        #expect(state.status == .fatalError(.dropboxFolderMissing))
    }

    /// The user's own pause is a deliberate act, and saying "Connecting…" while
    /// they are paused would suggest Auster is about to start again.
    @Test("A pause outranks syncing and connecting")
    func pausedBeatsSyncingAndConnecting() {
        let state = linked()
        state.setConnected(false)
        state.setSyncing(detail: "Syncing…")
        state.setPaused(true)

        #expect(state.status == .paused)
    }

    @Test("Syncing outranks connecting")
    func syncingBeatsConnecting() {
        let state = linked()
        state.setConnected(false)
        state.setSyncing(detail: "Indexing 12…")

        #expect(state.status == .syncing(detail: "Indexing 12…"))
    }

    @Test("Losing the connection shows as connecting, not as an error")
    func disconnectedIsConnecting() {
        let state = linked()
        state.setConnected(false)

        #expect(state.status == .connecting)
    }

    @Test("Finishing a sync returns to idle")
    func syncingEndsAtIdle() {
        let state = linked()
        state.setSyncing(detail: "Syncing…")
        state.setIdle()

        #expect(state.status == .idle)
    }

    @Test("Clearing a fatal error restores the state underneath it")
    func fatalErrorCanBeCleared() {
        let state = linked()
        state.setPaused(true)
        state.setFatalError(.notAuthorized)
        state.clearFatalError()

        #expect(state.status == .paused)
    }

    @Test("Unlinking returns to needing setup")
    func unlinkingNeedsSetup() {
        let state = linked()
        state.setLinked(false)

        #expect(state.status == .needsSetup)
        #expect(state.account == nil)
    }

    /// A linked account that cannot be reached has no profile yet. Treating that
    /// as "not linked" would send the user back through the setup wizard every
    /// time they opened their laptop on a train.
    @Test("Being linked without a fetched profile is not needing setup")
    func linkedButOfflineIsNotSetup() {
        let state = SyncState()
        state.setLinked(true)
        state.setConnected(false)

        #expect(state.status == .connecting)
    }

    // MARK: - Activity

    @Test("A started item appears in the activity list")
    func startingAnItemAddsActivity() {
        let state = linked()
        state.itemStarted(event("/report.txt", size: 500))

        #expect(state.activity.count == 1)
        #expect(state.activity.first?.dbxPath == "/report.txt")
        #expect(state.activity.first?.total == 500)
        #expect(state.activity.first?.completed == 0)
    }

    @Test("Progress updates the item already in the list")
    func progressUpdatesInPlace() {
        let state = linked()
        state.itemStarted(event("/report.txt", size: 500))
        state.itemProgress(event("/report.txt", size: 500), completed: 250)

        #expect(state.activity.count == 1)
        #expect(state.activity.first?.completed == 250)
    }

    /// Progress can arrive for an item whose start was never seen — the ad-hoc
    /// fetch path does not announce itself — and dropping it would leave the
    /// transfer invisible.
    @Test("Progress for an unknown item starts tracking it")
    func progressWithoutAStartIsTracked() {
        let state = linked()
        state.itemProgress(event("/report.txt", size: 500), completed: 100)

        #expect(state.activity.first?.completed == 100)
    }

    @Test("A completed item leaves the activity list")
    func completingAnItemRemovesActivity() {
        let state = linked()
        state.itemStarted(event("/a.txt"))
        state.itemStarted(event("/b.txt"))
        state.itemCompleted(event("/a.txt"))

        #expect(state.activity.map(\.dbxPath) == ["/b.txt"])
    }

    @Test("Items are tracked by normalized path, so one item is one row")
    func activityIsKeyedByNormalizedPath() {
        let state = linked()
        state.itemStarted(event("/Report.txt"))
        state.itemStarted(event("/report.txt"))

        #expect(state.activity.count == 1)
    }

    @Test("Both directions are tracked separately from each other's paths")
    func activityRecordsDirection() {
        let state = linked()
        state.itemStarted(event("/down.txt", direction: .down))
        state.itemStarted(event("/up.txt", direction: .up))

        #expect(state.activity.first { $0.dbxPath == "/up.txt" }?.direction == .up)
    }

    @Test("Clearing activity empties the list")
    func activityCanBeCleared() {
        let state = linked()
        state.itemStarted(event("/a.txt"))
        state.clearActivity()

        #expect(state.activity.isEmpty)
    }

    // MARK: - Usage

    @Test("Usage reads as a percentage of the allocation")
    func usageText() {
        let state = linked()
        state.setUsage(SpaceUsage(used: 246_000_000_000, allocated: 2_000_000_000_000))

        #expect(state.usageText.contains("12.3%"))
        #expect(state.usageText.hasSuffix("used"))
    }

    @Test("Unknown usage reads as unknown rather than as zero")
    func unknownUsage() {
        let state = linked()
        state.setUsage(nil)

        #expect(!state.usageText.contains("%"))
    }

    /// Dropbox reports an unlimited allocation as zero, and "100% used" would be
    /// alarming and wrong.
    @Test("An unlimited allocation does not read as full")
    func unlimitedAllocation() {
        let state = linked()
        state.setUsage(SpaceUsage(used: 5_000_000, allocated: 0))

        #expect(!state.usageText.contains("100"))
    }

    // MARK: - Lists

    @Test("Recent changes and sync issues are handed through")
    func listsArePassedThrough() {
        let state = linked()
        state.setRecentChanges([
            HistoryEntry(
                direction: .down,
                changeType: .added,
                itemType: .file,
                dbxPath: "/a.txt",
                size: 1,
                timestamp: Date()
            )
        ])
        state.setSyncErrors([
            SyncErrorEntry(
                dbxPathLower: "/b.txt",
                dbxPath: "/b.txt",
                direction: .up,
                title: "Could not upload file",
                message: "Your Dropbox is full."
            )
        ])

        #expect(state.recentChanges.count == 1)
        #expect(state.syncErrors.count == 1)
    }
}

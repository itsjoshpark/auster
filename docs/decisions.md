# Auster — Decisions Log

Decisions made with Josh (2026-08-22) during planning. Each records the choice,
alternatives considered, and rationale. Implementation should not relitigate these
without checking in.

## D1. Sync model: Maestral-style folder sync (not File Provider)
A real local folder (default `~/Dropbox`, user-choosable) kept in two-way sync by
our own engine: FSEvents for local changes, Dropbox longpoll/delta for remote
changes; all included files always on disk.
**Rejected:** `NSFileProviderReplicatedExtension` (Finder-integrated, on-demand
materialization) — revisited and re-rejected 2026-08-22. Reasons: files would be
forced into the system-managed `~/Library/CloudStorage/` domain (no user-chosen
plain `~/Dropbox` folder — the core product promise); it only replaces the local
half of the engine while making conflict handling fit a constrained system model;
and extension debugging against the opaque `fileproviderd` daemon is
interactive-debugging-shaped and untestable headless. The FSEvents engine is
deterministic and fully testable in a temp directory.

## D2. Distribution: direct download, Developer ID + notarization, Sparkle updates
No App Sandbox (a free-form sync folder + full-disk file access make sandboxing
painful and App Store distribution impractical). Updates via Sparkle. Signing/
notarization is set up at the end of development; not a blocker during it.

## D3. Dropbox app: Full Dropbox access type
Already configured in Josh's Dropbox developer console entry. Scopes:
`account_info.read`, `files.metadata.read`, `files.content.read`,
`files.content.write`. OAuth 2 **PKCE** (no client secret in the app). App key is
provided by Josh and injected via a gitignored `Secrets.xcconfig`; ask him for it
when implementation reaches auth.

## D4. v1 scope
**In:** core two-way sync, onboarding wizard with browser OAuth, menu bar UI,
Settings window, selective sync, desktop notifications + recent-activity list,
sync-issues list, pause/resume, start-at-login, rebuild index.
**Out of scope — permanently (per Josh, 2026-08-22):** bandwidth/rate limits,
multiple accounts, `.mignore` ignore files, CLI, Dropbox **team/business**
accounts (team spaces, path-root migration). These will never be implemented; do
not design abstractions or leave hooks for them. Auster targets personal accounts
only — detect team accounts at link time and show "**Not supported**" (not "not
yet supported"). Batch API calls remain a possible future optimization.

## D5. Target: macOS 15+, SwiftUI, Swift 6 strict concurrency
Frees `MenuBarExtra`, `Settings` scene, `@Observable`, mature structured
concurrency. Xcode 26+ (Icon Composer `.icon` app-icon support; deployment
target remains macOS 15 — Icon Composer exports fallback renderings for
pre-Tahoe systems).

## D6. Architecture: single app, layered core (no daemon/GUI split)
One menu-bar app embedding the engine as a local Swift Package **AusterCore** with
zero UI dependencies (fully testable headless). Maestral's daemon+XPC split existed
because of Python and its CLI; login-item autostart gives us the "always running"
property without IPC. **Rejected:** launchd daemon + XPC; embedding Python
Maestral.

## D7. Dependencies
- **SwiftyDropbox** (official Dropbox Swift SDK, SPM) — auth/PKCE, generated
  routes, token refresh, keychain storage. Actively maintained (auto-generated spec
  updates, July 2026).
- **GRDB** — SQLite index/state database.
- **Sparkle** — app updates.
Nothing else unless a phase proves a need.

## D8. Docs are the contract; implementer works Maestral-free
The implementing model (Claude Opus 5) gets **only the Auster repo**. Everything
learned from Maestral's source is captured in `docs/research/*`; `docs/PLAN.md`
(master plan) is the single entry point. If implementation finds a gap in these
docs, it should note the gap in the docs and make a reasonable decision consistent
with the sync-engine reference's safety principles (never lose user data; prefer
conflicted copies over overwrites; skip rather than guess).

## D9. Engine safety principles (non-negotiable)
1. Never delete or overwrite local or remote data whose latest state we haven't
   accounted for — when in doubt, create a conflicted copy or skip.
2. All local mutations by the engine go through the FS-event ignore mechanism.
3. Downloads are staged to a cache dir on the same volume and moved atomically.
4. Index/cursor writes happen only after the corresponding change is applied.
5. Remote deletes of files always use `parentRev` guards.

## Implementation notes

Decisions made during implementation where the plan and research docs were
silent. These record *what was chosen and why*, not new policy — anything that
contradicts D1–D9 above is a bug.

### N1. Xcode project is hand-written, with synchronized folder groups (Phase 1)
`xcodegen` was not installed and the plan allowed generating project files
directly. `Auster.xcodeproj/project.pbxproj` is checked in and uses
`PBXFileSystemSynchronizedRootGroup` for `Auster/` and `AusterTests/`: Xcode
derives target membership from the file system, so later phases add sources
without editing the project. Consequences: no extra build-tool dependency, and
`Auster/Resources/Info.plist` needs an explicit membership exception so it is
not also copied in as a resource.

### N2. An `AusterTests` app-target test bundle exists (Phase 1)
Phase 1 did not list one, but the CI workflow it specifies runs
`xcodebuild ... test` against the `Auster` scheme, which needs a testable. The
bundle is host-based (`TEST_HOST` = `Auster.app`) and currently holds one
placeholder test; Phase 8's view-model tests belong here. The engine's coverage
stays in `AusterCoreTests`.

### N3. Swift Testing, not XCTest
Both test targets use the `Testing` framework (`@Suite`/`@Test`/`#expect`). It
is built into the toolchain, runs under both `swift test` and `xcodebuild test`,
and its parallel-by-default execution suits the actor-based engine.

### N4. `DropboxClientsManager.authorizedClient` is not Swift 6 concurrency-safe
SwiftyDropbox 10.2.4 exposes it as a plain mutable class property, so touching
it from `AusterCore` fails to compile under language mode 6. Phase 2's
`DropboxService` must own the client behind its own isolation rather than
reading that global from arbitrary contexts.

### N5. `AuthManager` stays in `AusterCore`; only presentation is injected (Phase 2)
The plan puts `AuthManager` in `AusterCore` and has it call
`DropboxClientsManager.authorizeFromControllerV2`, but that route is
`#if os(macOS)` + `import AppKit` and takes an `NSApplication` — which
`AusterCore` may not touch. Two consequences:

- `AusterCore` defines `AuthorizationPresenter` (open a URL, show an error);
  the app target implements it with `NSWorkspace`/`NSAlert`. An internal
  `SharedApplicationBridge` adapts it to SwiftyDropbox's AppKit-free
  `SharedApplication` protocol, which is what the SDK actually drives the flow
  through.
- `KeychainDropboxLinkStore` owns its own `DropboxOAuthManager` instance
  (public init, same keychain storage) rather than going through
  `DropboxClientsManager`, whose `authorizedClient` global Swift 6 refuses to
  read (N4 — confirmed: it is an error, not a warning, even from `@MainActor`).
  Clients are built with
  `DropboxClient(accessToken:dropboxOauthManager:)`, so token refresh still
  comes for free.

`AuthManager`'s public interface is unchanged from the phase file; the store is
a constructor dependency, which is also what makes the link outcomes testable
without a browser.

### N6. The OAuth redirect arrives via the app delegate, not `.onOpenURL` (Phase 2)
The phase file specifies `.onOpenURL`. That modifier needs a view on screen,
and a menu-bar-only app's `MenuBarExtra` window is built lazily when the user
clicks the icon — precisely when the redirect is *not* on screen. Auster uses
`@NSApplicationDelegateAdaptor` with `application(_:open:)` instead, which is
always live. A missing app key is reported by the same delegate with a modal
alert and then terminates the app, as the phase file requires.

### N7. Downloads are hash-verified after the SDK writes them (Phase 2)
The plan describes feeding `ContentHasher.Streaming` as bytes arrive.
SwiftyDropbox's file download owns the write itself (temp file → destination
move) and exposes only a `Progress` callback, so there is no byte stream to
intercept. `LiveDropboxService` therefore hashes the written file and compares
it to the metadata's `contentHash`, deleting the file and throwing
`.dataCorrupted` on a mismatch. Same guarantee — nothing corrupt is ever staged
for the atomic move (D9.3) — at the cost of one extra read.

### N8. `SyncDatabase.wasResetOnOpen` is a `let`, not `private(set) var` (Phase 3)
The phase file spells it `public private(set) var`. Swift 6 refuses mutable
stored state on a `Sendable` class, and the flag is only ever assigned during
`init`, so it is a `let`. No call site changes.

### N9. `PathStore`'s case cache is a shared reference, not per-copy (Phase 3)
`PathStore` is a `Sendable` struct as the phase file specifies, but
`correctCase` needs the ~5000-entry cache from engine-doc §9. A cache stored
inline would be copied with the struct, so every value passed to a worker would
start cold and re-issue `metadata` calls. The cache is therefore a small
`Mutex`-guarded `final class CaseCache` held by reference, so all copies share
one. Eviction is oldest-insertion-first rather than true LRU: the entries are
folder casings, which are cheap to re-derive.

### N10. `AppConfig` has non-mutating setters and mirrors, not owns, the exclusions (Phase 3)
Two consequences of it being a `UserDefaults` façade rather than a stored model:

- Setters are `nonmutating`, so two `AppConfig` values over the same suite can
  never disagree. The struct is `@unchecked Sendable` because `UserDefaults` is
  documented thread-safe but not annotated `Sendable`.
- `excludedItems` here is a *mirror*. The database (`StateKey.excludedItems`) is
  the source of truth, and Phase 7's selective-sync operation writes both — so
  `AppConfig` takes no database dependency, and the engine never reads the UI's
  copy.

### N11. Dates are stored as Unix timestamps, not GRDB's default date strings (Phase 3)
GRDB encodes `Date` as `"YYYY-MM-DD HH:MM:SS.SSS"` text. The engine compares
`last_sync` and the hash cache's `mtime` against `stat` timestamps, where the
sub-second part is what decides whether a file counts as changed, so the record
types in `Database/Records.swift` store `Double` columns and convert at the
boundary. This is also why the public model types stay free of GRDB: the
internal record structs own the column names and the on-disk representation.


### N12. Phase 4's tasks were committed in dependency order (Phase 4)
The phase file orders the tasks 4.1 → 4.6, but 4.2's `ConflictResolver` tests
need both `Exclusions` (4.4, for the names that never count as unsynced
changes) and `SyncFatalError` (4.3). The commits therefore run
4.1 → 4.4 → 4.3 → 4.2 → 4.5 → 4.6. `Engine/SyncEngine.swift` is created in 4.6
rather than 4.2 for the same reason: nothing exercises it until the download
cycle exists, and an untested stub would have been dead code.
`SyncEngineEvents`/`SyncCompletion` live in their own
`Engine/SyncEngineEvents.swift` because `DownloadApplier` needs them a task
earlier than the engine does. No interface from the phase file changed.

### N13. `MockDropboxService` gained content hashes, symlinks, and case renames (Phase 4)
Three behavioural gaps that made real engine rules untestable, all fixed in the
direction of what Dropbox actually does:

- Files now carry a computed `content_hash`. It was `nil`, which made §4.4's
  "identical content already on disk" rule unreachable — the rule that stops a
  first index re-downloading a folder the user already has.
- `seedSymlink(at:target:)` exists, since a symlink is file metadata carrying
  `symlink_info` and there was no way to produce one.
- `move` accepts a rename that only changes case. It previously rejected one as
  a collision, because source and destination share a lookup key.

Also `seedFile` takes a `clientModified:`, and `reversesListingOrder` emits each
page back to front — Dropbox promises only that a page applied *in order*
reproduces server state, not that parents precede children, so the engine's own
depth ordering (§4.3) is what has to guarantee it.

### N14. Always-excluded names are matched case-insensitively (Phase 4)
Engine-doc §8 gives the list as "case-sensitive where meaningful" and spells two
entries twice (`Thumbs.db`/`thumbs.db`, `.DS_Store`/`.ds_store`). Auster matches
the whole list case-insensitively instead: Dropbox paths are case-insensitive,
so `Desktop.ini` and `desktop.ini` are one file, and a rule catching only one
spelling would sync the other. Matching also applies to *every* component of a
path, not just the basename, so nothing inside `.dropbox.cache` or
`.auster.cache` is ever queued.

### N15. Selective-sync retraction writes the database, not the config mirror (Phase 4)
§8 says a remote deletion of an excluded item removes it from the exclusion
list. The engine writes `StateKey.excludedItems` directly, consistent with N10
(the database is the source of truth, `AppConfig` mirrors it). The engine's
`excludedItems` closure stays read-only; Phase 7 owns keeping the UI's mirror in
step.

### N16. URLs are built lexically, never by statting the path (Phase 5)
`URL.appendingPathComponent(_:)` and `FileManager.contentsOfDirectory(at:)`
consult the filesystem: the first appends a trailing slash for an existing
directory, the second resolves every symlink (`/private/var/…` where the engine
says `/var/…`). Both make the URL for an item depend on whether it exists yet,
so the URL `PathStore` derives and the URL the watcher reports for the same file
compare unequal — and the FS-event ignore filter, the catch-up scan and the
index all compare exactly those. Three consequences:

- `PathStore.toLocalURL`, `LocalFileMonitor` and `DirectoryListing` (new) all
  join with `isDirectory: false` and never resolve symlinks.
- `LocalFileMonitor` keeps two spellings of its root: the configured one it
  reports in, and a `realpath(3)` one to match FSEvents. `resolvingSymlinksInPath()`
  cannot be used — it strips the `/private` prefix FSEvents always includes.
- `IgnoreFilter` compares path components rather than `URL` values.

### N17. One `ignoring` call declares alternative descriptions of one event (Phase 5)
Engine-doc §5.2 says the filter drops the first matching event per registration.
That is not enough on its own: `atomicMoveIntoPlace` cannot know in advance
whether `rename(2)` will surface as a rename of the staged file, a creation of
the destination, or a modification of it, so it declares all three — and the two
that do not arrive would sit for the full 2 s TTL, swallowing the user's next
edit to that file. Matching any declaration therefore retires the others from
the same call. An operation that genuinely causes two events (`createSymlink`
replacing an existing link) makes two calls.

### N18. `LocalFileMonitor` filters excluded names itself (Phase 5)
The staging directory lives *inside* the watched folder, so every download
writes, stamps and renames a file in there. Filtering `Exclusions.isExcludedName`
at the watcher rather than in the upload cycle keeps that traffic — and
`.DS_Store` churn — out of the queue entirely. A move is judged by its
destination, so a file arriving out of excluded space is still reported.

### N19. Upload-session chunking cannot be asserted at the `DropboxService` seam (Phase 5)
Phase 5 Task 5.5 asks the 12 MiB scenario to "assert session path with 4 MiB
chunks". `DropboxService.upload` deliberately hides whether a transfer used one
call or a session — that choice lives in `LiveDropboxService` (built in Phase 2),
and `MockDropboxService` has no seam for it. The scenario therefore asserts what
this layer can be held to: a 12 MiB file round-trips with its content hash
intact. The chunking itself belongs to the Phase 9 integration tests, against
the real API.

### N20. `MockDropboxService` records the arguments the engine chose (Phase 5)
`recordedUploads` (path, write mode, `client_modified`), `recordedDeletes`
(path, `parentRev`), `recordedMoves` and `recordedFolderCreations`. The write
mode and the revision guard *are* the safety argument for the upload direction
(D9.1, D9.5), and ordering — deletions before creations, parents before children
— is the correctness argument for a batch (§5.5); neither is observable from the
resulting remote state alone. `reversesListingOrder` exists for the same reason
on the download side.

### N21. `SyncState` tracks "is linked" separately from the fetched account (Phase 6)
The phase file's `SyncState` has `account: AccountInfo?` and a `.needsSetup`
status, which invites treating a missing account as "not linked". It is not: the
profile can only be fetched online, so a linked user opening their laptop on a
train would have been sent back through the setup wizard. `setLinked(_:)` is the
input `.needsSetup` derives from — it comes from the keychain, which works
offline — and `setAccount(_:)` only supplies the profile for display.

### N22. `SyncEventCollector` breaks the engine/coordinator construction cycle (Phase 6)
Notifications are batched per download cycle (engine-doc §10), so something must
accumulate completed items and hand them over when the cycle ends. The engine
cannot: its callbacks are fire-and-forget and it does not own cycle boundaries
relative to the user's attention. The coordinator can, but it is built *after*
the engine, which needs its callbacks at init. `SyncEventCollector` is the shared
box both sides hold, and `SyncCoordinator.engineEvents(state:monitor:database:
pathStore:collector:)` is the static factory that ties the knot. Consequently
`SyncCoordinator.init` takes `collector:` in addition to the phase file's list,
plus optional `connection:` and `tuning:`.

### N23. Loop timings are injectable, and every loop has a floor (Phase 6)
`SyncCoordinator.Tuning` carries the longpoll timeout, the post-change settle,
the upload debounce and the reconnect backoff, so tests do not wait out real
ones. It also carries a `loopFloor` applied to every iteration: real longpolling
blocks for a minute or more, but a mock — or a server answering instantly —
would otherwise turn the loop into a spin.

### N24. Selective-sync exclusions get real accessors on `SyncDatabase` (Phase 6)
`excludedItems()` / `setExcludedItems(_:)` replace ad-hoc JSON decoding that had
started to appear in two places. A malformed stored value reads as "nothing
excluded", which syncs more than intended rather than less — the recoverable way
round.

### N25. `ConnectionMonitor` is an accelerator, not a source of truth (Phase 6)
The coordinator learns it is offline from the engine's own `.connection`
failures and recovers by retrying, so `NWPathMonitor` is not load-bearing; what
it adds is knowing the moment Wi-Fi returns rather than at the end of the next
backoff. It sits behind `ConnectionMonitoring` and is `nil` in tests, which is
why none of the lifecycle tests depend on real network state.

### N26. Selective sync splits into pure algebra and an engine-side application (Phase 7)
The phase file puts the logic in `Coordination/SelectiveSync.swift`. It ended up
in two pieces, because the two halves fail differently: `SelectiveSync` is total,
pure set arithmetic (normalize → minimal set → delta of newly excluded / newly
included), while the half that touches the user's files —
`SyncEngine.removeExcluded(dbxPathLower:)` — lives on the engine actor. Local
deletion and index pruning mutate exactly what a sync cycle mutates, so they have
to share its isolation; doing them from the coordinator would let a cycle
interleave with them. `SyncCoordinator.setExcluded(items:)` orders the three
steps: persist the selection first (so an interruption leaves the engine
filtering by what the user asked for), then apply exclusions, then *queue*
inclusions before fetching any of them.

### N27. A mixed checkbox includes; every node's state is derived, never stored (Phase 7)
Two rules that together keep the tree honest:

- `FolderTreeModel` stores only the excluded set. `checkState` is recomputed for
  every loaded node whenever that set changes, so what the user sees and what
  `resultingExcludedSet()` would hand the engine cannot drift apart. A parent
  whose loaded children are all excluded therefore reads `.mixed`, not `.off` —
  the state the same selection would produce if it were reloaded from scratch,
  and honest about the parent's own files still syncing.
- Toggling a `.mixed` box includes rather than excludes. Re-including a folder
  whose *ancestor* is excluded pushes that exclusion one level down, re-excluding
  each sibling not on the path — which works only because `expand` loads a
  complete level at a time. Where a level was never loaded the exclusion is
  simply dropped: syncing more than asked is the recoverable direction.

### N28. The setup wizard is an AppKit window, not a SwiftUI `Window` scene (Phase 8)
A `Window` scene can only be opened through `openWindow`, which lives in a
view's environment — and a menu-bar app has no view on screen until its icon is
clicked, which is precisely the click a user with nothing set up has no reason to
make. `OnboardingWindowController` builds an `NSWindow` around an
`NSHostingView` instead, so the wizard can be on screen at launch. Closing it
without finishing quits, as ux §3 requires; the last page closes it through a
callback so that path does not. The Sync Issues window stays a SwiftUI `Window`
scene, because it is only ever opened from the menu, which *is* a view.

### N29. `LinkController` is gone; `AppEnvironment` owns the link and `AppSettings` mirrors the config (Phase 8)
Phase 2's `LinkController` existed to drive the debug UI and said so. Its job —
holding the `AuthManager` and routing OAuth redirects — is now `AppEnvironment`'s,
which also builds itself from the bundle's app key (`AppEnvironment.fromBundle()`).
Alongside it, `AppSettings` is a small `@Observable` mirror of the handful of
`AppConfig` values the interface binds to: `AppConfig` is a `UserDefaults` façade
and therefore invisible to SwiftUI, so a settings toggle over it would never
redraw anything. Every property writes straight back, so the defaults stay the
storage. The selective-sync exclusions deliberately stay out of it (N10).

### N30. `SyncIssuesWindow` was built in Task 8.1 rather than 8.4 (Phase 8)
The menu's "Show Sync Issues (N)…" row needs somewhere to open, and a row wired
to a window that does not exist yet is not a commit that works. The window reads
only `state.syncErrors`, so nothing about it needed Task 8.4's notification
machinery. `LoginItem` moved earlier for the same reason: the unlinked menu's
"Start on Login" toggle is part of ux §2.

### N31. Batched notifications count authors by account id, not by resolved name (Phase 8)
`NotificationComposer` resolves an author's display name from a cache, and
returns "Someone" when it has none. Deciding whether a batch has one author by
comparing *names* would collapse two unknown people into one and announce
"Someone changed 2 files"; it compares account ids instead, and only resolves a
name once there is exactly one to resolve. An unattributed change is "You" —
Dropbox reports an author only inside shared folders, and everywhere else nobody
but the account holder can write.

### N32. A local filesystem failure is a per-path sync issue, not a fatal error (Phase 9)
`SyncEngine.record` caught only `DropboxServiceError`, so anything the local
filesystem refused — a folder the user made read-only, a name the volume would
not take, a disk that filled between two files — escaped the per-item handler,
aborted the whole cycle, and reached the coordinator's funnel as
`SyncFatalError.unexpected`. One unwritable folder therefore stopped all syncing.
It now catches everything except `SyncFatalError` and `CancellationError`, and
records the rest as a sync issue for that path, which is what design §5 says a
per-path failure is. Found by Task 9.3's disk-full test.

### N33. Symlinks are a download-direction feature only (Phase 9)
Task 9.3 asks for a "symlink round-trip local→remote→second-client". There is no
such round trip to test: `files/upload` cannot create a symlink, so a link the
user makes locally goes up as its target's *content*, and `MockDropboxService`
models exactly that. The two tests written instead are the two real behaviours —
a symlink already in Dropbox (which is how one gets there) arriving at a fresh
client as a symlink rather than as content, and a local symlink uploading once
and not looping on the next pass.

### N34. Making a file read-only reads as an unsynced local change (Phase 9)
`chmod` bumps a file's ctime, which is the same signal an edit gives, so a
read-only file with a pending remote update is set aside as a conflicted copy
rather than replaced (engine-doc §4.4 rule 5). That is the safe outcome and the
one Task 9.3's test asserts: the protected file survives untouched, with its
permission bits, and the remote version lands beside it. The
`preservePermissions` path of `atomicMoveIntoPlace` still applies to updates with
no local change, and is covered in `LocalFileOperationsTests`.

### N35. The integration suite is opt-in twice, and skipped in CI (Phase 9)
`AusterCoreIntegrationTests` runs only when `AUSTER_INTEGRATION=1` *and* a
credential is present (`AUSTER_TEST_TOKEN`, or `AUSTER_TEST_REFRESH_TOKEN` with
`AUSTER_APP_KEY`); otherwise every test reports as skipped with the reason. The
phase file also offers reading the app's keychain entry, which is not used: a
`swift test` process has a different bundle identity, so whether it can read
those items is a property of keychain ACLs rather than of anything Auster
controls, and a credential in the environment is the same secret with none of
that ambiguity. `Scripts/test.sh` and the CI workflow both pass
`--skip IntegrationTests`, so the network round trips are never paid for by
accident.

### N36. The release scripts version `Config/Shared.xcconfig`, not `project.pbxproj` (Phase 10)
The phase file has `project-version.sh` reading and writing `project.pbxproj`,
which is where FrontRow keeps its versions. Auster's have lived in
`Config/Shared.xcconfig` since Phase 1 — every configuration of every target uses
it as its base configuration — and `project.pbxproj` does not mention them at
all. The script keeps its name and its commands and takes the xcconfig instead.
One consequence: an xcconfig defines each setting once, where a pbxproj carries
one per configuration, so the script insists on exactly one definition rather
than two. A second definition would silently win over the first, which is a
reason to stop rather than something to rewrite.

### N37. The release build takes the Dropbox app key from a repository secret (Phase 10)
`Config/Secrets.xcconfig` is gitignored, so a CI checkout has no app key, and an
Auster built without one puts up "Missing Dropbox app key" and quits — it would
have been a release nobody could use. The release workflow writes the key from a
`DROPBOX_APP_KEY` repository secret into `Config/Secrets.xcconfig` before the
archive. The ordinary CI build deliberately does *not*: nothing it does needs a
real key, and `AppShellTests` already skips the one test that would.

### N38. Sparkle's updater is started by hand, so an unusable one is a state and not an alert (Phase 10)
`SPUStandardUpdaterController(startingUpdater: true)` answers a failed start with
an alert at launch. Starting fails for ordinary reasons — an unsigned local
build, the placeholder public key that ships until Josh generates the real pair —
and none of them are worth interrupting the user over. `UpdaterManager` starts
the updater itself, and a failure simply leaves `canCheckForUpdates` false, which
is the state the update controls were written for in Phase 8: an app installed by
something other than Sparkle has no updater either. The type was renamed from
Phase 8's `UpdaterController` to keep it distinct from Sparkle's own
`SPUStandardUpdaterController`.

### N39. The mock refuses to list a path that is not a folder (Phase 9 follow-up)
The first run of the integration suite against a real account failed two tests,
and both failures were in the *test doubles*, not the engine:

- `MockDropboxService.listFolder` answered a listing of a folder that does not
  exist with an empty page. Dropbox answers `path/not_found`, and
  `path/not_folder` when a file occupies the path (mapped to `.conflict` by
  `DropboxErrorMapper`). "No entries under this prefix" and "no such folder" are
  different facts, and an engine only ever tested against the lenient answer
  never meets the strict one. The mock now checks the root exists and is a
  folder; the Dropbox root (`""`) is exempt, since it exists even on an empty
  account.
- `IntegrationScope.upload` sent `autorename: false`, but `UploadApplier` sends
  `autorename: true` on every upload it makes. That is the whole difference
  between Dropbox *refusing* a stale-rev write and Dropbox writing a conflicted
  copy beside the original, so the test guarding D9.1 — the no-lost-update
  guarantee — was exercising a call the engine never issues. Confirmed against
  the live API: `update(staleRev)` + `autorename: false` → `path/conflict/file`;
  the same write with `autorename: true` → `name (… conflicted copy).ext`. The
  engine's behaviour was correct throughout; only the harness was wrong.

`IntegrationScope.make()` also replaces `init()` at the call sites, so each
scope's remote folder exists before a test lists it — Dropbox creates parents
implicitly on upload, which is why the gap went unnoticed.

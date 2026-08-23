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

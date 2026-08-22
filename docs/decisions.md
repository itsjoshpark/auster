# Auster — Decisions Log

Decisions made with Josh (2026-08-22) during planning. Each records the choice,
alternatives considered, and rationale. Implementation should not relitigate these
without checking in.

## D1. Sync model: Maestral-style folder sync (not File Provider)
A real local folder (default `~/Dropbox`, user-choosable) kept in two-way sync by
our own engine: FSEvents for local changes, Dropbox longpoll/delta for remote
changes; all included files always on disk.
**Rejected:** `NSFileProviderReplicatedExtension` (Finder-integrated, on-demand
materialization). Reasons: much harder API and debugging story, diverges from
Maestral's UX, and full-local files are the product goal.

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
**Deferred (v2+):** bandwidth/rate limits, multiple accounts, `.mignore` ignore
files, CLI, Dropbox **team/business** namespace handling (team spaces, path-root
migration — v1 targets personal accounts; detect team accounts at link time and
show "not yet supported"), batch API optimizations.

## D5. Target: macOS 15+, SwiftUI, Swift 6 strict concurrency
Frees `MenuBarExtra`, `Settings` scene, `@Observable`, mature structured
concurrency. Xcode 16+.

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

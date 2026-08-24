# CLAUDE.md

Auster is a macOS menu-bar Dropbox sync client (SwiftUI, Swift 6, macOS 15+).

## Start here

**`docs/PLAN.md` is the entry point.** Read it first — it gives the reading
order (design → decisions → research docs), the global constraints, and the
10-phase implementation plan in `docs/plan/`. Work phases in order; check off
`- [ ]` boxes in the phase files as you go and commit them with the code.

The docs are self-contained: the sync-engine algorithms, Dropbox API notes,
and the UX spec are all captured in `docs/research/` — everything you need is
in this repo.

## Hard rules

- `docs/decisions.md` is settled — do not relitigate. D4 lists features that
  are **permanently** out of scope: build no hooks for them. D9's engine safety
  principles are non-negotiable (no data loss; conflicted copies over
  overwrites; ignore-wrapped local mutations; atomic downloads; guarded deletes).
- `AusterCore` never imports AppKit/SwiftUI; the app target contains no sync
  logic.
- Dependencies: SwiftyDropbox, GRDB, Sparkle only. Anything else: ask Josh.
- TDD: failing test first, then code, then commit. Swift 6 language mode with
  zero concurrency warnings.
- **Conventional Commits** for every commit message AND every PR title
  (`feat:`, `fix:`, `docs:`, `chore:`, `test:`, `refactor:`). Imperative mood,
  no attribution footers.
- Never commit secrets. The Dropbox app key lives in gitignored
  `Config/Secrets.xcconfig` — ask Josh for the key when Phase 2 needs it.

## Building & testing

```sh
# AusterCore's tests, then an ad-hoc-signed build of the app. This is the
# command to run locally.
Scripts/test.sh

# The app target's own tests (Swift Testing, hosted in Auster.app).
xcodebuild test -project Auster.xcodeproj -scheme Auster -destination "platform=macOS" CODE_SIGN_IDENTITY="-"

# The integration suite, which talks to a real Dropbox account. Opt-in twice:
# the flag says the caller means it, the credential says they have somewhere to
# run it. Without both, every test reports as skipped.
AUSTER_INTEGRATION=1 AUSTER_TEST_REFRESH_TOKEN=… AUSTER_APP_KEY=… Scripts/test.sh

# Build only.
Scripts/build.sh [Debug|Release]

# Lint — CI runs this and Scripts/test.sh does not, so run it before a PR.
swift-format lint -s -p -r ./

# Auto-fix formatting.
swift-format format -p -r -i ./
```

## Code

Where these overlap the hard rules above, the hard rules win.

- Group source files by feature, not by layer. A feature folder holds its
  models and its views together. A feature that outgrows one folder splits by
  kind into `Models/`, `Views/`, and any domain subfolder it needs; small
  features stay flat.
- All shared data should use `@Observable` classes with `@State` (for ownership)
  and `@Bindable` / `@Environment` (for passing).
- Strongly prefer not to use `ObservableObject`, `@Published`, `@StateObject`,
  `@ObservedObject`, or `@EnvironmentObject` unless they are unavoidable, or if
  they exist in legacy/integration contexts where changing architecture would be
  complicated.
- Assume strict Swift concurrency rules are being applied.
- Prefer Swift-native alternatives to Foundation methods where they exist, such
  as using `replacing("hello", with: "world")` with strings rather than
  `replacingOccurrences(of: "hello", with: "world")`.
- Prefer modern Foundation API, for example `URL.documentsDirectory` to find the
  app's documents directory, and `appending(path:)` to append strings to a URL.
- Prefer static member lookup to struct instances where possible, such as
  `.circle` rather than `Circle()`, and `.borderedProminent` rather than
  `BorderedProminentButtonStyle()`.
- New code should use modern Swift concurrency rather than old-style Grand
  Central Dispatch — prefer `Task { @MainActor in }` or actor isolation to
  `DispatchQueue.main.async()`. Leave working GCD code alone; some APIs only
  take a queue, and the replacements differ in delivery semantics.
- Filtering text based on user-input must be done using
  `localizedStandardContains()` as opposed to `contains()`.
- User-facing text takes curly quotation marks and the curly apostrophe —
  `“…”` and `’`, never `"` or `'`. A file name sitting in a sentence goes in
  quotation marks, the way AppKit's own alerts write one; each translation uses
  the marks its language writes.
- Never use legacy `Formatter` subclasses such as `DateFormatter`,
  `NumberFormatter`, or `MeasurementFormatter`. Always use the modern
  `FormatStyle` API instead. For example, to format a date, use
  `myDate.formatted(date: .abbreviated, time: .shortened)`. To parse a date from
  a string, use `Date(inputString, strategy: .iso8601)`. For numbers, use
  `myNumber.formatted(.number)` or custom format styles.
- Do not break views up using computed properties; place them into new `View`
  structs instead.
- Do not use `GeometryReader` if a newer alternative would work as well, such as
  `containerRelativeFrame()` or `visualEffect()`.
- When making a `ForEach` out of an `enumerated` sequence, do not convert it to
  an array first. So, prefer `ForEach(x.enumerated(), id: \.element.id)` instead
  of `ForEach(Array(x.enumerated()), id: \.element.id)`.
- Place view logic into view models or similar, so it can be tested.
- Avoid `AnyView` unless it is absolutely required.
- Name a Swift file after the primary type inside it. That file may also hold
  the subviews and helpers that exist to serve that type, whatever their size —
  a screen and the rows, cards and labels only it builds belong together.
- Split a type out when something that never touches the file's primary type
  depends on it. That is the test, not line count.
- Name a screen `…View`, its `@Observable` state `…Model` on the same stem
  (`InspectorView` / `MediaInspectorModel`), and a component inside a screen for
  the role it plays — `Row`, `Card`, `Button`, `Menu`, `Picker`, `Label`, `Grid`,
  `Sheet`, `Alert`. Reach for `…View` on a component only when no role noun fits.
- A `ViewModifier` is named `…Modifier` and lives in the file with the
  `extension View` convenience that applies it.

## Comments

Applies to every file — Swift, YAML, shell, config.

- 1-3 short lines, only when the code cannot say it itself.
- Describe the code as it is. Not what it used to be, what was tried, or why an
  alternative was rejected — that belongs in the commit message.
- No syntax narration, no obvious mechanics, no references to PRs or people.

## When to ask Josh

The app key (Phase 2), anything needing his Dropbox account interactively,
signing/appcast credentials (Phase 10), and scope changes. Everything else:
proceed autonomously, and record any genuinely new decision in
`docs/decisions.md` under "Implementation notes".

## Xcode MCP

Xcode 26.3+ has a built-in MCP server (`xcrun mcpbridge`). If registered in
this session, its tools can drive Xcode directly (builds, tests, issues,
running the app) — but only while Josh has `Auster.xcodeproj` open in a
running Xcode. Prefer the CLI loop (`Scripts/test.sh`, `xcodebuild`) as the
default; use Xcode MCP when live build issues or running the app would help,
and ask Josh to open the project if it isn't. It cannot exist before Phase 1
creates the project.

## Checking SwiftyDropbox APIs

Never guess SDK signatures. After package resolution, the exact pinned
SwiftyDropbox source is in the build's SPM checkout
(`SourcePackages/checkouts/SwiftyDropbox` in DerivedData, or
`AusterCore/.build/checkouts/SwiftyDropbox`) — read it to verify route
methods, parameter labels, enum cases, and error types. Before resolution, a
reference clone may exist at
`/Users/josh/Developer/maestral-project/SwiftyDropbox` (tracks master, may be
newer than the pin — prefer the resolved checkout when both exist).
`docs/research/dropbox-api-notes.md` remains authoritative for *behavior*
(write modes, longpoll timing, retries); the SDK source is for exact API
shapes.

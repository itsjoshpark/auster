# Phase 1 — Project Scaffolding & Menu Bar Shell

**Goal:** A building, running menu-bar app skeleton with the `AusterCore` package,
all dependencies resolved, and a test target that runs.

**Prereqs:** none. **Definition of done:** `xcodebuild build` and
`swift test` (in AusterCore) succeed; launching the app shows an Auster icon in
the menu bar with a placeholder window.

### Task 1.1: Repository & AusterCore package

**Files:** create `AusterCore/Package.swift`,
`AusterCore/Sources/AusterCore/AusterCore.swift` (placeholder type),
`AusterCore/Tests/AusterCoreTests/SmokeTests.swift`.

- [x] Package manifest: swift-tools 6.0, platform `.macOS(.v15)`, library product
  `AusterCore`; dependencies `https://github.com/dropbox/SwiftyDropbox` (latest
  release major) and `https://github.com/groue/GRDB.swift` (latest release major).
  Enable strict concurrency (`SwiftSetting.enableUpcomingFeature` not needed on
  tools 6 — language mode 6 is the default).
- [x] Smoke test: `import AusterCore; import SwiftyDropbox; import GRDB` and assert
  a trivial fact, so dependency resolution is exercised by CI-style `swift test`.
- [x] `swift test` passes. Commit.

### Task 1.2: App target

**Files:** create `Auster.xcodeproj` (via `xcodegen` if available, otherwise
generate project files directly), `Auster/AusterApp.swift`,
`Auster/Resources/Info.plist`, `Auster/Resources/Assets.xcassets`,
`Config/Shared.xcconfig`, `Config/Secrets.xcconfig.template`; modify `.gitignore`
(add `Config/Secrets.xcconfig`).

**Interfaces produced:** `@main struct AusterApp: App` containing a
`MenuBarExtra("Auster", systemImage: "checkmark.circle")` (window style) showing a
placeholder `Text("Auster")`, and an empty `Settings` scene.

- [x] Info.plist: `LSUIElement = YES`; `CFBundleURLTypes` registering scheme
  `db-$(DROPBOX_APP_KEY)`; app links AusterCore local package.
- [x] `Secrets.xcconfig.template` documents `DROPBOX_APP_KEY = <ask Josh>`;
  `Shared.xcconfig` includes it optionally (`#include? "Secrets.xcconfig"`). Build
  must succeed without the real key (auth phases need it at runtime only).
- [x] App icon: **copy** `design/AppIcon/AppIcon.icon` into the app target
  (e.g., `Auster/AppIcon.icon`) and set it as the app icon in the target
  settings (Xcode 26 consumes `.icon` directly). `design/` is reference-only —
  the build must never reference files inside it. Ask Josh to open the copy
  once in Icon Composer to visually verify and re-save — not a blocker for
  this phase.
- [x] Build and launch; menu bar icon appears; no Dock icon. Commit.

### Task 1.3: Build/test scripts

**Files:** create `Scripts/build.sh`, `Scripts/test.sh`; modify `README.md`
(replace the placeholder "Building" section with real instructions: scripts,
where the app key goes).

- [x] `test.sh` runs `swift test --package-path AusterCore` then
  `xcodebuild -project Auster.xcodeproj -scheme Auster build`. Both scripts pass.
  Commit.

### Task 1.4: CI workflow

**Files:** create `.github/workflows/ci.yml`, `.swift-format`.

Modeled on Josh's FrontRow project (reference copy may exist locally at
`/Users/josh/Developer/FrontRow/.github/workflows/ci.yml`; this task is
self-contained regardless).

- [x] `.swift-format`: repo formatting config (defaults + 4-space indent,
  120-column line length). All committed Swift must pass
  `swift-format lint -s -p -r ./` from here on.
- [x] `ci.yml`: on push to `main` + all PRs; single job on `macos-26`:
  1. checkout; `maxim-lobanov/setup-xcode@v1` with `xcode-version: latest-stable`
  2. `brew install swift-format`
  3. lint: `swift-format lint -s -p -r ./`
  4. AusterCore: `swift test --package-path AusterCore`
  5. app: `xcodebuild clean analyze test -project Auster.xcodeproj -scheme
     Auster -destination "platform=macOS" -resultBundlePath
     TestResults.xcresult CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=YES
     CODE_SIGNING_ALLOWED=YES`
  6. on failure: print failed test names/locations by walking
     `xcrun xcresulttool get test-results tests --path TestResults.xcresult
     --compact` JSON (test-case → failure-message nodes with file:line), and
     upload `TestResults.xcresult` as an artifact.
- [ ] Push a branch to verify the workflow passes on GitHub before merging.
  Commit.

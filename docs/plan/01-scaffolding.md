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

- [ ] Package manifest: swift-tools 6.0, platform `.macOS(.v15)`, library product
  `AusterCore`; dependencies `https://github.com/dropbox/SwiftyDropbox` (latest
  release major) and `https://github.com/groue/GRDB.swift` (latest release major).
  Enable strict concurrency (`SwiftSetting.enableUpcomingFeature` not needed on
  tools 6 — language mode 6 is the default).
- [ ] Smoke test: `import AusterCore; import SwiftyDropbox; import GRDB` and assert
  a trivial fact, so dependency resolution is exercised by CI-style `swift test`.
- [ ] `swift test` passes. Commit.

### Task 1.2: App target

**Files:** create `Auster.xcodeproj` (via `xcodegen` if available, otherwise
generate project files directly), `Auster/AusterApp.swift`,
`Auster/Resources/Info.plist`, `Auster/Resources/Assets.xcassets`,
`Config/Shared.xcconfig`, `Config/Secrets.xcconfig.template`; modify `.gitignore`
(add `Config/Secrets.xcconfig`).

**Interfaces produced:** `@main struct AusterApp: App` containing a
`MenuBarExtra("Auster", systemImage: "checkmark.circle")` (window style) showing a
placeholder `Text("Auster")`, and an empty `Settings` scene.

- [ ] Info.plist: `LSUIElement = YES`; `CFBundleURLTypes` registering scheme
  `db-$(DROPBOX_APP_KEY)`; app links AusterCore local package.
- [ ] `Secrets.xcconfig.template` documents `DROPBOX_APP_KEY = <ask Josh>`;
  `Shared.xcconfig` includes it optionally (`#include? "Secrets.xcconfig"`). Build
  must succeed without the real key (auth phases need it at runtime only).
- [ ] App icon: the Icon Composer document lives at
  `design/AppIcon/AppIcon.icon` (see `design/AppIcon/README.md`). Add it to the
  project and set it as the app icon in the target settings (Xcode 26 consumes
  `.icon` directly). Ask Josh to open it once in Icon Composer to visually
  verify and re-save — not a blocker for this phase.
- [ ] Build and launch; menu bar icon appears; no Dock icon. Commit.

### Task 1.3: Build/test scripts

**Files:** create `Scripts/build.sh`, `Scripts/test.sh`; modify `README.md`
(replace the placeholder "Building" section with real instructions: scripts,
where the app key goes).

- [ ] `test.sh` runs `swift test --package-path AusterCore` then
  `xcodebuild -project Auster.xcodeproj -scheme Auster build`. Both scripts pass.
  Commit.

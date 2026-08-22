# Phase 10 — Distribution

**Goal:** Shippable artifact: Sparkle updates, Developer ID signing,
notarization, DMG. Requires Josh for credentials at several steps — batch the
asks.

**Reference:** decisions D2. **Definition of done:** a notarized DMG installs on
a clean machine, launches, and Sparkle sees an (empty) appcast.

### Task 10.1: Sparkle

**Files:** modify app project (SPM dep `https://github.com/sparkle-project/Sparkle`),
create `Auster/Support/UpdaterManager.swift`; modify `AboutTab.swift`,
`GeneralTab.swift`, `Info.plist`.

- [ ] `SPUStandardUpdaterController` wired to the About tab button and the
  menu-bar "Check for Updates…"; automatic-check interval bound to the existing
  `updateCheckInterval` setting (map Never → disabled). `SUFeedURL` +
  `SUPublicEDKey` placeholders in Info.plist via xcconfig
  (`SPARKLE_FEED_URL`, `SPARKLE_ED_PUBLIC_KEY`) — generate the EdDSA keypair
  with Sparkle's `generate_keys`, hand the private key to Josh (never commit).
  Ask Josh where the appcast will be hosted (likely GitHub Releases + appcast
  from a repo page). Commit.

### Task 10.2: Signing, notarization, packaging

**Files:** create `Scripts/release.sh`, `Scripts/notarize.sh`,
`docs/release-process.md`.

- [ ] `release.sh`: archive build (Release, hardened runtime, Developer ID
  Application identity via `CODE_SIGN_IDENTITY` env), `codesign --deep` embedded
  Sparkle frameworks, produce DMG (`hdiutil`), `notarize.sh` submits via
  `xcrun notarytool submit --wait` + staples. Needs from Josh: Developer ID
  certificate in keychain, App Store Connect API key or notarytool keychain
  profile name — script takes both as env vars and documents them in
  `docs/release-process.md` along with the appcast update steps
  (`generate_appcast`).
- [ ] Dry-run everything possible without credentials (unsigned archive + DMG
  build), then a full signed run with Josh. Commit.

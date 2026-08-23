# Phase 10 — Distribution & Release Automation

**Goal:** Shippable, self-updating releases: Sparkle wired into the app, and a
GitHub Actions release pipeline that signs, notarizes, packages, publishes,
and updates the appcast in one manually-triggered run.

The pipeline is modeled on Josh's FrontRow project (reference copy may exist
locally at `/Users/josh/Developer/FrontRow` — see `.github/workflows/release.yml`
and `scripts/` there; everything needed is specified below regardless).
Requires Josh for credentials — batch the asks (see Task 10.4).

**Definition of done:** CI green; a dry-run release build succeeds end-to-end
on GitHub Actions (build → sign → notarize → DMG artifact) without touching
tags/releases/appcast; a real release publishes v0.1.0 and Sparkle offers it
to an older build.

### Task 10.1: Sparkle in the app

**Files:** modify app project (SPM dep
`https://github.com/sparkle-project/Sparkle`), create
`Auster/Support/UpdaterManager.swift`, `.sparkle/appcast.xml` (empty feed
skeleton), `.sparkle/notes/TEMPLATE.md`, `.sparkle/notes/next.md` (copy of
template), `.sparkle/notes/README.md`; modify `AboutTab.swift`,
`GeneralTab.swift`, `Info.plist`.

- [x] `SPUStandardUpdaterController` wired to the About tab button and the
  menu-bar "Check for Updates…"; automatic-check interval bound to the
  existing `updateCheckInterval` setting (Never → disabled).
- [x] Info.plist (via xcconfig): `SUFeedURL =
  https://raw.githubusercontent.com/itsjoshpark/auster/main/.sparkle/appcast.xml`
  (the feed is *published from main* — this constrains the release workflow to
  run from main only), and `SUPublicEDKey` (ask Josh to run Sparkle's
  `generate_keys`; the private key becomes a GitHub secret, never committed).
      *`SU_FEED_URL` and `SU_PUBLIC_ED_KEY` are in `Config/Shared.xcconfig`. The
      public key is the placeholder `replace_with_the_sparkle_public_key` until
      Josh generates the pair; the app reports itself as having no updater and
      the release workflow refuses to publish until it is replaced.*
- [x] Release-notes flow: notes for the *next* release are written to
  `.sparkle/notes/next.md` before releasing (template-checked by the
  workflow); on release they ship to GitHub as Markdown and to the appcast as
  HTML, then are archived as `.sparkle/notes/<version>.md`. Document this in
  `.sparkle/notes/README.md`. Commit.

### Task 10.2: Version & appcast scripts (each TDD'd with a `.test.sh`)

**Files:** create in `Scripts/release/`: `bump-version.sh` + `.test.sh`,
`project-version.sh` + `.test.sh`, `append-appcast-item.sh` + `.test.sh`,
`render-notes.sh` + `.test.sh`. Modify `.github/workflows/ci.yml`: add a
second job running `Scripts/release/*.test.sh` (installs `cmark-gfm`).

- [x] `bump-version.sh <current> <major|minor|patch>` → prints bumped semver.
- [x] `project-version.sh read-marketing <pbxproj>` /
  `project-version.sh write <pbxproj> <version> <build>` — reads/writes
  `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in `project.pbxproj`.
      *They live in `Config/Shared.xcconfig`, not `project.pbxproj` — the script
      takes the xcconfig instead (implementation note N36).*
- [x] `render-notes.sh <notes.md>` → HTML on stdout via `cmark-gfm` (GitHub
  gets the Markdown as written; the appcast gets this HTML — same source, so
  both read the same).
- [x] `append-appcast-item.sh --appcast --version --build --url --signature
  --length --notes --pub-date --minimum-system-version` — inserts a new
  `<item>` (with `sparkle:version` = build, `sparkle:shortVersionString`,
  enclosure url/signature/length, HTML notes, pubDate, minimumSystemVersion)
  at the **top** of the feed, preserving the rest of the file byte-for-byte.
- [x] Tests cover happy paths + malformed input; CI job runs them. Commit.

### Task 10.3: Release workflow

**Files:** create `.github/workflows/release.yml`,
`.github/ExportOptions.plist`, `docs/release-process.md`.

`ExportOptions.plist`: `method=developer-id`, `signingStyle=manual`,
`signingCertificate=Developer ID Application`, `teamID` from Josh,
`destination=export`.

`release.yml` — `workflow_dispatch` with inputs `release-type`
(patch/minor/major choice) and `dry-run` (boolean); `concurrency: group:
release, cancel-in-progress: false`; `permissions: contents: write`; runs on
`macos-26`. Steps, in order:

- [x] **Checkout with `fetch-depth: 0`** (the build number is
  `git rev-list --count HEAD`; a shallow clone would return 1 and strand every
  existing user), setup-xcode latest-stable, `brew install cmark-gfm`, run the
  Task 10.2 script tests first.
- [x] **Resolve version step with hard guards** (all before the expensive
  build): must run from `main` (the appcast is served from main); marketing
  version read from `project.pbxproj` and bumped by `release-type`; build =
  commit count; fail if tag `v<version>` exists; fail if build ≤ newest
  `sparkle:version` already in the appcast (Sparkle would never offer the
  update); fail if `.sparkle/notes/next.md` is missing, still equals the
  template, or `<version>.md` already exists.
- [x] **Render notes to HTML** now (malformed notes fail before the build,
  not after).
- [x] **Credentials**: decode the App Store Connect `.p8` key to
  `$RUNNER_TEMP` (chmod 600, deleted in an `if: always()` step); import the
  Developer ID `.p12` into an **ephemeral keychain** created with a random
  password (`security create-keychain` / `import -T /usr/bin/codesign` /
  `set-key-partition-list`), never the login keychain.
- [x] **Preflight** (cheap, before the ~15-min build): a `Developer ID
  Application` identity is present; warn <30 days to certificate expiry, fail
  if expired; `notarytool history` accepts the API key.
- [x] **Archive** (`xcodebuild archive`, Release, `generic/platform=macOS`,
  derived data + archive paths under `$RUNNER_TEMP`) injecting
  `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` on the command line;
  **export** with `ExportOptions.plist`; **verify** the exported app:
  CFBundleVersion/ShortVersionString match, `codesign --verify --deep
  --strict`, and the signing authority is a Developer ID Application cert (the
  archive may carry a dev signature; only the export re-signs).
- [x] **DMG**: `npm install -g create-dmg` (sindresorhus's, not the Homebrew
  formula — different flags) + `brew install graphicsmagick imagemagick`;
  `create-dmg --no-code-sign` → `Auster_v<version>.dmg`.
- [x] **Notarize + staple**: `notarytool submit --wait`, `stapler staple`,
  `stapler validate`; upload the DMG as a workflow artifact.
- [x] **Publication gate:** nothing above changes anything outside the runner;
  every step below is skipped when `dry-run` is true.
- [x] **Tag + GitHub Release** (`gh release create v<version>` with the DMG
  and the Markdown notes).
- [x] **Appcast + write-back commit**: sign the DMG with Sparkle's
  `sign_update` (EdDSA private key from secrets via stdin, binary found under
  the build's `SourcePackages/artifacts/sparkle`); `append-appcast-item.sh`
  with the release URL
  `https://github.com/<repo>/releases/download/v<version>/<dmg>` and the app's
  `LSMinimumSystemVersion`; write version+build back into `project.pbxproj`
  (so local builds report the shipped version and the next run has a version
  to bump); `git mv` notes to `<version>.md` and reset `next.md` from the
  template; commit `chore: release <version> (<build>) [skip ci]` and push to
  main with **rebase-and-retry ×3** (the release is already public — a
  rejected push must not strand the feed).
- [x] `docs/release-process.md`: the runbook — write `next.md`, run the
  workflow (dry-run first), secrets inventory and rotation notes
  (the Developer ID certificate expires after 5 years; the API and EdDSA keys
  don't). Commit.

### Task 10.4: Secrets setup (with Josh) & first release

**GitHub secrets to ask Josh for** (documented in `docs/release-process.md`):
`DEVELOPER_ID_CERT_P12_BASE64` (+`DEVELOPER_ID_CERT_PASSWORD`),
`AC_API_KEY_P8_BASE64`, `AC_API_KEY_ID`, `AC_API_ISSUER_ID`,
`SPARKLE_ED_PRIVATE_KEY`; plus the team ID for `ExportOptions.plist` and the
public EdDSA key for Info.plist.

- [ ] Dry-run release on Actions → DMG artifact installs and launches on a
  clean machine.
      *Outstanding: the workflow, the scripts and the runbook are done and
      committed, but no run can succeed until the six repository secrets exist
      and `SU_PUBLIC_ED_KEY` is a real key. `docs/release-process.md` has the
      inventory and the commands.*
- [ ] Real release v0.1.0; install it, bump a dummy v0.1.1 dry run… then
  verify Sparkle update flow end-to-end with a real v0.1.1 when there is
  something to ship. Commit any fixes.

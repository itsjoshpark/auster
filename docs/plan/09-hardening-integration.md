# Phase 9 — Hardening & Integration Tests

**Goal:** Real-API integration suite, fatal-path recovery UI, and the long-tail
edge cases that make a sync client trustworthy.

**Reference:** engine-doc §9; dropbox-api-notes §7 (integration rules).
**Definition of done:** integration suite green against Josh's account;
recovery flows manually verified.

### Task 9.1: Integration test suite (opt-in)

**Files:** create `AusterCore/Tests/AusterCoreIntegrationTests/IntegrationTests.swift`
+ `IntegrationHarness.swift`; modify `Scripts/test.sh` (runs only when
`AUSTER_INTEGRATION=1`).

Harness: requires a linked account in the keychain (run the app once) or a
refresh token in env; all operations confined to remote
`/AusterIntegrationTests/<UUID>` with a local temp root; `tearDown` deletes the
remote folder even on failure.

- [x] Tests: round-trip small file (verify local `ContentHasher` output equals
  server `contentHash` — the cross-check promised in Phase 3); 12 MiB session
  upload; remote edit via API → longpoll fires → downloaded; conflicted-copy
  server behavior on stale-rev upload matches `MockDropboxService`'s simulation
  (assert same naming shape — this validates the mock's contract); delete with
  stale parentRev rejected; cursor survives listFolderContinue across changes;
  special filenames (emoji, NFD composed accents, ` (1)` suffixes) round-trip.
- [x] Commit.

### Task 9.2: Fatal-path recovery UI

**Files:** create `Auster/Windows/FatalErrorDialogs.swift`; modify coordinator
wiring; tests `Tests/.../RecoveryFlowTests.swift` (model logic only).

- [x] Folder missing (ux §9): dialog "Your Dropbox folder can't be found" with
  three choices — **Locate…** (folder picker; adopt the picked folder as the new
  root, then `rebuildIndex()` so its contents are reconciled safely — identical
  files skipped, differing ones become conflicted copies) / **Recreate** (make
  an empty folder at the configured path, then `rebuildIndex()` → full
  re-download) / **Quit**. TDD the decision model (pure enum-in → actions-out).
- [x] `notAuthorized` during sync → pause, menu shows "Please re-link Auster",
  menu action runs link flow, resume on success.
- [x] `wasResetOnOpen` (DB corruption) → auto full reindex with a notification
  ("Rebuilding sync index…"), no dialog.
- [x] Single-instance guard at launch (`NSRunningApplication` bundle-id scan →
  activate existing, exit). Commit.

### Task 9.3: Edge-case sweep (unit tests on existing components)

- [ ] Filename edge tests through the scenario harness: emoji, NFD/NFC pairs
  (create NFD locally → uploads NFC, no rename loop — engine-doc §9), 255-byte
  names, leading dots, `Icon\r` excluded, path with `/` depth 20.
- [ ] Clock skew: remote clientModified in the future → local mtime clamped to
  now (engine-doc §4.6 step 6).
- [ ] Disk full during download (simulate via tiny quota dir if feasible, else
  inject write error in `LocalFileOperations`) → item error recorded, cycle
  continues, cache dir cleaned.
- [ ] Read-only local file replaced by remote update (permissions preserved,
  no crash).
- [ ] Symlink round-trip local→remote→second-client simulation (mock).
- [ ] App Nap / sleep: after `NSWorkspace.willSleepNotification` →
  `didWakeNotification`, coordinator runs a catch-up + download cycle (add this
  wiring in `AppEnvironment`). Commit each green cluster.

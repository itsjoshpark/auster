# Phase 8 — App UI: Menu Bar, Settings, Onboarding, Notifications

**Goal:** Replace all debug UI with the real Maestral-style experience.

**Reference:** [research/maestral-ux.md](../research/maestral-ux.md) — treat it
as the UI spec; menu order/copy in §2, wizard in §3, settings in §4, issues §6,
activity §7, notifications §8, behaviors §9. All views render from `SyncState`
and call `SyncCoordinator`/`AuthManager` only.
**Definition of done:** walking the manual script at the bottom matches the UX
doc.

### Task 8.1: Menu bar

**Files:** create `Auster/MenuBar/MenuBarView.swift`,
`Auster/MenuBar/StatusIcon.swift`, `Auster/MenuBar/RecentChangesSection.swift`;
modify `Auster/AusterApp.swift`; tests `Tests (app target)/StatusIconTests.swift`.

- [x] `StatusIcon.assetName(for: SyncState.Status, hasSyncErrors: Bool) -> String`
  mapping per ux §1 onto the custom template icons from `design/MenuBarIcon/`
  (**copy** the five SVGs into `Assets.xcassets` as **template** image sets,
  rendered at 18×18 pt — `design/` is reference-only and never referenced by
  the build): idle → `menubar-idle`, syncing/indexing → `menubar-syncing`,
  paused → `menubar-paused`, sync-error and fatal → `menubar-error`,
  connecting → `menubar-offline`. TDD the mapping incl. the "error badge only
  when idle" rule (engine-doc §10 / cocoa behavior). Syncing stays static in
  v1 (see `design/MenuBarIcon/README.md`).
- [x] `MenuBarExtra` window content, top→bottom per ux §2: Open Dropbox Folder /
  Launch Dropbox Website / divider / email + usage rows / divider / status row
  (+ inline activity progress rows when syncing, ≤ 5, from `state.activity`) /
  Sync Issues row ("No Sync Issues" disabled or "Show Sync Issues (N)…") /
  Pause–Resume / Recent Changes disclosure (last 30 from `state.recentChanges`,
  row click reveals in Finder — `NSWorkspace.activateFileViewerSelecting`) /
  divider / Snooze Notifications submenu-equivalent (30 m / 1 h / 8 h; shows
  "snoozed until HH:MM" + turn-on when active) / Rebuild Index (confirmation
  dialog, copy per ux §2 item 13) / divider / Settings… / Check for Updates… /
  divider / Quit (⌘Q, calls `stopForQuit`).
- [x] Unlinked variant per ux §2. Commit.

### Task 8.2: Onboarding wizard

**Files:** create `Auster/Onboarding/OnboardingWindow.swift` + one view per page
(`WelcomePage`, `LinkPage`, `FolderPage`, `SelectiveSyncPage`, `DonePage`);
create `AusterCore/.../State/OnboardingModel.swift`;
tests `Tests/.../OnboardingModelTests.swift`.

- [x] `OnboardingModel`: page state machine per ux §3 (welcome → link → folder →
  selective → done), link via `AuthManager` (spinner while awaiting redirect;
  team account → error page with "Not supported: Auster does not support Dropbox
  team accounts."), folder selection (default `~/Dropbox`; existing non-empty →
  merge / choose-other / cancel dialog per ux §3.3 — "merge" simply proceeds:
  the engine's content-hash checks make it correct), selective page embeds
  `FolderTreeModel` tree, done → persist config + `coordinator.start()`. TDD
  transitions incl. cancel-and-unlink from folder page.
- [x] Fixed ~550×400 window shown when `.needsSetup`; closing it quits. Manual
  run-through fresh (delete app support + unlink first). Commit.

### Task 8.3: Settings window

**Files:** create `Auster/SettingsUI/SettingsView.swift` (+ `GeneralTab.swift`,
`SelectiveSyncTab.swift`, `AccountTab.swift`, `AboutTab.swift`),
`Auster/Support/LoginItem.swift`, `Auster/Support/FolderMover.swift`.

- [x] Tabs per ux §4: **General** — folder location picker (move via
  `FolderMover`: stop sync → `FileManager.moveItem` → update config → start;
  alert on failure/occupied target), Start at login (`SMAppService.mainApp`
  toggle), Notify about remote changes, update-check interval
  (Daily/Weekly/Monthly/Never). **Selective Sync** — Phase 7 tree embedded.
  **Account** — photo (async from `profilePhotoURL`, circle-clipped), name,
  email + plan, usage, Unlink… (confirmation copy per ux §4; unlink → wipe DB +
  cursors + config, keep files, back to onboarding). **About** — icon, version,
  repo link, Check for Updates (Sparkle stub button until Phase 10; hidden if
  updater unavailable).
- [ ] Manual pass of each control. Commit.

### Task 8.4: Notifications & sync issues window

**Files:** create `Auster/Support/NotificationManager.swift` (implements
`SyncNotifying`), `Auster/Windows/SyncIssuesWindow.swift`;
tests `Tests/.../NotificationBatchingTests.swift` (logic extracted to
`AusterCore/.../State/NotificationComposer.swift`).

- [x] `NotificationComposer` (pure, TDD): batch → title/body/action per
  engine-doc §10 + ux §8 ("You"/name resolution via account cache; 1 item →
  "<who> added <name>" + Show; many → counts; deletions → deleted-files URL;
  conflicts individually; nothing for own uploads — composer only ever receives
  download batches + conflicts by construction). Snooze + master switch
  suppress change notifications, never error ones.
- [x] `NotificationManager`: UNUserNotificationCenter; request permission on
  first notification after setup completes (ux §8); actions open Finder/URLs.
- [x] Sync Issues window per ux §6: list rows (icon, name, path, error title +
  message; actions reveal-in-Finder / open on dropbox.com); rows disappear when
  `state.syncErrors` clears. Commit.

### Manual test script (run fully before phase sign-off)

- [ ] Fresh setup end-to-end (wizard, all 5 pages, selective sync unchecking one
  folder) → initial download completes → icon idle.
- [ ] Each menu item behaves per ux §2; pause/resume; snooze shows countdown.
- [ ] Remote change on dropbox.com → notification with Show → Finder reveal.
- [ ] Conflict provoked (edit same file both sides while paused, resume) →
  conflicted copy + its notification.
- [ ] Settings: move folder; toggle login item (verify in System Settings);
  unlink → wizard returns; relink.
- [ ] Sync issue provoked (e.g. create a file named `CON.` or upload into a
  read-only remote shared folder if available; otherwise unit-only) → menu
  count + window row + clearing.

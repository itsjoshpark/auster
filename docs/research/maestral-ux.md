# Maestral UX Reference for Auster

Self-contained description of Maestral's macOS user experience, which Auster
replicates in SwiftUI (modernizing where noted). No access to Maestral is needed.

## 1. Menu bar item

Maestral is a pure menu-bar app (no Dock icon; `LSUIElement`). A monochrome
template icon reflects state:

| State | Icon feel | When |
|---|---|---|
| idle | steady checkmark-style | "Up to date" |
| syncing | animated / activity variant | transfers or indexing in progress |
| paused | pause badge | user paused sync |
| connecting / disconnected | dimmed | no connection to Dropbox |
| sync error | warning badge | per-path sync issues exist (shown once idle) |
| fatal error | error badge | sync stopped (folder missing, auth revoked, …) |

Auster: use SF Symbols with `MenuBarExtra`; keep icons template (auto dark/light).

## 2. Menu structure (linked, steady state)

Maestral's exact menu, top to bottom — Auster mirrors this in a `MenuBarExtra`
(menu style: item 12 needs a real submenu, and menu items track state while the
menu is open, so the richer-rows argument for window style did not hold — see
decisions N42):

1. **Open Dropbox Folder** — opens the local folder in Finder.
2. **Launch Dropbox Website** — opens dropbox.com.
3. ---
4. *email address* (disabled info row)
5. *space usage* e.g. "12.3% of 2 TB used" (disabled info row)
6. ---
7. *Status row*: "Up to date" / "Syncing…" / "Paused" / "Connecting…" / progress
   text like "Syncing ↓ 3/10" or "Indexing 2,451…"
8. **Show Sync Issues (N)…** — or disabled "No Sync Issues" when clean
9. **Pause Syncing** / **Resume Syncing**
10. **Show Recent Changes…** — window listing recently synced items (Maestral
    showed ~30; each row: name, path, change time; double-click reveals in Finder)
11. ---
12. **Snooze Notifications ▸** — submenu: For the next 30 minutes / hour / 8 hours;
    while snoozed, header shows "Notifications snoozed until HH:MM" + "Turn on
    notifications"
13. **Rebuild Index…** — confirmation alert explaining it may take a while, then
    full re-index (safe; conflicts become conflicted copies)
14. ---
15. **Preferences…** (Auster: "Settings…")
16. **Check for Updates…**
17. ---
18. **Quit Maestral** (⌘Q)

Unlinked/pre-setup variant: Open Dropbox Folder, Launch Dropbox Website, ---,
"Setting up…" status, ---, Start on login (toggle), Help Center, ---, Quit.

Menu contents (usage, status, issues count, pause label) refresh when the menu
opens and continuously while sync status changes (Maestral longpolled the daemon;
Auster observes the engine directly).

## 3. Setup wizard (first launch)

A fixed-size (~550×400), non-resizable window with sequential pages. Shown when not
linked or no local folder chosen; quitting it exits the app.

1. **Welcome** — app icon, "Welcome to Auster, an open source Dropbox client",
   button **Link Dropbox Account**.
2. **Link** — Maestral asked the user to paste an auth token. **Auster modernizes**:
   button opens the browser PKCE flow; page shows a spinner "Waiting for
   authorization…" until the `db-<appkey>://` redirect arrives; Cancel available.
   On failure show retry.
3. **Folder location** — "successfully linked" text; explains: choose a local
   folder for your Dropbox; if it's not empty you'll be offered to **merge**
   (merging transfers nothing that's identical — the sync engine's content-hash
   comparison makes this true automatically). Folder picker defaulting to `~`
   (creating `~/Dropbox`; if the target exists, offer merge / choose another /
   cancel). Buttons: Select / Cancel & Unlink.
4. **Selective sync** — "choose which folders to sync" with a lazy-loading
   checkbox tree of the remote Dropbox (top-level folders, expandable; see §5).
   Buttons: Select / Back.
5. **Done** — "You have successfully set up Auster. Allow some time for initial
   indexing and download." Button: Close. Sync starts.

## 4. Settings window

Maestral used a single window with sections (no tabs): account (rounded profile
picture, name, email + account type, usage, **Unlink this Dropbox…** button);
sync settings (Selective sync: "Select files and folders…" button; Local Dropbox
folder: folder picker; Bandwidth: "Change settings…"); system settings (Check for
updates: Daily/Weekly/Monthly/Never; Start on login switch; Notify about remote
changes switch); about (version, link, copyright).

**Auster** reorganizes into a native SwiftUI `Settings` scene with tabs, same
content:
- **General**: local folder location (picker + move-folder support), Start at
  login, Notify about remote changes, update-check interval.
- **Selective Sync**: the checkbox tree (see §5) embedded directly.
- **Account**: profile picture, name, email + plan, space usage, Unlink button
  (confirmation: unlink keeps local files, stops syncing, forgets account).
- **About**: icon, version, link to repo, Check for Updates (Sparkle).
(Maestral's bandwidth-limit settings are permanently out of scope — decisions D4.)

Changing the folder location moves the existing folder (`FileManager.moveItem`) and
updates config; on failure or existing target, alert.

## 5. Selective sync UI behavior

- Tree of remote folders, **lazy-loaded** per level via `list_folder` (non-recursive)
  as nodes expand; only folders are shown (Maestral listed files too in later
  versions — Auster: folders only for v1 simplicity).
- Each node has a tri-state checkbox: **on** (included), **off** (excluded),
  **mixed** (some descendants excluded). Initial state derives from the excluded
  paths list; checking/unchecking a parent cascades to loaded children; a child
  differing from its parent makes ancestors mixed.
- On Apply/Select: compute the delta — newly excluded paths are added to the
  excluded list and their local copies deleted; newly included paths are removed
  from the list and queued for download. Excluding everything is allowed; excluding
  the root is not.

## 6. Sync issues window

List of per-path sync errors: file name + icon, path, error title + human-readable
message. Row action: reveal in Finder / open on dropbox.com. Issues clear
automatically when the item later syncs successfully. Menu shows the count.

## 7. Recent changes (activity)

Window (Maestral) or popover section (Auster may inline the top few in the
MenuBarExtra window plus a "Show all" window) listing completed sync events, most
recent first: icon by type, name, dbx path, relative time, direction. Click →
reveal in Finder (deleted items: no action / dropbox.com deleted files page).

## 8. Notifications

- Sent only for **downloaded** (remote) changes and for conflicts, never for the
  user's own uploads. Batched per download cycle:
  - One change: "**<Person> added|changed|removed|moved <filename>**" ("You" if the
    change came from the same account) with a **Show** button → reveal in Finder;
    deletions → open dropbox.com/deleted_files.
  - Many changes: "<Person> changed 12 files" / "24 items changed".
  - Each conflicted copy gets its own "Sync conflict" notification.
- Sync errors: "Could not upload/download <name>" with Show action.
- Fatal errors: notification + menu error state.
- Snooze: menu-driven timer (30 min / 1 h / 8 h) suppressing change notifications
  (not error ones). A master "notify about remote changes" switch lives in
  Settings.
- Auster: `UserNotifications` framework; request permission during onboarding
  (after setup completes, not at first launch).

## 9. Miscellaneous behaviors worth copying

- **Start on login**: toggle uses `SMAppService.mainApp` (modern replacement for
  Maestral's launchd plist).
- **Pause/Resume**: pausing stops watchers and workers; resuming runs the full
  startup sequence (catch-up scan first). Paused state persists across app
  restarts.
- **Auto-pause on disconnect**: status becomes "Connecting…" and sync resumes
  automatically when the network returns; not user-visible "paused".
- **Folder missing**: if the local Dropbox folder disappears (deleted/renamed/on an
  unmounted drive), show a dialog offering to select a new location or recreate,
  never treat as deletions.
- **Single instance**: enforce one running instance (NSRunningApplication check /
  existing-instance activation).
- **Quit** stops sync cleanly (cursor/index already persisted incrementally; no
  long teardown needed).

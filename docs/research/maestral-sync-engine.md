# Maestral Sync Engine Reference

This document is a **self-contained** description of how Maestral (the discontinued
open-source Dropbox client) implemented two-way sync. Auster's sync engine reimplements
these algorithms in Swift. You do not need access to Maestral's source code; everything
required is captured here. Terminology: "remote" = Dropbox server state, "local" = the
user's local Dropbox folder on disk.

## 1. Persistent state

Maestral keeps all sync state in an SQLite database plus a small config/state store.
Auster should keep the same logical schema (via GRDB).

### 1.1 Index table (the heart of the engine)

One row per synced item, keyed by **lowercased Dropbox path**:

| Column | Meaning |
|---|---|
| `dbx_path_lower` (PK) | Normalized (lowercased) Dropbox path. Primary key because Dropbox paths are case-insensitive. |
| `dbx_path_cased` | Correctly cased Dropbox path (from `path_display`), used to derive the local path. |
| `dbx_id` | Dropbox's unique ID for the item (`id` field of metadata). |
| `item_type` | `file` or `folder`. |
| `last_sync` | Unix timestamp of the last time this item was synced. Compared against local ctime to detect unsynced local changes. |
| `rev` | Dropbox revision string. Literal string `"folder"` for folders. |
| `content_hash` | Dropbox content hash. `"folder"` for folders. May be null if not yet computed. |
| `symlink_target` | Target path if the file is a symlink, else null. |

The index represents "the state both sides agreed on at last sync". Every diff (local
scan or remote delta) is computed against it.

### 1.2 Hash cache table

Computing Dropbox content hashes is expensive; cache them:

| Column | Meaning |
|---|---|
| `inode` (PK) | File inode. |
| `local_path` | Absolute local path. |
| `hash_str` | Cached content hash. |
| `mtime` | mtime at hash time. If current mtime differs, recompute. |

### 1.3 Sync errors table

One row per path that failed to sync, keyed by `dbx_path_lower`, with direction
(up/down), error title/message/type, and the from-paths for moves. Surfaced in the UI
as "sync issues"; cleared and retried on the next pass over that path.

### 1.4 History table

Completed sync events (for the "Recent Changes" UI), pruned to entries newer than a
retention window (Maestral: 1 week / max 1000). Each row records direction, change
type, item type, paths, size, timestamps.

### 1.5 Cursors

- **Remote cursor** (string): Dropbox `list_folder` cursor. Empty string means "never
  indexed → do a full remote index". Persisted after each applied batch so an
  interrupted indexing resumes where it left off.
- **Local cursor** (float timestamp): time of the last completed upload cycle. Used by
  the offline catch-up scan to detect files modified while the app wasn't watching.

Also persisted: `did_finish_indexing` flag and `indexing_counter` so a first-run
indexing that gets interrupted resumes rather than restarts, and a
`pending_downloads` queue (paths newly included via selective sync that still need
downloading — persisted so it survives restarts).

## 2. Thread/concurrency model

Maestral ran these concurrent workers (Auster should map them to actors/tasks):

1. **Connection monitor** — polls reachability of the API host every 10 s. On
   disconnect: pause sync, set "autostart" flag; on reconnect: resume if flag set.
2. **Startup worker** — runs once per sync start (see §3).
3. **Download worker** — loop: longpoll for remote changes → apply download sync
   cycle → refresh space usage.
4. **Upload worker** — loop: wait on local FS event queue (with timeout ~40 s) →
   run upload sync cycle.
5. **Local FS observer** — the FSEvents watcher feeding the event queue.
6. **Download-added-item worker** — drains the persistent `pending_downloads` queue
   (items newly included in selective sync).

A single **sync lock** serializes upload cycles, download cycles, and ad-hoc
downloads: only one may mutate local files + index at a time. A cancel event allows
aborting mid-cycle (checked between items). All worker errors funnel through one
handler: connection errors → pause + schedule auto-resume; cancellation → stop;
anything else → notify user, stop sync.

## 3. Startup sequence (each time sync starts)

1. Verify the local Dropbox folder still exists (see §9 for the folder-missing case).
2. Fetch space usage / account info.
3. (Team accounts) Maestral checked for path-root changes here — Auster does not
   support team accounts at all (decisions D4); they are rejected at link time, so
   this step is omitted.
4. Retry every path in the download-errors list (fetch each item fresh).
5. Drain the persistent pending-downloads queue.
6. Run one full **download sync cycle** (§4). If the remote cursor is empty, this is
   the initial full index of the whole Dropbox.
7. Run **offline catch-up upload** (§6): full local scan diffed against the index.
8. Enter steady state: enable the FS event handler, start upload/download workers.

Order matters: remote changes land before the local scan, so the local scan sees
the updated index.

## 4. Download sync (remote → local)

### 4.1 Detecting changes

- Steady state: call `files/list_folder/longpoll` with the saved cursor (timeout
  ~40 s + server adds up to 90 s jitter; use an HTTP client timeout well above
  that, ~130 s+). Longpoll needs **no auth** and uses the separate `notify.dropboxapi.com`
  host — SwiftyDropbox handles this internally. When it returns `changes: true`,
  wait ~2 s (lets multi-step server operations settle), then page through
  `files/list_folder/continue` with the cursor.
- First run (empty cursor): `files/list_folder("", recursive: true)` and page
  through everything. Persist the new cursor after **each applied page** so
  interruption resumes cleanly.
- Dropbox returns only `FileMetadata`, `FolderMetadata`, or `DeletedMetadata` —
  **moves arrive as delete + add**; modifications arrive as another `FileMetadata`
  for the same path.

### 4.2 Cleaning remote changes

Group entries by `path_lower`. If a path has multiple entries, keep only the **last**
one (Dropbox guarantees in-order application reproduces server state), except: if the
last entry's type (file vs folder) differs from what our index has for that path,
synthesize a `DeletedMetadata` before it so the old item is removed first.

### 4.3 Ordering

Sort each batch by path depth (number of `/`). Then apply:
1. **Deletions**, shallowest first (deleting a parent implicitly handles children).
2. **Folder creations**, shallowest first (parents before children).
3. **Files**, in parallel (bounded concurrency; Maestral used a small thread pool
   with a parallel-transfer semaphore, default ~6).

Before applying any file/folder, ensure its parent folder exists in the index; if
not, fetch the parent's metadata and create it first (guarded by a lock so
concurrent workers don't race creating the same parents).

### 4.4 Conflict resolution (the decision table)

For every incoming remote event, compare against the index and local disk
(`checkDownloadConflict`), in this exact order:

1. **`event.rev == index.rev`** → `LocalNewerOrIdentical`: local is same or ahead;
   **skip** the download (do not touch index).
2. **`event.content_hash == localContentHash(path)`** (and symlink targets equal) →
   `Identical`: same content already on disk; **skip but update index** with the new
   rev.
3. **An unresolved upload error exists for this path** → `Conflict`.
4. **Local item has no unsynced changes** (recursive ctime check, §4.5) →
   `RemoteNewer`: safe to apply the remote change.
5. **Remote event is a deletion** (and local has unsynced changes) →
   `LocalNewerOrIdentical`: skip the deletion; local edits win over remote delete.
6. **Otherwise** → `Conflict`.

`Conflict` handling: never overwrite. Rename the local item to a Dropbox-style
conflicted copy:
`"<name> (<OwnerName>'s conflicted copy YYYY-MM-DD)<ext>"` (owner name omitted if
unknown → `"<name> (conflicted copy YYYY-MM-DD)<ext>"`), appending ` (1)`, ` (2)`…
if that name exists. Then rescan the renamed item so it gets uploaded as a new file,
and proceed to apply the remote change at the original path.

### 4.5 "Does local have unsynced changes?"

`ctime(local) > index.last_sync` for files. For folders, recurse: any child
file/folder with ctime newer than its `last_sync` counts (excluded names like
`.DS_Store` never count). Missing from disk but present in index also counts as a
change. ctime (not mtime) is used here because it catches permission/rename
changes; mtime is used by the catch-up scan instead because moving a folder across
volumes can bump ctimes wholesale.

### 4.6 Applying a remote file

1. Apply casing changes first: if index has the path with different casing, rename
   the local item to match (inside an FS-event ignore, §5.2).
2. Run the conflict check (§4.4); skip or conflict-rename as decided.
3. Ensure parent exists.
4. Symlinks: Dropbox stores symlink metadata; do not download content — create the
   symlink locally (`symlink_target`).
5. Otherwise **download to a temp file** in a hidden cache dir *inside* the Dropbox
   folder (Maestral: `<dropbox>/.maestral.cache/`; Auster: `.auster.cache`) —
   same volume guarantees an atomic rename. Verify the downloaded bytes' content
   hash against metadata; delete and retry (up to 10×) on mismatch.
6. Set the file's mtime to `client_modified` (clamped to ≤ now and ≤ `server_modified`).
7. Re-check for conflict (the file may have changed during a long download);
   conflict-rename if needed.
8. If a **folder** currently occupies the target path, delete it (recursively).
9. Atomically move temp file into place, preserving existing permissions/xattrs when
   replacing a file with the same `dbx_id` (i.e., a content update).
10. Update index row (rev, hash, `last_sync = now`); update hash cache with the
    known hash + fresh mtime/inode.

All local mutations happen inside FS-event **ignores** (§5.2) so they don't echo
back into the upload queue.

### 4.7 Applying a remote folder

Casing fix → conflict check → ensure parent → if a *file* occupies the path, delete
it → `mkdir` (FileExists is fine) → update index.

### 4.8 Applying a remote deletion

Casing fix → conflict check (local unsynced changes veto the deletion, §4.4 rule 5)
→ recursive delete of the local item (case-sensitive guard: verify the on-disk
name's casing matches before deleting, so `A.txt` deletion doesn't remove `a.txt`)
→ remove path subtree from index. "Not found" locally is success (already gone).

## 5. Upload sync (local → remote)

### 5.1 Capturing local changes

Watch the Dropbox folder recursively with FSEvents. Raw events (created / deleted /
modified / moved, file or dir — ignore dir-modified) go through the ignore filter
(§5.2) into a queue. The upload worker wakes when the queue is non-empty, then keeps
draining until the queue has been idle for ~1 s (debounce), timestamps the batch
(this becomes the new local cursor), and processes it.

### 5.2 The ignore mechanism (critical correctness piece)

Every local mutation the engine itself performs (download-move, mkdir, delete,
conflict rename, case rename) is wrapped in an "ignore" declaration: the expected
FS event(s) are registered before performing the operation. The event filter drops
the **first** matching event (or all matching child events, for recursive directory
ignores) and expires each registration ~2 s after its operation completes (FSEvents
can deliver late). Matching is by event type + path (+ dest path for moves);
recursive ignores match children of the ignored directory event. Without this,
every download would immediately re-upload.

### 5.3 Cleaning local events (coalescing)

Raw event streams are messy (editors do atomic-save dances). Clean a batch as
follows:

1. **Split** every move event into delete(src) + create(dst) pairs (remembering the
   pairing).
2. **Per path**, collapse the event history to a single event:
   - more creates than deletes → single `Created`
   - more deletes than creates → single `Deleted`
   - equal, first event was a delete (or no creates) → single `Modified`
     (or a delete+create pair if the item type changed file↔folder)
   - equal, first event was a create → item was temporary; drop all events, but
     **rescan the path** (schedule synthetic events from disk state) because macOS
     can deliver atomic-save events out of order.
3. **Recombine** split moves back into a single Move event only if both sides
   survived with exactly one event each and neither side is excluded from sync
   (if one side is excluded, keep them as separate delete/create so renames into or
   out of excluded space behave as create/delete).
4. **Prune children of moved/deleted directories**: if a directory was moved, drop
   child move events that mirror it; if deleted, drop child delete events. (Do this
   with set lookups, not nested scans — batches can be 20k+ events.)

Then convert each FS event to a sync event, computing the local content hash
(parallelize hashing across a small pool).

### 5.4 Filtering

Drop events whose path is excluded (§8) before uploading.

### 5.5 Ordering

1. **Deletions** first (parallel) — children of deleted dirs were already pruned.
2. **Directory moves** second, sequentially (a dir move takes its whole subtree).
3. Everything else grouped by path depth, shallowest level first, parallel within a
   level (parents exist before children are uploaded).

### 5.6 Per-event upload handlers

All handlers first check two special conflicts for created/moved items:

- **Selective-sync conflict**: the path is excluded by the user's selective sync →
  rename local item to `"<name> (selective sync conflict)"` and rescan it.
- **Normalization conflict**: another local file in the same directory has a
  different byte-name but the same normalized form (case- or Unicode-collision;
  Dropbox would treat them as one path) → rename to
  `"<name> (case conflict)"` / `"(unicode conflict)"` and rescan.

**File created/modified:**
- Wait until the file's size is stable (poll ~0.2 s) to avoid uploading a file
  mid-write.
- Fetch current remote metadata. If remote content hash + symlink target equal
  local → skip upload, just update the index (common when two clients sync the same
  change, or when a file was moved locally and the move handler already created it).
- Choose write mode: no index entry → `add` (Dropbox autorenames on collision);
  index says folder → `overwrite`; index has a file rev → `update(rev)` (Dropbox
  creates a server-side conflicted copy if the server rev moved on).
- Upload with `autorename: true` (see §7 for chunking). Then check whether the
  server renamed it (returned `path_lower` ≠ expected, or, on case-sensitive local
  filesystems, returned name ≠ local name): if renamed, the server made a
  **conflicted copy** — move the *local* file to the server-assigned name (inside an
  ignore) and drop the old index row, so local mirrors remote. Update index from
  returned metadata.

**Folder created:** `files/create_folder`. If a folder already exists remotely →
not a conflict; fetch its metadata and update index. If a *file* is in the way →
create with `autorename: true` and mirror the rename locally as above.

**Item moved:** call `files/move_v2(from, to, autorename: true)`.
- If a file already exists at the destination per our index, first delete it
  remotely with `parent_rev` guard (ignore not-found/conflict failures) because the
  move API won't overwrite.
- If the source doesn't exist remotely → fall back to rescanning the destination
  (it will be uploaded as new).
- Ignore renames that only change Unicode normalization (Dropbox normalizes to NFC;
  treating these as moves causes loops).
- After a successful dir move, update the index for the whole subtree by listing the
  new remote folder recursively.
- Note: moving a directory tree only needs the one API call; children need no
  uploads (handled implicitly).

**Item deleted:**
- If path excluded by selective sync → skip.
- Fetch remote metadata (`include_deleted`). Missing remotely → skip.
- Type mismatch guards: expected folder but remote is a file that changed since
  last sync → skip and untrack; expected file but remote is a folder → skip and
  untrack. (Never delete data the server version of which we haven't seen.)
- Delete with `parent_rev = index.rev` for files (server rejects if the remote
  changed since our last sync — then skip, the change will download later).
- Remove subtree from index.

After the cycle, notify the user about conflicts, persist the local cursor, and
clear per-cycle caches.

## 6. Offline catch-up scan (run at every sync start)

Detect changes made while the app wasn't running by a full walk of the local folder
compared to the index:

- On disk, not in index → `Created`.
- On disk with `mtime > max(index.last_sync, local_cursor)` (and < scan start) →
  `Modified` (files only; type change file↔folder becomes delete+create).
- In index, not on disk (checked with **casing-exact** existence on
  case-insensitive filesystems) → `Deleted`.

Feed these through the same clean → convert → apply pipeline (§5.3–5.6).
Before emitting deletions, verify the Dropbox folder itself still exists —
otherwise you'd interpret a missing folder as "delete everything remotely" (§9).
Moves cannot be detected offline; they become delete + create, which is fine
because the create's content-equality check (§5.6) avoids re-uploading bytes when
possible.

## 7. Transfers

- **Download**: stream to temp file, hash while streaming, compare with metadata's
  `content_hash`; on mismatch delete + retry (max 10).
- **Upload ≤ chunk size**: single `files/upload` call with `client_modified` set
  from the file's mtime (UTC) and `content_hash` attached for server-side
  verification.
- **Upload > chunk size**: `upload_session/start` → repeated `append_v2` →
  `finish` with the commit info (path, mode, autorename, client_modified). Maestral
  used 4 MiB chunks; each call carries the chunk's `content_hash`. Detect the file
  changing mid-upload (compare stat before/after each read) → abort (close session)
  and skip; the next FS event will retry. On an offset error from the server, seek
  to the server-provided offset and continue. (Dropbox hard limits: 150 MB max for
  single-call upload, so chunked path is mandatory above that; sessions live 48 h.)
- Bound parallel uploads and downloads with semaphores (Maestral default 6).
- Retry transfers up to 10× on data-corruption errors.
- Space usage is refreshed after download cycles (for menu display).

## 8. What is never synced / selective sync

**Always-excluded names** (case-sensitive where meaningful): `desktop.ini`,
`Thumbs.db`, `thumbs.db`, `.DS_Store`, `.ds_store`, `.Spotlight-V100`, `.Trashes`,
`.fseventd`, `.localized`, `.TemporaryItems`, `Icon\r`,
`.com.apple.timemachine.supported`, `.dropbox`, `.dropbox.attr`, `.dropbox.cache`,
the engine's own cache dir name, plus temp patterns: basenames starting `~$` or
`.~`, or starting `~` and ending `.tmp`.

**Selective sync**: a persisted set of lowercased Dropbox paths the user excluded.
- Download side: incoming events under an excluded path are dropped. A remote
  deletion of an excluded item removes it (and children) from the excluded list.
- Excluding a folder in the UI: add to list, delete local copy.
- Including a folder: remove it (and ancestors' entries as needed) from the list,
  enqueue it on the persistent pending-downloads queue.
- Upload side: creating/moving an item *at an excluded path* locally triggers the
  "selective sync conflict" rename (§5.6). Local deletion of an excluded path is
  skipped.

## 9. Guard rails & edge cases

- **Dropbox folder missing/renamed**: every cycle verifies the folder exists (with
  exact casing). If missing → raise a fatal "folder missing" state, pause sync, and
  offer the user to relocate/recreate — never interpret it as mass deletion.
- **Deleting the whole Dropbox folder locally** while running: same guard.
- **Case sensitivity**: detect at startup whether the local filesystem is
  case-sensitive (create a probe file, check alternate casing). All index keys are
  normalized (lowercase, NFC-ish per Dropbox rules); display paths kept cased.
  `path_display` from Dropbox only guarantees the basename's casing — resolve full
  cased paths via cache → index → (rarely) parent metadata queries, with an LRU
  cache (~5000 entries).
- **Unicode**: Dropbox normalizes names to NFC; macOS HFS+/APFS may report NFD.
  Compare normalized; ignore pure-normalization renames.
- **Database corruption**: on SQLite error at open → delete DB, reset cursors,
  trigger full reindex (sync state is always reconstructible).
- **Rebuild index** (user action): stop sync, clear index + cursors, restart →
  full remote index + catch-up scan re-derive everything; differing contents
  produce conflicted copies rather than data loss.
- **Cancellation**: checked before each item transfer; interrupting mid-batch is
  safe because cursors/index only advance after items are applied.
- **Memory**: process changes in pages (list_folder pages ≈ up to ~2000 entries);
  don't hold the whole tree in memory.

## 10. Status & activity reporting

The engine exposes:
- **Status line**: `Connecting…` / `Up to date` / `Syncing…` / `Paused` /
  `Sync error` (+ transient `Indexing N…`, `Syncing ↓ x/y`-style progress strings).
- **Activity**: currently syncing items (path + direction + progress bytes/total).
- **History**: recent completed events for "Recent Changes" (last ~30 shown).
- **Sync errors list**: per-path issues for the Sync Issues window.
- **Notifications** (batched per download cycle): single change → "<User> added
  <name>" with a Show button (reveal in Finder); multiple → "<User> changed N
  files"; deletions link to dropbox.com/deleted_files; each *conflict* gets its own
  notification. Changes by the current account during upload are not notified —
  only downloaded (remote) changes and conflicts are.

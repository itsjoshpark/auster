# Dropbox API v2 & SwiftyDropbox Notes for Auster

Self-contained reference for the Dropbox APIs Auster uses and how the official Swift
SDK (SwiftyDropbox) exposes them. Verified against SwiftyDropbox master (July 2026);
the SDK is actively maintained and generated from Dropbox's API spec.

## 1. App registration & auth

- Dropbox App Console entry exists for Auster with **Full Dropbox** access type.
  Required scopes (enable in console → Permissions tab): `account_info.read`,
  `files.metadata.read`, `files.content.read`, `files.content.write`.
- While the app is in **development** status, only the owner's account (and up to
  500 invited dev users) can authorize — fine for building/testing. Production
  approval is only needed later for public release.
- **OAuth 2 code flow with PKCE** — no app secret ships in the client. SwiftyDropbox
  implements this:
  - Add SwiftyDropbox via SPM (product `SwiftyDropbox`,
    `https://github.com/dropbox/SwiftyDropbox`).
  - At launch: `DropboxClientsManager.setupWithAppKeyDesktop("<APP_KEY>")`.
  - To link: `DropboxClientsManager.authorizeFromControllerV2(sharedApplication:
    controller: loadingStatusDelegate: openURL: scopeRequest:)` with
    `ScopeRequest(scopeType: .user, scopes: [...], includeGrantedScopes: false)`.
    It opens the browser; PKCE is forced on desktop.
  - **Redirect**: register the URL scheme `db-<APP_KEY>` in Info.plist
    (CFBundleURLTypes). On callback, pass the URL to
    `DropboxClientsManager.handleRedirectURL(_:includeBackgroundClient:completion:)`
    from the SwiftUI `.onOpenURL` handler. Completion delivers
    `DropboxOAuthResult` (.success / .cancel / .error).
  - Tokens: short-lived access token + long-lived refresh token, stored in the
    **macOS Keychain** by the SDK (`SecureStorageAccessDefaultImpl`). Clients from
    `DropboxClientsManager` refresh automatically. `DropboxClientsManager
    .authorizedClient` is non-nil when linked (SDK restores from keychain at setup).
  - Unlink: `DropboxClientsManager.unlinkClients()` (revokes + clears keychain);
    optionally call `auth/token/revoke` first via `client.auth.tokenRevoke()`.
- App key injection: keep the key out of git — `Secrets.xcconfig` (gitignored)
  defining `DROPBOX_APP_KEY`, referenced from Info.plist, read via Bundle at
  runtime. Ask Josh for the actual key when wiring this up.

## 2. Endpoints Auster uses (SwiftyDropbox route names)

All on `client.files` / `client.users` / `client.check`. SwiftyDropbox calls are
callback-based (`.response { ... }`); wrap them in async/await helpers with
`withCheckedThrowingContinuation`.

| Purpose | Route |
|---|---|
| Account info | `users.getCurrentAccount()` → name, email, account_id, account type |
| Space usage | `users.getSpaceUsage()` |
| Connectivity probe | `check.user(query:)` (validates auth + reachability) |
| List / full index | `files.listFolder(path: "", recursive: true, includeDeleted: false, limit: 2000)` then `files.listFolderContinue(cursor:)` until `hasMore == false` |
| Get latest cursor without entries | `files.listFolderGetLatestCursor(...)` (not needed if we full-index first) |
| Change notification | `files.listFolderLongpoll(cursor:, timeout: 30...480)` — **no auth header**, separate notify host; SDK routes it correctly. Server adds up to 90 s jitter, so use a generous client timeout (SDK handles a long timeout for longpoll requests). Response: `changes: Bool`, optional `backoff` seconds (honor it: sleep backoff + ~5 s before next longpoll). |
| Single item metadata | `files.getMetadata(path:, includeDeleted: true)` — errors with `path/not_found` for never-existed paths |
| Download | `files.download(path: "rev:<rev>")` — download **by rev** so you get exactly the version you decided to apply. Streamed variant: `download(path:overwrite:destination:)` writes to a URL. |
| Upload small | `files.upload(path:, mode:, autorename:, clientModified:, contentHash:, input:)` — max 150 MB per call |
| Upload session | `files.uploadSessionStart(...)` → `uploadSessionAppendV2(cursor:, contentHash:, input:)` → `uploadSessionFinish(cursor:, commit: CommitInfo(path:mode:autorename:clientModified:), ...)` — sessions valid 48 h |
| Delete | `files.deleteV2(path:, parentRev:)` — `parentRev` makes the delete conditional on the remote file still being at that rev |
| Move | `files.moveV2(fromPath:, toPath:, autorename: true)` |
| Create folder | `files.createFolderV2(path:, autorename:)` |
| Revoke token | `auth.tokenRevoke()` |

### WriteMode semantics (upload)
- `.add` — never overwrite; server autorenames to `"name (2).ext"` on collision.
- `.overwrite` — always overwrite.
- `.update(rev)` — overwrite only if server rev matches; otherwise server creates
  `"name (conflicted copy).ext"` (with `autorename: true`). This is the normal mode
  for modified files and is what makes lost-update impossible.

## 3. Metadata model

`Files.Metadata` subclasses: `FileMetadata`, `FolderMetadata`, `DeletedMetadata`.

- `FileMetadata`: `id` (stable, `"id:..."`), `rev` (opaque, changes per revision),
  `size`, `contentHash`, `clientModified` / `serverModified` (UTC), `pathLower`,
  `pathDisplay`, `symlinkInfo?.target`, `isDownloadable`, `sharingInfo?.modifiedBy`.
- `FolderMetadata`: `id`, `pathLower`, `pathDisplay`, `sharingInfo`.
- `DeletedMetadata`: only name/paths — type of the deleted item is unknown (look it
  up in our index).
- **Moves are never reported**: a rename/move arrives as `DeletedMetadata` (old
  path) + `FileMetadata`/`FolderMetadata` (new path).
- `pathDisplay` guarantees correct casing **only for the basename**; parent
  components may be stale-cased. Resolve full casing via our index (see sync-engine
  doc §9).
- Paths are case-insensitive; Dropbox normalizes Unicode to NFC.

## 4. content_hash algorithm

To compare local files with remote metadata without downloading:

1. Split the file into 4 MiB (4,194,304-byte) blocks.
2. SHA-256 each block.
3. Concatenate the raw block digests.
4. SHA-256 the concatenation; hex-encode → `content_hash`.

Empty file → SHA-256 of empty concatenation. Implement with CryptoKit
(`SHA256`), streaming (never load whole files). Verify downloads by hashing the
stream while writing; attach per-chunk `contentHash` on uploads so the server
verifies each request.

## 5. Rate limiting & errors

- HTTP 429 / `too_many_requests` and 5xx: SwiftyDropbox surfaces
  `CallError.rateLimitError(retryAfter)` / `.internalServerError`. Honor
  `Retry-After`, retry with exponential backoff + jitter.
- Longpoll `backoff` field: wait that many seconds before re-longpolling.
- Auth errors (`AuthError.expiredAccessToken` is auto-refreshed by the SDK;
  `invalidAccessToken` / revoked → force re-link: pause sync, show "unlinked"
  state).
- Path errors worth distinguishing in the sync engine: `not_found`,
  `disallowed_name`, `malformed_path`, `restricted_content`, `insufficient_space`,
  `conflict` (file/folder/file_ancestor), `too_many_write_operations` (retry with
  backoff — Dropbox namespace write contention).
- `reset` on `listFolderContinue`: cursor invalidated → clear cursor, full reindex.
- Data-corruption on transfers (hash mismatch): retry up to 10×.

## 6. Practical limits

- Single `files/upload` call: ≤ 150 MB hard limit. Auster (like Maestral) uploads
  files ≤ 4 MiB in one call and uses upload sessions with 4 MiB chunks above that
  (4 MiB alignment also matches the content-hash block size).
- Upload session total: ≤ 350 GB.
- `list_folder` page size: request `limit` is advisory; pages can be large — process
  page-by-page, persist cursor per page.
- Batch endpoints (`delete_batch`, `move_batch`, `upload_session/finish_batch`)
  exist; v1 uses per-item calls (matching Maestral) — noted as a future
  optimization.
- Longpoll timeout parameter: 30–480 s (Auster uses 40 like Maestral, + jitter
  tolerance in the HTTP timeout).

## 7. Testing hooks in SwiftyDropbox

- `MockDropboxTransportClient` (in the SDK) implements `DropboxTransportClientInterface`
  and lets tests intercept every route call and return canned
  responses — pass it to `DropboxClient(transportClient:)`. Use this for
  AusterCore unit tests instead of mocking HTTP. (It is an internal test helper in
  the SDK repo; if not exported by the SPM product, define `AusterDropboxClient` as
  a protocol over the routes we use and mock that instead — decide at
  implementation time. The protocol approach also keeps async/await wrappers in one
  place and is the recommended default.)
- Integration tests: gate on an env var (`AUSTER_TEST_TOKEN` or run the OAuth flow
  once on Josh's test account) and operate under a dedicated remote test directory
  (e.g. `/AusterIntegrationTests/<uuid>`), cleaning up after each run. Never run
  destructive integration tests against a real populated account without a scoped
  test root.

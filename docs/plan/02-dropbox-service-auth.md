# Phase 2 — Dropbox Service Layer & Auth

**Goal:** A typed, mockable, async facade over SwiftyDropbox
(`DropboxService`), plus working link/unlink (PKCE) in the app.

**Reference:** [research/dropbox-api-notes.md](../research/dropbox-api-notes.md)
(routes, PKCE, WriteMode, errors, limits).
**Definition of done:** unit tests pass against `MockDropboxService`; manually
linking Josh's account from the app works end-to-end (ask Josh for the app key
now), and account name/usage can be fetched.

### Task 2.1: Domain models & service protocol

**Files:** create `AusterCore/Sources/AusterCore/Client/RemoteModels.swift`,
`Client/DropboxService.swift`, `Client/DropboxServiceError.swift`;
tests `Tests/.../RemoteModelsTests.swift`.

**Interfaces produced (used by every later phase — keep these exact):**

```swift
public struct RemoteFile: Sendable, Equatable {
    public let id: String; public let name: String
    public let pathLower: String; public let pathDisplay: String
    public let rev: String; public let size: Int64
    public let contentHash: String?
    public let clientModified: Date; public let serverModified: Date
    public let symlinkTarget: String?
    public let isDownloadable: Bool
    public let modifiedBy: String?     // account id, when shared
}
public struct RemoteFolder: Sendable, Equatable {
    public let id: String; public let name: String
    public let pathLower: String; public let pathDisplay: String
}
public struct RemoteDeleted: Sendable, Equatable {
    public let name: String; public let pathLower: String; public let pathDisplay: String
}
public enum RemoteMetadata: Sendable, Equatable {
    case file(RemoteFile), folder(RemoteFolder), deleted(RemoteDeleted)
    public var pathLower: String { ... }   // convenience accessors
}
public struct ListPage: Sendable { public let entries: [RemoteMetadata]; public let cursor: String; public let hasMore: Bool }
public enum WriteMode: Sendable, Equatable { case add, overwrite, update(rev: String) }
public struct AccountInfo: Sendable, Equatable {
    public let accountId: String; public let displayName: String; public let email: String
    public let accountType: String      // "basic" | "pro" | "business"
    public let isTeam: Bool             // true → reject at link (decisions D4)
    public let profilePhotoURL: URL?
}
public struct SpaceUsage: Sendable, Equatable { public let used: Int64; public let allocated: Int64 }

public protocol DropboxService: Sendable {
    func currentAccount() async throws -> AccountInfo
    func spaceUsage() async throws -> SpaceUsage
    func listFolder(path: String, recursive: Bool) async throws -> ListPage
    func listFolderContinue(cursor: String) async throws -> ListPage
    func longpoll(cursor: String, timeout: Int) async throws -> (changes: Bool, backoff: Int?)
    func metadata(path: String, includeDeleted: Bool) async throws -> RemoteMetadata?  // nil = not_found
    /// Downloads `rev:` to `localURL` (streaming), verifying content hash; retries per api-notes §5.
    func download(rev: String, to localURL: URL, progress: @escaping @Sendable (Int64) -> Void) async throws -> RemoteFile
    /// Single-call ≤ 4 MiB, upload sessions above (4 MiB chunks); per-chunk contentHash; per api-notes §2/§6.
    func upload(from localURL: URL, to dbxPath: String, mode: WriteMode, autorename: Bool,
                clientModified: Date, progress: @escaping @Sendable (Int64) -> Void) async throws -> RemoteFile
    func delete(path: String, parentRev: String?) async throws
    func move(from: String, to: String, autorename: Bool) async throws -> RemoteMetadata
    func createFolder(path: String, autorename: Bool) async throws -> RemoteFolder
    func revokeToken() async throws
}
```

```swift
public enum DropboxServiceError: Error, Sendable, Equatable {
    case notFound(path: String)
    case conflict(path: String)              // file/folder/file_ancestor conflicts
    case notAuthorized                       // invalid/revoked token → force re-link
    case insufficientSpace
    case restrictedContent(path: String)
    case disallowedName(path: String)
    case malformedPath(path: String)
    case tooManyWriteOperations              // retryable namespace contention
    case rateLimited(retryAfter: TimeInterval)
    case dataCorrupted(path: String)         // hash mismatch after retries
    case fileChangedDuringUpload(path: String)
    case connection                          // offline / timeouts / 5xx after retries
    case cursorReset                         // listFolderContinue "reset" → full reindex
    case other(message: String)
}
```

- [ ] TDD model conveniences (pathLower accessor, `RemoteMetadata` equality).
- [ ] Commit.

### Task 2.2: Mock service

**Files:** create `AusterCore/Sources/AusterCore/Client/MockDropboxService.swift`
(in the main target so scenario tests in later phases can grow it into
`FakeRemote`); tests `Tests/.../MockDropboxServiceTests.swift`.

**Interfaces produced:** `public final class MockDropboxService: DropboxService`
— an in-memory Dropbox: dictionary of pathLower → (metadata, content), a rev
counter, cursor = monotonically increasing change-log position; implements
list/continue over the change log, autorename semantics (`" (2)"`, conflicted
copies for `.update` mismatches per api-notes §2), `parentRev`-guarded deletes.
Configurable per-call error injection: `mock.failNext(.upload, with: .connection)`.

- [ ] TDD the fake's own semantics (they're the contract later scenario tests
  trust): add→list shows entry; update with stale rev + autorename → server-style
  conflicted copy name; delete with wrong parentRev → `.conflict`; continue after
  changes returns only the delta; move reports delete+add in the change log
  (mirrors real Dropbox — moves are never reported as moves, api-notes §3).
- [ ] Commit.

### Task 2.3: Content hasher + live service

**Files:** create `FileSystem/ContentHasher.swift`,
`Client/LiveDropboxService.swift`, `Client/Retry.swift`;
tests `Tests/.../ContentHasherTests.swift`, `Tests/.../RetryTests.swift`.

**Interfaces produced (also used by Phases 3–5):**

```swift
public enum ContentHasher {
    public static let blockSize = 4 * 1024 * 1024
    public static func hash(fileAt: URL) throws -> String            // streaming, CryptoKit (api-notes §4)
    public static func hash(data: Data) -> String
    public struct Streaming { public mutating func update(_ chunk: Data); public func finalize() -> String }
}
```

- [ ] TDD `ContentHasher` against the api-notes §4 algorithm: empty file,
  < 4 MiB, exactly 4 MiB, 4 MiB + 1 — compute expected values with a tiny
  reference implementation inside the test (SHA256 per block, concatenate raw
  digests, SHA256 again). `Streaming` must equal the whole-file result across
  uneven chunk boundaries. (Phase 9's integration suite cross-checks against a
  real upload's server `contentHash`.) Commit.

- [ ] `Retry.swift`: `func withRetry<T>(policy:operation:)` — exponential backoff
  + jitter; honors `.rateLimited(retryAfter:)` and longpoll `backoff`; max 10
  attempts for `.dataCorrupted`/`.tooManyWriteOperations`, no retry for
  `.notFound`/`.notAuthorized`/etc. TDD with a fake clock.
- [ ] `LiveDropboxService` wraps `DropboxClient` (injected), converting callbacks
  to async via continuations and `CallError` → `DropboxServiceError` (mapping per
  api-notes §5). Upload implements the 4 MiB single-call/session split with
  mid-upload change detection (stat before/after read → throw
  `.fileChangedDuringUpload`). Download streams to the target URL feeding
  `ContentHasher.Streaming` on the fly; on final mismatch with metadata's
  `contentHash`, delete the partial file and throw `.dataCorrupted` (the retry
  layer re-attempts up to 10×).
- [ ] Error-mapping unit tests (construct SDK error values → assert mapped enum).
  Live network calls are NOT unit-tested; covered by Phase 9 integration suite.
- [ ] Commit.

### Task 2.4: Auth manager + app wiring

**Files:** create `AusterCore/Sources/AusterCore/Auth/AuthManager.swift`;
modify `Auster/AusterApp.swift`; create `Auster/Support/AppKey.swift`;
tests `Tests/.../AuthManagerTests.swift`.

**Interfaces produced:**

```swift
@MainActor public final class AuthManager {   // thin; SDK owns keychain state
    public var isLinked: Bool { get }         // DropboxClientsManager.authorizedClient != nil
    public func beginLink()                    // authorizeFromControllerV2 (opens browser)
    public func handleRedirect(url: URL) async -> LinkOutcome
    public func unlink() async                 // revoke + unlinkClients
}
public enum LinkOutcome: Equatable { case linked(AccountInfo), cancelled, teamAccountNotSupported, failed(String) }
```

- [ ] App: `DropboxClientsManager.setupWithAppKeyDesktop(AppKey.value)` at launch
  (`AppKey` reads Info.plist value injected from xcconfig; fatal, user-visible
  alert if placeholder). `.onOpenURL` → `handleRedirect`.
- [ ] `handleRedirect`: on success fetch `currentAccount()`; if `isTeam` →
  `unlink()` and return `.teamAccountNotSupported` (UI copy: "**Not supported**:
  Auster does not support Dropbox team accounts.").
- [ ] Temporary debug UI in the MenuBarExtra window: Link/Unlink button + linked
  account email label (replaced in Phase 8).
- [ ] TDD outcome logic with mock service (team rejection, cancel). Manual check
  with Josh's key: link → email appears; unlink → back to link button. Commit.

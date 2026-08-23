import AusterCore
import Foundation
import SwiftyDropbox
import Testing

/// A real Dropbox account, a real network, and a scoped place to make a mess
/// (api-notes §7).
///
/// Everything else in Auster's test suite runs against `MockDropboxService`,
/// which is a *model* of Dropbox. This target exists to check the model: the
/// places where the mock says Dropbox behaves surprisingly — conflicted copies
/// on a stale rev, tombstones that do not say what they buried, content hashes
/// that have to match ours byte for byte — are exactly the places where being
/// wrong would be invisible until a user lost a file.
///
/// It is opt-in, and it is opt-in twice over: `AUSTER_INTEGRATION=1` says the
/// caller means it, and a credential says they have somewhere to run it. Without
/// both, every test here reports as skipped rather than failing, so `swift test`
/// stays green on a machine with no Dropbox account.
enum IntegrationHarness {

    /// Everything this suite creates lives under here, and nothing outside it is
    /// ever touched. Deleting a real user's files is not a bug this suite is
    /// allowed to have.
    static let remoteRoot = "/AusterIntegrationTests"

    // MARK: - Enablement

    /// Whether the caller asked for these tests at all.
    static var isRequested: Bool {
        ProcessInfo.processInfo.environment["AUSTER_INTEGRATION"] == "1"
    }

    /// Requested *and* able to authenticate.
    static var isEnabled: Bool {
        isRequested && credentials != nil
    }

    /// Why the suite is not running, for a human reading the test log.
    static var skipReason: Comment {
        Comment(rawValue: skipReasonText)
    }

    private static var skipReasonText: String {
        if !isRequested {
            return "set AUSTER_INTEGRATION=1 to run the integration suite"
        }
        return """
            AUSTER_INTEGRATION=1 is set but no credential was found. Provide either \
            AUSTER_TEST_TOKEN (a Dropbox access token), or AUSTER_TEST_REFRESH_TOKEN \
            together with AUSTER_APP_KEY.
            """
    }

    /// How the suite authenticates, in the order it looks.
    private enum Credentials {

        /// A plain access token — the simplest thing to paste into a shell.
        case accessToken(String)

        /// A refresh token and the app key it belongs to, for a credential that
        /// does not expire after four hours.
        case refreshToken(token: String, appKey: String)
    }

    private static var credentials: Credentials? {
        let environment = ProcessInfo.processInfo.environment

        if let token = environment["AUSTER_TEST_TOKEN"]?.trimmed, !token.isEmpty {
            return .accessToken(token)
        }
        if let refresh = environment["AUSTER_TEST_REFRESH_TOKEN"]?.trimmed, !refresh.isEmpty,
            let appKey = environment["AUSTER_APP_KEY"]?.trimmed, !appKey.isEmpty
        {
            return .refreshToken(token: refresh, appKey: appKey)
        }
        return nil
    }

    // MARK: - The service

    /// A live service for the configured credential.
    ///
    /// Built per call rather than shared: `swift-testing` runs tests in
    /// parallel, and a `DropboxClient` per test keeps one test's retry backoff
    /// from being another's.
    static func makeService() throws -> any DropboxService {
        guard let credentials else {
            throw IntegrationError.notConfigured(skipReasonText)
        }

        switch credentials {
        case .accessToken(let token):
            return LiveDropboxService(client: DropboxClient(accessToken: token))

        case .refreshToken(let token, let appKey):
            // A refresh token alone is not a credential the SDK can call with;
            // it needs the OAuth manager that knows how to exchange it.
            let oauth = DropboxOAuthManager(
                appKey: appKey,
                secureStorageAccess: SecureStorageAccessDefaultImpl()
            )
            let accessToken = DropboxAccessToken(
                accessToken: "",
                uid: "auster-integration",
                refreshToken: token,
                tokenExpirationTimestamp: 0
            )
            return LiveDropboxService(
                client: DropboxClient(accessToken: accessToken, dropboxOauthManager: oauth)
            )
        }
    }

    enum IntegrationError: Error, CustomStringConvertible {
        case notConfigured(String)

        var description: String {
            switch self {
            case .notConfigured(let reason): reason
            }
        }
    }
}

extension String {
    fileprivate var trimmed: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// One test's own remote folder and local scratch directory, removed on the way
/// out however the test ended.
///
/// A class so `deinit` can do the cleanup: a `defer` in every test is one place
/// to forget, and what gets forgotten here is a folder in somebody's real
/// Dropbox.
final class IntegrationScope {

    let service: any DropboxService

    /// `/AusterIntegrationTests/<uuid>` — unique per test, so parallel runs and
    /// abandoned runs never collide.
    let remotePath: String

    /// A local temp directory, for staging downloads and hashing.
    let localRoot: URL

    /// Builds a scope whose remote folder already exists.
    ///
    /// Dropbox creates parent folders implicitly on upload, so a scope that only
    /// ever uploads would not need this — but listing a folder that has never
    /// been written to answers `path/not_found`, not an empty page, so a test
    /// that lists before it writes needs the folder to be there.
    static func make() async throws -> IntegrationScope {
        let scope = try IntegrationScope()
        _ = try await scope.service.createFolder(path: scope.remotePath, autorename: false)
        return scope
    }

    init() throws {
        service = try IntegrationHarness.makeService()
        remotePath = "\(IntegrationHarness.remoteRoot)/\(UUID().uuidString)"
        localRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("auster-integration-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: localRoot, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: localRoot)

        // The remote folder outlives the process unless something removes it, so
        // this runs even when the test failed — a leaked folder would be found
        // by the next person to open Dropbox, not by CI.
        let service = service
        let remotePath = remotePath
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            try? await service.delete(path: remotePath, parentRev: nil)
            done.signal()
        }
        _ = done.wait(timeout: .now() + 30)
    }

    // MARK: - Paths

    /// A path inside this test's remote folder.
    func remote(_ name: String) -> String {
        "\(remotePath)/\(name)"
    }

    func local(_ name: String) -> URL {
        localRoot.appendingPathComponent(name, isDirectory: false)
    }

    // MARK: - Convenience

    /// `autorename` defaults to `true` because that is what `UploadApplier`
    /// sends on every upload it makes. It is the difference between Dropbox
    /// refusing a stale-rev write and Dropbox writing a conflicted copy beside
    /// the original, so a harness that defaulted the other way would be testing
    /// a call the engine never issues (note N39).
    @discardableResult
    func upload(
        _ name: String,
        contents: Data,
        mode: WriteMode = .add,
        autorename: Bool = true
    ) async throws -> RemoteFile {
        let source = local("upload-\(UUID().uuidString)")
        try contents.write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }

        return try await service.upload(
            from: source,
            to: remote(name),
            mode: mode,
            autorename: autorename,
            clientModified: Date(timeIntervalSince1970: 1_700_000_000),
            progress: { _ in }
        )
    }

    func download(rev: String, as name: String) async throws -> (RemoteFile, Data) {
        let destination = local("download-\(UUID().uuidString)-\(name)")
        let file = try await service.download(rev: rev, to: destination, progress: { _ in })
        return (file, try Data(contentsOf: destination))
    }

    /// Every entry directly inside this test's folder, by lowercased path.
    func listing() async throws -> [String: RemoteMetadata] {
        var page = try await service.listFolder(path: remotePath, recursive: false)
        var entries = page.entries
        while page.hasMore {
            page = try await service.listFolderContinue(cursor: page.cursor)
            entries.append(contentsOf: page.entries)
        }
        return Dictionary(entries.map { ($0.pathLower, $0) }, uniquingKeysWith: { _, last in last })
    }
}

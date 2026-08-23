import GRDB
import SwiftyDropbox
import Testing

@testable import AusterCore

/// Exercises dependency resolution: if this target compiles, SwiftyDropbox and
/// GRDB resolved and the `AusterCore` library builds against them.
@Suite("Smoke")
struct SmokeTests {

    @Test("AusterCore exposes its bundle identity")
    func coreIdentity() {
        #expect(AusterCore.bundleIdentifier == "com.itsjoshpark.Auster")
        #expect(AusterCore.cacheDirectoryName == ".auster.cache")
    }

    @Test("GRDB is linked and usable in memory")
    func grdbIsLinked() throws {
        let queue = try DatabaseQueue()
        let answer = try queue.read { db in
            try Int.fetchOne(db, sql: "SELECT 1 + 1")
        }
        #expect(answer == 2)
    }

    @Test("SwiftyDropbox is linked and serializes its route types")
    func swiftyDropboxIsLinked() {
        // `update` is the write mode every guarded upload uses (decisions.md D9.5).
        #expect(Files.WriteMode.update("abc123").description.contains("abc123"))
    }
}

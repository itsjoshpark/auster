import Testing

@testable import Auster

/// App-target tests. The bulk of Auster's coverage lives in `AusterCoreTests`;
/// this target exists for the thin view-model layer (Phase 8) and to give the
/// `Auster` scheme a test action.
@Suite("App shell")
struct AppShellTests {

    @Test("Menu bar placeholder builds")
    func menuBarContentViewBuilds() {
        _ = MenuBarContentView()
    }
}

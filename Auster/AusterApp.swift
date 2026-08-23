import AusterCore
import SwiftUI

/// Auster's entry point.
///
/// The app is a menu-bar-only agent (`LSUIElement`): a `MenuBarExtra` in window
/// style plus a `Settings` scene. All sync logic lives in `AusterCore`; this
/// target only renders state and forwards user intent.
@main
struct AusterApp: App {

    var body: some Scene {
        MenuBarExtra("Auster", systemImage: "checkmark.circle") {
            MenuBarContentView()
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsPlaceholderView()
        }
    }
}

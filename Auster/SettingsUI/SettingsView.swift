import AusterCore
import SwiftUI

/// The Settings scene (ux §4).
///
/// Maestral used one long window of sections; Auster uses the native tabbed
/// `Settings` scene with the same content, reorganized so that the two
/// destructive controls — moving the folder and unlinking — are not next to the
/// switches nobody thinks twice about.
struct SettingsView: View {

    @Bindable var environment: AppEnvironment

    var body: some View {
        TabView {
            GeneralTab(environment: environment, settings: environment.settings)
                .tabItem { Label("General", systemImage: "gearshape") }

            SelectiveSyncTab(environment: environment)
                .tabItem { Label("Selective Sync", systemImage: "folder.badge.gearshape") }

            AccountTab(environment: environment)
                .tabItem { Label("Account", systemImage: "person.crop.circle") }

            AboutTab(environment: environment)
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 480, height: 380)
    }
}

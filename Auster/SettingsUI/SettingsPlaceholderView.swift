import AusterCore
import SwiftUI

/// Placeholder settings body.
///
/// Phase 8 replaces this with the General / Selective Sync / Account / About
/// tabs. Until then it carries the one pane that already exists, so selective
/// sync can be exercised against a real account.
struct SettingsPlaceholderView: View {

    @Bindable var environment: AppEnvironment

    var body: some View {
        SelectiveSyncEditor(environment: environment)
            .padding()
            .frame(width: 460, height: 380)
    }
}

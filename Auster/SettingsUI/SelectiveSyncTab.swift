import AusterCore
import SwiftUI

/// The folder tree, embedded (ux §4, §5).
struct SelectiveSyncTab: View {

    @Bindable var environment: AppEnvironment

    var body: some View {
        SelectiveSyncEditor(environment: environment)
            .padding()
    }
}

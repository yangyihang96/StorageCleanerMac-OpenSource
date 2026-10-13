import SwiftUI

extension SettingsView {
    var miniWindowSettings: some View {
        MiniWindowConfigurationSettingsView(draft: $miniWindowDraft)
    }
}

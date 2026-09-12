import AppKit
import Foundation

@MainActor
enum PrivacySystemSettingsOpener {
    static func openFullDiskAccess() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"
        ) else { return }
        NSWorkspace.shared.open(url)
    }
}

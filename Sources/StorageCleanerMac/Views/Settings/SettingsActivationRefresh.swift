import AppKit
import SwiftUI

struct SettingsActivationRefresh: ViewModifier {
    let isVisible: Bool
    let category: SettingsCategory
    let refresh: () -> Void

    static func shouldRefresh(isVisible: Bool, category: SettingsCategory) -> Bool {
        isVisible && [.general, .accessAndSetup, .systemControl].contains(category)
    }

    func body(content: Content) -> some View {
        content.onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            guard Self.shouldRefresh(isVisible: isVisible, category: category) else { return }
            refresh()
        }
    }
}

/// Coalesce activation notifications, but never drop the one received during
/// an in-flight permission read. The follow-up reads after the user's return.
struct SettingsAccessRefreshGate {
    private(set) var isChecking = false
    private var needsFollowUp = false

    mutating func request() -> Bool {
        if isChecking {
            needsFollowUp = true
            return false
        }
        isChecking = true
        return true
    }

    mutating func finish() -> Bool {
        guard isChecking else { return false }
        if needsFollowUp {
            needsFollowUp = false
            return true
        }
        isChecking = false
        return false
    }
}

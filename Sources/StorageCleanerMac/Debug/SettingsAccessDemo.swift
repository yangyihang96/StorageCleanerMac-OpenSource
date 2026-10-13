#if DEBUG
import Foundation

/// Explicit screenshot fixture, never a grant or a hardware connection.
/// Release has no argument parser and no simulated permission state.
enum SettingsAccessDemo: String, CaseIterable {
    case pending, granted, unknown

    static func resolve(arguments: [String]) -> Self? {
        guard let argument = arguments.first(where: { $0.hasPrefix("--debug-settings-access=") }) else { return nil }
        return Self(rawValue: String(argument.dropFirst("--debug-settings-access=".count)))
    }

    static var current: Self? { resolve(arguments: ProcessInfo.processInfo.arguments) }

    var diskState: FullDiskAccessState {
        switch self { case .pending: .notVerified; case .granted: .verified; case .unknown: .unknown }
    }
    var notificationsAuthorized: Bool { self == .granted }
    var diskTitle: String {
        switch self {
        case .pending: L10n.text("待授权", "Awaiting Access")
        case .granted: L10n.text("已授权", "Granted")
        case .unknown: L10n.text("无法判断", "Unknown")
        }
    }
    var helperTitle: String {
        self == .granted ? L10n.text("已批准运行中（演示）", "Approved and Connected (Demo)")
            : L10n.text("等待批准（演示）", "Awaiting Approval (Demo)")
    }
}
#endif

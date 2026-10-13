import Foundation
import Security

/// Both checks precede any PhotoKit call; signing and bundle metadata are immutable for this process.
enum PhotoLibraryAvailability {
    static func isEnabled(info: [String: Any]?, entitlement: Bool) -> Bool {
        guard let usage = info?["NSPhotoLibraryUsageDescription"] as? String,
              !usage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        return entitlement
    }
    static let isEnabledInMainBundle: Bool = {
        let info = Bundle.main.infoDictionary
        guard isEnabled(info: info, entitlement: true), let task = SecTaskCreateFromSelf(nil) else { return false }
        let value = SecTaskCopyValueForEntitlement(task, "com.apple.security.personal-information.photos-library" as CFString, nil)
        return isEnabled(info: info, entitlement: value as? Bool == true)
    }()
}

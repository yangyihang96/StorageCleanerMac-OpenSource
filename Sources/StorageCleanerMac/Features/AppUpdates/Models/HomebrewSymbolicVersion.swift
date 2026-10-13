import Foundation

enum HomebrewSymbolicVersion {
    static func isLatest(_ value: String?) -> Bool {
        guard let value else { return false }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return trimmed == "latest" || trimmed == ":latest"
    }
}

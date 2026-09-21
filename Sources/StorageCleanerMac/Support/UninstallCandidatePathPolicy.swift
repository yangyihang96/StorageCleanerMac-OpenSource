import Foundation

/// Generates conservative candidates, not proof of exclusive ownership.
/// Display names and shared app-group containers are deliberately excluded.
enum UninstallCandidatePathPolicy {
    static func isSafeComponent(_ value: String) -> Bool {
        // CFBundleIdentifier permits ASCII letters, digits, hyphens and periods.
        // Validate bytes directly: an identifier is not a display name or path.
        guard !value.isEmpty, value != ".", value != ".." else { return false }
        for byte in value.utf8 {
            switch byte {
            case 48...57, 65...90, 97...122, 45, 46: continue
            default: return false
            }
        }
        return true
    }

    static func candidateURLs(bundleIdentifier: String, homeDirectory: URL) -> [URL] {
        guard homeDirectory.isFileURL, isSafeComponent(bundleIdentifier) else { return [] }
        let library = homeDirectory.standardizedFileURL
            .appendingPathComponent("Library", isDirectory: true)
        return [
            library.appendingPathComponent("Application Support", isDirectory: true)
                .appendingPathComponent(bundleIdentifier),
            library.appendingPathComponent("Caches", isDirectory: true)
                .appendingPathComponent(bundleIdentifier),
            library.appendingPathComponent("Preferences", isDirectory: true)
                .appendingPathComponent(bundleIdentifier + ".plist"),
            library.appendingPathComponent("Containers", isDirectory: true)
                .appendingPathComponent(bundleIdentifier),
        ]
    }
}

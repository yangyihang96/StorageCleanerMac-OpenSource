import Foundation

/// Settings guards cover the root and every extracted production page.
/// Other source reads retain their original single-file scope.
enum SettingsSourceContract {
    static func source(at url: URL) throws -> String {
        let root = try String(contentsOf: url, encoding: .utf8)
        guard url.standardizedFileURL.path.hasSuffix(
            "/Sources/StorageCleanerMac/Views/SettingsView.swift"
        ) else { return root }

        let directory = url.deletingLastPathComponent().appendingPathComponent("Settings", isDirectory: true)
        let pages = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )
            .filter { $0.pathExtension == "swift" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        let pageSources = try pages.map { try String(contentsOf: $0, encoding: .utf8) }
        return ([root] + pageSources).joined(separator: "\n")
    }

    /// A contract spanning several declarations must name each one explicitly,
    /// rather than depend on adjacency across extracted page files.
    static func declarations(_ markers: [String], in source: String) throws -> String {
        try markers.map { try r2SourceDeclaration($0, in: source) }.joined(separator: "\n")
    }
}

import Foundation

enum SystemApplicationPolicy {
    private static let protectedRoots = [
        "/System",
        "/Library/Apple/System",
    ]

    static func isSystemManaged(_ application: InstalledApplication) -> Bool {
        application.isSystemApplication
            || application.installationSource == .system
            || isSystemManaged(url: application.bundleURL)
    }

    static func isSystemManaged(url: URL) -> Bool {
        let standardizedURL = url.standardizedFileURL
        let paths = Set([
            standardizedURL.path,
            standardizedURL.resolvingSymlinksInPath().path,
        ])
        if paths.contains("/Applications/Safari.app") { return true }
        return paths.contains { path in
            protectedRoots.contains { root in
                path == root || path.hasPrefix(root + "/")
            }
        }
    }
}

enum ApplicationIconSourceResolver {
    static func applicationBundleURL(
        for application: InstalledApplication,
        fileManager: FileManager = .default
    ) -> URL? {
        let candidates = [application.bundleURL]
            + (application.homebrewMetadata?.appBundlePaths.map {
                URL(fileURLWithPath: $0, isDirectory: true)
            } ?? [])
            + application.duplicateLocations

        return candidates.first { candidate in
            candidate.pathExtension.caseInsensitiveCompare("app") == .orderedSame
                && fileManager.fileExists(atPath: candidate.path)
        }
    }

    static func sourceURL(
        for application: InstalledApplication,
        fileManager: FileManager = .default
    ) -> URL {
        applicationBundleURL(for: application, fileManager: fileManager)
            ?? application.bundleURL
    }
}

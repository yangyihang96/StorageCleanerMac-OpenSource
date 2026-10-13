import FanControlShared
import Foundation

enum AppDataDirectories {
    static var applicationSupportRoot: URL {
        applicationSupportRoot(fileManager: .default)
    }

    static func applicationSupportRoot(fileManager: FileManager) -> URL {
        if let url = integrationRoot(fileManager: fileManager) { return url }
        let base = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        return base.appendingPathComponent(
            StorageCleanerBuildIdentity.applicationSupportDirectoryName,
            isDirectory: true
        )
    }

    /// True only while the isolated local QA bundle's override is in effect.
    static var isUsingIntegrationRoot: Bool {
        integrationRoot(fileManager: .default) != nil
    }

    // Explicit isolated local QA bundle only; installed Debug/Release/Beta
    // applications never accept this override.
    static func integrationRoot(
        fileManager: FileManager,
        bundleIdentifier: String? = Bundle.main.bundleIdentifier,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL? {
        guard bundleIdentifier == "com.local.StorageCleanerMac.integration",
              let raw = environment["STORAGE_CLEANER_INTEGRATION_ROOT"] else { return nil }
        let url = URL(fileURLWithPath: raw, isDirectory: true)
        let cacheRoot = fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches").path
        guard raw == url.standardizedFileURL.path,
              url.deletingLastPathComponent().path == cacheRoot,
              url.lastPathComponent.hasPrefix("StorageCleanerIntegration-") else { return nil }
        return url
    }

    static func applicationSupportDirectoryName(isBeta: Bool) -> String {
        isBeta ? "StorageCleanerMac-Beta" : "StorageCleanerMac"
    }
}

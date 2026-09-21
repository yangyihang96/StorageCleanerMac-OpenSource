import FanControlShared
import Foundation

enum AppDataDirectories {
    static var applicationSupportRoot: URL {
        applicationSupportRoot(fileManager: .default)
    }

    static func applicationSupportRoot(fileManager: FileManager) -> URL {
        // Explicit isolated local QA bundle only; installed Debug/Release/Beta
        // applications never accept this override.
        if Bundle.main.bundleIdentifier == "com.local.StorageCleanerMac.integration",
           let raw = ProcessInfo.processInfo.environment["STORAGE_CLEANER_INTEGRATION_ROOT"] {
            let url = URL(fileURLWithPath: raw, isDirectory: true)
            let cacheRoot = fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches").path
            if raw == url.standardizedFileURL.path,
               url.deletingLastPathComponent().path == cacheRoot,
               url.lastPathComponent.hasPrefix("StorageCleanerIntegration-") {
                return url
            }
        }
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

    static func applicationSupportDirectoryName(isBeta: Bool) -> String {
        isBeta ? "StorageCleanerMac-Beta" : "StorageCleanerMac"
    }
}

import FanControlShared
import Foundation

enum AppDataDirectories {
    static var applicationSupportRoot: URL {
        applicationSupportRoot(fileManager: .default)
    }

    static func applicationSupportRoot(fileManager: FileManager) -> URL {
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

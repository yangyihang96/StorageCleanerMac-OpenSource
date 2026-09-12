import Foundation

struct InstalledAppCopy: Equatable, Sendable {
    let url: URL
    let bundleIdentifier: String
    let version: String?
    let build: String?
    let resourceIdentity: String

    var versionDisplay: String {
        switch (version?.nonEmpty, build?.nonEmpty) {
        case let (version?, build?):
            "\(version) (\(build))"
        case let (version?, nil):
            version
        case let (nil, build?):
            build
        case (nil, nil):
            L10n.text("未知版本", "Unknown version")
        }
    }
}

struct AppInstallationConflict: Equatable, Identifiable, Sendable {
    let canonicalCopy: InstalledAppCopy
    let legacyCopy: InstalledAppCopy
    let currentRuntimePath: String

    var id: String { fingerprint }

    var copies: [InstalledAppCopy] {
        [canonicalCopy, legacyCopy]
    }

    var fingerprint: String {
        copies
            .sorted { $0.url.path < $1.url.path }
            .map { copy in
                [
                    copy.url.standardizedFileURL.path,
                    copy.bundleIdentifier,
                    copy.version?.nonEmpty ?? "-",
                    copy.build?.nonEmpty ?? "-",
                    copy.resourceIdentity
                ].joined(separator: "|")
            }
            .joined(separator: "\n")
    }
}

enum AppInstallationConflictService {
    static let canonicalApplicationURL = URL(fileURLWithPath: "/Applications/存储清理助手.app", isDirectory: true)
    static let legacyApplicationURL = URL(fileURLWithPath: "/Applications/StorageCleanerMac.app", isDirectory: true)

    static func detect(
        mainBundle: Bundle = .main,
        fileManager: FileManager = .default
    ) -> AppInstallationConflict? {
        guard let expectedBundleIdentifier = mainBundle.bundleIdentifier?.nonEmpty else {
            return nil
        }

        return detect(
            expectedBundleIdentifier: expectedBundleIdentifier,
            currentBundleURL: mainBundle.bundleURL,
            canonicalURL: canonicalApplicationURL,
            legacyURL: legacyApplicationURL,
            fileManager: fileManager
        )
    }

    static func detect(
        expectedBundleIdentifier: String,
        currentBundleURL: URL,
        canonicalURL: URL,
        legacyURL: URL,
        fileManager: FileManager = .default
    ) -> AppInstallationConflict? {
        guard
            let canonicalCopy = installedCopy(at: canonicalURL, fileManager: fileManager),
            let legacyCopy = installedCopy(at: legacyURL, fileManager: fileManager),
            canonicalCopy.bundleIdentifier == expectedBundleIdentifier,
            legacyCopy.bundleIdentifier == expectedBundleIdentifier,
            canonicalCopy.resourceIdentity != legacyCopy.resourceIdentity
        else {
            return nil
        }

        return AppInstallationConflict(
            canonicalCopy: canonicalCopy,
            legacyCopy: legacyCopy,
            currentRuntimePath: currentBundleURL.standardizedFileURL.path
        )
    }

    private static func installedCopy(
        at url: URL,
        fileManager: FileManager
    ) -> InstalledAppCopy? {
        var isDirectory: ObjCBool = false
        guard
            fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory),
            isDirectory.boolValue
        else {
            return nil
        }

        let infoURL = url.appendingPathComponent("Contents/Info.plist", isDirectory: false)
        guard
            let data = try? Data(contentsOf: infoURL),
            let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
            let bundleIdentifier = (info["CFBundleIdentifier"] as? String)?.nonEmpty
        else {
            return nil
        }

        return InstalledAppCopy(
            url: url.standardizedFileURL,
            bundleIdentifier: bundleIdentifier,
            version: (info["CFBundleShortVersionString"] as? String)?.nonEmpty,
            build: (info["CFBundleVersion"] as? String)?.nonEmpty,
            resourceIdentity: resourceIdentity(for: url, fileManager: fileManager)
        )
    }

    private static func resourceIdentity(for url: URL, fileManager: FileManager) -> String {
        let resolvedURL = url.resolvingSymlinksInPath().standardizedFileURL
        guard let attributes = try? fileManager.attributesOfItem(atPath: resolvedURL.path) else {
            return resolvedURL.path
        }

        let device = (attributes[.systemNumber] as? NSNumber)?.uint64Value
        let inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value
        guard let device, let inode else {
            return resolvedURL.path
        }
        return "\(resolvedURL.path)|\(device):\(inode)"
    }
}

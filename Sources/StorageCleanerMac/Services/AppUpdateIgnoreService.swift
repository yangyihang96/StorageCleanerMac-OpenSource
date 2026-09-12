import Foundation

enum AppUpdateIgnoreService {
    private static let storageKey = "appUpdateIgnoredLatestVersions"

    static func ignore(_ app: AppUpdateItem, defaults: UserDefaults = .standard) {
        guard let latestVersion = latestVersionKey(for: app) else { return }
        var versions = ignoredVersions(defaults: defaults)
        versions[identifier(for: app)] = latestVersion
        defaults.set(versions, forKey: storageKey)
    }

    static func isIgnored(_ app: AppUpdateItem, defaults: UserDefaults = .standard) -> Bool {
        guard let latestVersion = latestVersionKey(for: app) else { return false }
        return ignoredVersions(defaults: defaults)[identifier(for: app)] == latestVersion
    }

    static func clear(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: storageKey)
    }

    static func ignoredVersions(defaults: UserDefaults = .standard) -> [String: String] {
        defaults.dictionary(forKey: storageKey) as? [String: String] ?? [:]
    }

    private static func identifier(for app: AppUpdateItem) -> String {
        let bundleIdentifier = app.bundleIdentifier.trimmed
        let path = PathSafety.normalizedPath(app.path)
        return bundleIdentifier.isEmpty ? path : "\(bundleIdentifier)|\(path)"
    }

    private static func latestVersionKey(for app: AppUpdateItem) -> String? {
        let latestVersion = app.latestVersion?.trimmed ?? ""
        return latestVersion.isEmpty ? nil : latestVersion
    }
}

import Foundation

enum AppUpdateIgnoreService {
    private static let lock = NSRecursiveLock()
    private static let storageKey = "appUpdateIgnoredLatestVersions"

    static func ignore(_ app: AppUpdateItem, defaults: UserDefaults = .standard) {
        lock.lock(); defer { lock.unlock() }
        guard let latestVersion = latestVersionKey(for: app) else { return }
        var versions = ignoredVersions(defaults: defaults)
        versions[identifier(for: app)] = latestVersion
        defaults.set(versions, forKey: storageKey)
        notifyChange()
    }

    static func isIgnored(_ app: AppUpdateItem, defaults: UserDefaults = .standard) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let latestVersion = latestVersionKey(for: app) else { return false }
        return ignoredVersions(defaults: defaults)[identifier(for: app)] == latestVersion
    }

    static func clear(defaults: UserDefaults = .standard) {
        lock.lock(); defer { lock.unlock() }
        defaults.removeObject(forKey: storageKey)
        notifyChange()
    }

    static func ignoredVersions(defaults: UserDefaults = .standard) -> [String: String] {
        lock.lock(); defer { lock.unlock() }
        return defaults.dictionary(forKey: storageKey) as? [String: String] ?? [:]
    }

    static func identifier(for app: AppUpdateItem) -> String {
        identifier(bundleIdentifier: app.bundleIdentifier, path: app.path)
    }

    static func identifier(bundleIdentifier: String, path: String) -> String {
        let bundleIdentifier = bundleIdentifier.trimmed
        let path = PathSafety.normalizedPath(path)
        return bundleIdentifier.isEmpty ? path : "\(bundleIdentifier)|\(path)"
    }

    static func remove(identifier: String, defaults: UserDefaults = .standard) {
        lock.lock(); defer { lock.unlock() }
        var versions = ignoredVersions(defaults: defaults)
        versions.removeValue(forKey: identifier)
        defaults.set(versions, forKey: storageKey)
        notifyChange()
    }

    private static func notifyChange() {
        DispatchQueue.main.async { NotificationCenter.default.post(name: IgnoreListStore.didChange, object: nil) }
    }

    private static func latestVersionKey(for app: AppUpdateItem) -> String? {
        let latestVersion = app.latestVersion?.trimmed ?? ""
        return latestVersion.isEmpty ? nil : latestVersion
    }
}

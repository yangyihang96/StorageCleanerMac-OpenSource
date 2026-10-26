import Foundation

/// Settings → Notifications → Applications / Disk Space in CleanMyMac:
/// “Offer to uninstall applications correctly” (`TrashedApplicationsAlertsEnabled`)
/// and “Notify if Trash size exceeds” (`TrashSizeAlertsEnabled`,
/// `TrashSizeThreshold`). All three default on / 2 GB, the values found in
/// CleanMyMac's own preferences. D220 adds its free-space warning.
struct AppLifecycleReminderPreferencesSnapshot: Equatable, Sendable {
    var offersCorrectUninstall: Bool
    var notifiesTrashSize: Bool
    var trashSizeThresholdBytes: Int64
    /// D220: CleanMyMac's free-space warning (`DiskSpaceAlertsEnabled`,
    /// `DiskSpaceThreshold`), on by default.
    var notifiesLowDiskSpace = true
    var lowDiskSpaceThresholdBytes = AppLifecycleReminderPreferences.defaultLowDiskSpaceThresholdBytes(startupDiskCapacity: nil)
}

enum AppLifecycleReminderPreferences {
    private enum Key {
        static let offersCorrectUninstall = "appLifecycle.offersCorrectUninstall.v1"
        static let notifiesTrashSize = "appLifecycle.notifiesTrashSize.v1"
        static let trashSizeThreshold = "appLifecycle.trashSizeThresholdBytes.v1"
        static let notifiesLowDiskSpace = "appLifecycle.notifiesLowDiskSpace.v1"
        static let lowDiskSpaceThreshold = "appLifecycle.lowDiskSpaceThresholdBytes.v1"
    }

    static let defaultTrashSizeThresholdBytes: Int64 = 2_000_000_000

    /// Choices of the threshold menu (decimal units, as CleanMyMac stores 2 GB
    /// as 2,000,000,000 bytes).
    static let trashSizeThresholdChoices: [Int64] = [
        500_000_000, 1_000_000_000, 2_000_000_000, 3_000_000_000,
        5_000_000_000, 10_000_000_000, 20_000_000_000
    ]

    /// D220: the free-space threshold menu, CleanMyMac's own choices (the
    /// array in its `SharedPreferences`: 2, 5, 10, 20, 30, 50 and 100 GB).
    static let lowDiskSpaceThresholdChoices: [Int64] = [
        2_000_000_000, 5_000_000_000, 10_000_000_000, 20_000_000_000,
        30_000_000_000, 50_000_000_000, 100_000_000_000
    ]

    /// D220: CleanMyMac's `DiskSpaceThreshold` default, read from its
    /// `SharedPreferences`: the choice nearest to a tenth of the startup
    /// disk's capacity (an earlier choice wins a tie), a 1 TB disk assumed
    /// when the capacity cannot be read. 100 GB on 1 TB, 50 GB on 512 GB,
    /// 30 GB on 256 GB.
    static func defaultLowDiskSpaceThresholdBytes(startupDiskCapacity: Int64?) -> Int64 {
        let target = Double((startupDiskCapacity ?? 1_000_000_000_000) / 10)
        var best = lowDiskSpaceThresholdChoices[0]
        for choice in lowDiskSpaceThresholdChoices where abs(Double(choice) - target) < abs(Double(best) - target) {
            best = choice
        }
        return best
    }

    static func startupDiskTotalCapacity() -> Int64? {
        let values = try? URL(fileURLWithPath: "/", isDirectory: true).resourceValues(forKeys: [.volumeTotalCapacityKey])
        return values?.volumeTotalCapacity.map(Int64.init)
    }

    static func snapshot(
        defaults: UserDefaults = .standard,
        startupDiskCapacity: () -> Int64? = { AppLifecycleReminderPreferences.startupDiskTotalCapacity() }
    ) -> AppLifecycleReminderPreferencesSnapshot {
        let storedThreshold = (defaults.object(forKey: Key.trashSizeThreshold) as? NSNumber)?.int64Value
        let storedSpaceThreshold = (defaults.object(forKey: Key.lowDiskSpaceThreshold) as? NSNumber)?.int64Value
        return AppLifecycleReminderPreferencesSnapshot(
            offersCorrectUninstall: bool(Key.offersCorrectUninstall, default: true, defaults: defaults),
            notifiesTrashSize: bool(Key.notifiesTrashSize, default: true, defaults: defaults),
            trashSizeThresholdBytes: storedThreshold.flatMap { $0 > 0 ? $0 : nil } ?? defaultTrashSizeThresholdBytes,
            notifiesLowDiskSpace: bool(Key.notifiesLowDiskSpace, default: true, defaults: defaults),
            lowDiskSpaceThresholdBytes: storedSpaceThreshold.flatMap { $0 > 0 ? $0 : nil }
                ?? defaultLowDiskSpaceThresholdBytes(startupDiskCapacity: startupDiskCapacity())
        )
    }

    static func set(_ snapshot: AppLifecycleReminderPreferencesSnapshot, defaults: UserDefaults = .standard) {
        defaults.set(snapshot.offersCorrectUninstall, forKey: Key.offersCorrectUninstall)
        defaults.set(snapshot.notifiesTrashSize, forKey: Key.notifiesTrashSize)
        defaults.set(NSNumber(value: max(1, snapshot.trashSizeThresholdBytes)), forKey: Key.trashSizeThreshold)
        defaults.set(snapshot.notifiesLowDiskSpace, forKey: Key.notifiesLowDiskSpace)
        defaults.set(NSNumber(value: max(1, snapshot.lowDiskSpaceThresholdBytes)), forKey: Key.lowDiskSpaceThreshold)
        NotificationCenter.default.post(name: didChangeNotification, object: nil)
    }

    static let didChangeNotification = Notification.Name("StorageCleanerMac.AppLifecycleReminderPreferencesDidChange")

    static func thresholdTitle(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .decimal)
    }

    private static func bool(_ key: String, default value: Bool, defaults: UserDefaults) -> Bool {
        defaults.object(forKey: key) == nil ? value : defaults.bool(forKey: key)
    }
}

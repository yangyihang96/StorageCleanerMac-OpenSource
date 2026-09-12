public enum StorageCleanerBuildIdentity {
#if STORAGE_CLEANER_BETA
    public static let isBeta = true
    public static let appBundleIdentifier = "com.local.StorageCleanerMac.beta"
    public static let helperLabel = "com.local.StorageCleanerMac.beta.FanControlHelper"
    public static let applicationSupportDirectoryName = "StorageCleanerMac-Beta"
#else
    public static let isBeta = false
    public static let appBundleIdentifier = "com.local.StorageCleanerMac"
    public static let helperLabel = "com.local.StorageCleanerMac.FanControlHelper"
    public static let applicationSupportDirectoryName = "StorageCleanerMac"
#endif
}

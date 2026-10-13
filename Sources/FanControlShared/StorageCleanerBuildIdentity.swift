public enum StorageCleanerBuildIdentity {
    /// Bundle executable names. They must match `APP_NAME` in
    /// `script/build_and_run.sh` (Beta) and `script/make_release_dmg.sh` (release);
    /// `BuildIdentityPackagingTests` compares them with the scripts.
    public static let releaseExecutableName = "StorageCleanerMac"
    public static let betaExecutableName = "StorageCleanerMacBeta"
    /// Installed locations used for the helper's caller checks.
    public static let releaseInstalledApplicationPath = "/Applications/存储清理助手.app"
    public static let betaInstalledApplicationPath = "/Applications/测试版.app"
#if STORAGE_CLEANER_BETA
    public static let isBeta = true
    public static let appExecutableName = betaExecutableName
    public static let appBundleIdentifier = "com.local.StorageCleanerMac.beta"
    public static let helperLabel = "com.local.StorageCleanerMac.beta.FanControlHelper"
    public static let applicationSupportDirectoryName = "StorageCleanerMac-Beta"
#else
    public static let isBeta = false
    public static let appExecutableName = releaseExecutableName
    public static let appBundleIdentifier = "com.local.StorageCleanerMac"
    public static let helperLabel = "com.local.StorageCleanerMac.FanControlHelper"
    public static let applicationSupportDirectoryName = "StorageCleanerMac"
#endif
    public static func executableName(beta: Bool) -> String { beta ? betaExecutableName : releaseExecutableName }
    public static func installedApplicationPath(beta: Bool) -> String {
        beta ? betaInstalledApplicationPath : releaseInstalledApplicationPath
    }
    public static func installedExecutablePath(beta: Bool) -> String {
        installedApplicationPath(beta: beta) + "/Contents/MacOS/" + executableName(beta: beta)
    }
    public static var installedApplicationPath: String { installedApplicationPath(beta: isBeta) }
    public static var installedExecutablePath: String { installedExecutablePath(beta: isBeta) }
}

import Foundation
import Security

/// CleanMyMac's uninstaller sidebar (`uninstaller_filter_*`).
enum ApplicationCategory: Hashable, Sendable, Identifiable {
    case all
    case unused
    case suspicious
    case selected
    case store(ApplicationStore)
    case vendor(ApplicationVendor)
    case audioPlugins
    case thirtyTwoBit
    case leftovers
    case installers
    case otherLocations

    var id: String {
        switch self {
        case .all: "all"
        case .unused: "unused"
        case .suspicious: "suspicious"
        case .selected: "selected"
        case .store(let store): "store." + store.rawValue
        case .vendor(let vendor): "vendor." + vendor.rawValue
        case .audioPlugins: "plugins.audio"
        case .thirtyTwoBit: "32bit"
        case .leftovers: "leftovers"
        case .installers: "installers"
        case .otherLocations: "otherLocations"
        }
    }

    var title: String {
        switch self {
        case .all: L10n.text("所有应用程序", "All Applications")
        case .unused: L10n.text("未使用", "Unused")
        case .suspicious: L10n.text("可疑项", "Suspicious")
        case .selected: L10n.text("勾选的", "Selected")
        case .store(let store): store.title
        case .vendor(let vendor): vendor.title
        case .audioPlugins: L10n.text("音频插件", "Audio Plugins")
        case .thirtyTwoBit: L10n.text("32 位应用程序", "32-bit Applications")
        case .leftovers: L10n.text("程序残留", "Leftovers")
        case .installers: L10n.text("安装器", "Installers")
        case .otherLocations: L10n.text("其他位置的应用", "Applications in Other Locations")
        }
    }

    var help: String {
        switch self {
        case .all: L10n.text("这台 Mac 上的应用程序", "Applications on this Mac")
        case .unused: L10n.text("超过六个月未打开的应用程序", "Applications you haven’t opened for over six months")
        case .suspicious: L10n.text("签名无效，或未签名且从网络下载的应用程序", "Applications with a broken signature, or unsigned and downloaded from the internet")
        case .selected: L10n.text("您已勾选要卸载的应用程序", "The applications you already selected for uninstallation")
        case .store(let store): store.help
        case .vendor(let vendor): vendor.help
        case .audioPlugins: L10n.text("与数字音频工作站 (DAW) 相关的第三方音频插件", "Third party audio plugins for digital audio workstations")
        case .thirtyTwoBit: L10n.text("旧的 32 位版本应用程序无法在您的操作系统上运行。", "Old 32-bit applications cannot work on your OS.")
        case .leftovers: L10n.text("已卸载应用程序留下的偏好设置和配置文件", "Preference and configuration files of previously uninstalled applications")
        case .installers: L10n.text("不再需要的 DMG 或其他应用程序安装文件", "DMGs or other installation files you no longer need")
        case .otherLocations: L10n.text("标准应用目录之外的副本。默认不勾选，只移除所选应用包，保留所有关联文件。",
                                      "Copies outside the standard application folders. Nothing is selected by default; only selected app bundles move, keeping all related files.")
        }
    }

    var emptyDescription: String {
        switch self {
        case .unused: L10n.text("超过六个月未使用的应用程序将显示在此处。", "There are no applications you haven’t used in over six months.")
        case .suspicious: L10n.text("如果存在潜在有害的或危险的应用程序，将显示在此处。", "Potentially harmful or dangerous applications will appear here if you have any.")
        case .selected: L10n.text("已勾选的应用程序将显示在此处。", "Selected applications will appear here.")
        case .audioPlugins: L10n.text("第三方音频插件将显示在此处", "Third party audio plugins will appear here")
        case .leftovers: L10n.text("没有找到已卸载应用的残留文件。", "No leftovers of removed apps were found.")
        case .installers: L10n.text("没有找到不再需要的安装文件。", "No installation files you no longer need were found.")
        case .otherLocations: L10n.text("Spotlight 没有找到其他位置的应用。", "Spotlight found no applications in other locations.")
        default: L10n.text("您的 Mac 电脑中未安装有应用程序。", "There are no applications on your Mac.")
        }
    }
}

enum ApplicationStore: String, CaseIterable, Sendable {
    case appStore, setapp, steam, battleNet, other

    var title: String {
        switch self {
        case .appStore: "App Store"
        case .setapp: "Setapp"
        case .steam: "Steam"
        case .battleNet: "Battle.net"
        case .other: L10n.text("其他", "Other")
        }
    }

    var help: String {
        switch self {
        case .appStore: L10n.text("通过 App Store 安装的应用程序", "Applications installed from the App Store")
        case .setapp: L10n.text("通过 Setapp 安装的应用程序", "Applications installed using Setapp")
        case .steam: L10n.text("通过 Steam 安装的应用程序", "Applications installed using Steam")
        case .battleNet: L10n.text("通过 Battle.net 安装的应用程序", "Applications installed using Battle.net")
        case .other: L10n.text("来自第三方供应商的应用程序", "Applications from third-party vendors")
        }
    }
}

enum ApplicationVendor: String, CaseIterable, Sendable {
    case apple, google, microsoft, adobe, jetBrains, macPaw, other

    var title: String {
        switch self {
        case .apple: "Apple"
        case .google: "Google"
        case .microsoft: "Microsoft"
        case .adobe: "Adobe"
        case .jetBrains: "JetBrains"
        case .macPaw: "MacPaw"
        case .other: L10n.text("其他", "Other")
        }
    }

    var help: String {
        switch self {
        case .other: L10n.text("由其他第三方供应商开发的应用程序", "Applications developed by other third-party vendors")
        default: L10n.text("由 \(title) 开发的应用程序", "Applications developed by \(title)")
        }
    }

    /// Team IDs of the vendors CleanMyMac lists, with the identifier prefix as
    /// the fallback for apps whose signature cannot be read.
    static func of(bundleIdentifier: String, teamIdentifier: String?) -> ApplicationVendor {
        let id = bundleIdentifier.lowercased()
        switch teamIdentifier {
        case "EQHXZ8M8AV": return .google
        case "UBF8T346G9": return .microsoft
        case "JQ525L2MZD": return .adobe
        case "2ZEFAR8TH3": return .jetBrains
        case "S8EX82NJP6": return .macPaw
        default: break
        }
        if id.hasPrefix("com.apple.") { return .apple }
        if id.hasPrefix("com.google.") { return .google }
        if id.hasPrefix("com.microsoft.") { return .microsoft }
        if id.hasPrefix("com.adobe.") { return .adobe }
        if id.hasPrefix("com.jetbrains.") { return .jetBrains }
        if id.hasPrefix("com.macpaw.") { return .macPaw }
        return .other
    }
}

/// Facts the sidebar groups an application by.
struct ApplicationClassification: Hashable, Sendable {
    var store: ApplicationStore
    var vendor: ApplicationVendor
    var isUnused: Bool
    var isThirtyTwoBitOnly: Bool
    var suspiciousReason: String?

    /// CleanMyMac: "applications that were used more than 6 months ago". With
    /// no recorded last use, the date the app was installed (its bundle's
    /// creation or modification date) stands in.
    static func isUnused(lastUsed: Date?, installed: Date?, now: Date = Date(), calendar: Calendar = .current) -> Bool {
        guard let threshold = calendar.date(byAdding: .month, value: -6, to: now) else { return false }
        if let lastUsed { return lastUsed < threshold }
        if let installed { return installed < threshold }
        return false
    }

    static func store(for path: String, bundleIdentifier: String, fileManager: FileManager = .default) -> ApplicationStore {
        let lowerPath = path.lowercased()
        if fileManager.fileExists(atPath: (path as NSString).appendingPathComponent("Contents/_MASReceipt/receipt")) {
            return .appStore
        }
        if lowerPath.contains("/setapp/") || bundleIdentifier.lowercased().hasSuffix("-setapp") { return .setapp }
        if lowerPath.contains("/steamapps/") || lowerPath.contains("/steam.app/") { return .steam }
        if lowerPath.contains("battle.net") || bundleIdentifier.lowercased().hasPrefix("com.blizzard.") { return .battleNet }
        return .other
    }

    /// `executableArchitectures` holds only 32-bit slices (i386, ppc).
    static func isThirtyTwoBitOnly(_ bundleURL: URL) -> Bool {
        guard let architectures = Bundle(url: bundleURL)?.executableArchitectures?.map(\.intValue),
              !architectures.isEmpty else { return false }
        let thirtyTwoBit: Set<Int> = [NSBundleExecutableArchitectureI386, NSBundleExecutableArchitecturePPC]
        return architectures.allSatisfy { thirtyTwoBit.contains($0) }
    }

    /// CleanMyMac marks apps signed by developers from one country as
    /// suspicious (`signedWithAgressorCountryCertificate`). That judgement is
    /// not copied. Here an app is suspicious when its signature is broken, or
    /// when it is unsigned (or ad-hoc signed) and still carries the download
    /// quarantine flag.
    static func suspiciousReason(for bundleURL: URL) -> String? {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(bundleURL as CFURL, [], &staticCode) == errSecSuccess, let staticCode else {
            return nil
        }
        // The executable's signature only: hashing every resource of a large
        // app (Xcode) would take minutes and is not needed to see a break.
        let status = SecStaticCodeCheckValidity(staticCode, SecCSFlags(rawValue: kSecCSDoNotValidateResources), nil)
        if status == errSecCSUnsigned {
            return hasQuarantine(bundleURL)
                ? L10n.text("未签名，且来自网络下载", "Unsigned and downloaded from the internet") : nil
        }
        if status != errSecSuccess {
            return L10n.text("签名无效或已被修改", "The signature is broken or the app was modified")
        }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let values = information as? [String: Any] else { return nil }
        let adHoc = (values[kSecCodeInfoTeamIdentifier as String] as? String)?.isEmpty ?? true
        if adHoc, hasQuarantine(bundleURL) {
            return L10n.text("临时签名，且来自网络下载", "Ad-hoc signed and downloaded from the internet")
        }
        return nil
    }

    private static func hasQuarantine(_ url: URL) -> Bool {
        getxattr(url.path, "com.apple.quarantine", nil, 0, 0, XATTR_NOFOLLOW) > 0
    }
}

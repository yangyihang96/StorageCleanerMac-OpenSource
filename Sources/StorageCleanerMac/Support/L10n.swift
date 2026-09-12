import AppKit
import FanControlShared
import Foundation
import os

enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
    case system
    case zhHans
    case english

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: "跟随系统 / System"
        case .zhHans: "简体中文"
        case .english: "English"
        }
    }

    var detail: String {
        switch self {
        case .system:
            "Use the first language from macOS Language & Region."
        case .zhHans:
            "使用中文界面、菜单和导出报告。"
        case .english:
            "Use English interface text, menus, and exported reports."
        }
    }
}

enum AppAppearance: String, CaseIterable, Identifiable, Sendable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: L10n.text("跟随系统", "System")
        case .light: L10n.text("浅色", "Light")
        case .dark: L10n.text("深色", "Dark")
        }
    }

    var detail: String {
        switch self {
        case .system:
            L10n.text("跟随 macOS 当前外观。", "Follow the current macOS appearance.")
        case .light:
            L10n.text("固定使用浅色玻璃界面。", "Always use the light glass interface.")
        case .dark:
            L10n.text("固定使用深色玻璃界面。", "Always use the dark glass interface.")
        }
    }

    @MainActor
    func applyAppKitPreference() {
        switch self {
        case .system:
            NSApplication.shared.appearance = nil
        case .light:
            NSApplication.shared.appearance = NSAppearance(named: .aqua)
        case .dark:
            NSApplication.shared.appearance = NSAppearance(named: .darkAqua)
        }
    }
}

enum L10n {
    static let languageDefaultsKey = "app.language"
    static let appearanceDefaultsKey = "app.appearance"

    static var productName: String {
        text("存储清理助手", "Storage Cleaner")
    }

    static var showsBetaBadge: Bool {
        StorageCleanerBuildIdentity.isBeta
    }

    static var appName: String {
        showsBetaBadge
            ? text("测试版", "Beta")
            : productName
    }

    /// Every rendered label resolves through `text(_:_:)`, so the language
    /// decision is cached instead of re-reading UserDefaults and
    /// `Locale.preferredLanguages` for each string. Any defaults write or
    /// system locale change invalidates the cache before the next read.
    private static let cachedUsesChinese = OSAllocatedUnfairLock<Bool?>(initialState: nil)
    private static let cacheInvalidator = LanguageCacheInvalidator()

    private final class LanguageCacheInvalidator: @unchecked Sendable {
        private var tokens: [NSObjectProtocol] = []

        init() {
            let center = NotificationCenter.default
            let invalidate: @Sendable (Notification) -> Void = { _ in
                L10n.cachedUsesChinese.withLock { $0 = nil }
            }
            tokens.append(center.addObserver(
                forName: UserDefaults.didChangeNotification,
                object: nil,
                queue: nil,
                using: invalidate
            ))
            tokens.append(center.addObserver(
                forName: NSLocale.currentLocaleDidChangeNotification,
                object: nil,
                queue: nil,
                using: invalidate
            ))
        }
    }

    static var usesChinese: Bool {
        _ = cacheInvalidator
        if let cached = cachedUsesChinese.withLock({ $0 }) {
            return cached
        }
        let resolved = usesChinese(for: appLanguage)
        cachedUsesChinese.withLock { $0 = resolved }
        return resolved
    }

    static var appLanguage: AppLanguage {
        let rawValue = UserDefaults.standard.string(forKey: languageDefaultsKey) ?? AppLanguage.system.rawValue
        return AppLanguage(rawValue: rawValue) ?? .system
    }

    static var locale: Locale {
        usesChinese ? Locale(identifier: "zh_Hans") : Locale(identifier: "en_US_POSIX")
    }

    static func appKitAppleLanguages(for language: AppLanguage) -> [String]? {
        switch language {
        case .system:
            nil
        case .zhHans:
            ["zh-Hans"]
        case .english:
            ["en"]
        }
    }

    static func applyAppKitLanguagePreference() {
        let defaults = UserDefaults.standard
        if let languages = appKitAppleLanguages(for: appLanguage) {
            defaults.set(languages, forKey: "AppleLanguages")
        } else {
            defaults.removeObject(forKey: "AppleLanguages")
        }
        defaults.synchronize()
    }

    static func usesChinese(
        for language: AppLanguage,
        preferredLanguages: [String] = Locale.preferredLanguages
    ) -> Bool {
        switch language {
        case .zhHans:
            true
        case .english:
            false
        case .system:
            preferredLanguages.first?.lowercased().hasPrefix("zh") ?? false
        }
    }

    static func text(_ zh: String, _ en: String) -> String {
        usesChinese ? zh : en
    }

    static func items(_ count: Int) -> String {
        if usesChinese {
            return "\(count) 项"
        }
        return count == 1 ? "1 item" : "\(count) items"
    }

    static func itemBytes(_ count: Int, _ bytes: String) -> String {
        usesChinese ? "\(count) 项 · \(bytes)" : "\(items(count)) · \(bytes)"
    }

    static func greenCountDescription(_ count: Int) -> String {
        usesChinese ? "\(count) 个可安全清理项目，只会移到废纸篓。" : "\(items(count)) marked safe to clean. They will only be moved to Trash."
    }

    static func bulkTrashMessage(count: Int, bytes: String) -> String {
        if usesChinese {
            return "将 \(count) 个可安全清理项目移到废纸篓，体积约 \(bytes)。清空废纸篓后才会真正释放空间。"
        }
        return "Move \(items(count)) marked safe to clean to Trash, about \(bytes). Free space changes after Trash is emptied."
    }

    static func moveItemToTrashMessage(_ title: String) -> String {
        if usesChinese {
            return "将“\(title)”移到废纸篓。这个操作可以从废纸篓恢复。"
        }
        return "Move “\(title)” to Trash. You can restore it from Trash."
    }

    static func emptyTrashMessage(count: Int, bytes: String) -> String {
        if usesChinese {
            return "将永久删除废纸篓里的 \(count) 项，约 \(bytes)。这个操作通常无法恢复，建议先确认废纸篓内容。"
        }
        return "Permanently delete \(items(count)) from Trash, about \(bytes). This is usually not reversible, so review Trash first."
    }

    static func scanSeconds(_ seconds: TimeInterval) -> String {
        usesChinese ? "扫描 \(String(format: "%.1f", seconds)) 秒" : "Scanned in \(String(format: "%.1f", seconds)) sec"
    }

    static func countTierDetail(count: Int, detail: String) -> String {
        usesChinese ? "\(count) 项 · \(detail)" : "\(items(count)) · \(detail)"
    }

    static func lastScan(_ time: String) -> String {
        usesChinese ? "上次扫描 \(time)" : "Last scan \(time)"
    }

    static func usedSpace(_ value: String) -> String {
        usesChinese ? "\(value) 已用" : "\(value) used"
    }

    static func noItems(filterTitle: String) -> String {
        usesChinese ? "没有\(filterTitle)项目" : "No \(filterTitle.lowercased()) items"
    }
}

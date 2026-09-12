import SwiftUI

/// Presentation-only metadata for a main-window route.  It deliberately has
/// no knowledge of scanners, permissions, or cleanup operations.
enum ModulePresentationStyle: String, Hashable {
    case hero
    case management
    case dashboard
}

/// A category-level visual identity. Business outcome colors remain separate
/// in `AppDesignTokens.Palette` so a warning or a failure never masquerades
/// as module branding.
enum FeatureGroup: String, CaseIterable, Hashable, Identifiable {
    case smartScan = "smart-scan"
    case cleanup
    case protection
    case performance
    case applications
    case files
    case settings

    var id: String { rawValue }

}

enum SidebarGroup: String, CaseIterable, Identifiable {
    case cleanup
    case protection
    case performance
    case applications
    case files

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .cleanup:
            "sparkles"
        case .protection:
            "checkmark.shield.fill"
        case .performance:
            "gauge.with.dots.needle.67percent"
        case .applications:
            "square.stack.3d.up.fill"
        case .files:
            "folder.fill"
        }
    }

    var title: String {
        switch self {
        case .cleanup:
            L10n.text("清理", "CLEANUP")
        case .protection:
            L10n.text("保护", "PROTECTION")
        case .performance:
            L10n.text("性能", "PERFORMANCE")
        case .applications:
            L10n.text("应用", "APPLICATIONS")
        case .files:
            L10n.text("文件", "FILES")
        }
    }

    var expansionDefaultsKey: String {
        "mainWindow.sidebar.section.v2.\(rawValue).expanded"
    }
}

struct ModuleTheme {
    let featureGroup: FeatureGroup
    let accent: Color
    let gradientStart: Color
    let gradientEnd: Color
    let darkGradientStart: Color
    let darkGradientEnd: Color
    let radialHighlight: Color
    let darkRadialHighlight: Color

    /// The main window has an immersive visual surface when this is true.
    /// Settings and sheets use the neutral default instead.
    let isImmersive: Bool

    var identifier: String { featureGroup.rawValue }
    var sidebarIconColor: Color { accent }
    var actionFill: Color { accent }
    var scanProgressColor: Color { accent }

    static let neutral = ModuleTheme(
        featureGroup: .settings,
        accent: .accentColor,
        gradientStart: Color(nsColor: .windowBackgroundColor),
        gradientEnd: Color(nsColor: .windowBackgroundColor),
        darkGradientStart: Color(nsColor: .windowBackgroundColor),
        darkGradientEnd: Color(nsColor: .windowBackgroundColor),
        radialHighlight: .clear,
        darkRadialHighlight: .clear,
        isImmersive: false
    )

    func startColor(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark ? darkGradientStart : gradientStart
    }

    func endColor(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark ? darkGradientEnd : gradientEnd
    }

    var primaryText: Color { isImmersive ? .white : .primary }
    var secondaryText: Color { isImmersive ? Color.white.opacity(0.76) : .secondary }
    var tertiaryText: Color {
        isImmersive ? Color.white.opacity(0.58) : Color(nsColor: .tertiaryLabelColor)
    }

    func panelFill(for colorScheme: ColorScheme, reduceTransparency: Bool) -> Color {
        guard isImmersive else {
            return Color(nsColor: .windowBackgroundColor)
        }
        if reduceTransparency {
            return startColor(for: colorScheme)
        }
        return Color.white.opacity(0.035)
    }

    func panelBorder(for contrast: ColorSchemeContrast) -> Color {
        isImmersive
            ? Color.white.opacity(contrast == .increased ? 0.65 : 0.20)
            : Color(nsColor: .separatorColor).opacity(contrast == .increased ? 1 : 0.65)
    }
}

private struct ModuleThemeEnvironmentKey: EnvironmentKey {
    static let defaultValue = ModuleTheme.neutral
}

extension EnvironmentValues {
    var moduleTheme: ModuleTheme {
        get { self[ModuleThemeEnvironmentKey.self] }
        set { self[ModuleThemeEnvironmentKey.self] = newValue }
    }
}

enum ModuleThemeCatalog {
    static func theme(for filter: ReviewFilter) -> ModuleTheme {
        if filter == .memory {
            let base = theme(for: FeatureGroup.performance)
            let accent = Color(red: 0.55, green: 0.36, blue: 0.96)
            return ModuleTheme(featureGroup: .performance, accent: accent,
                               gradientStart: base.gradientStart, gradientEnd: base.gradientEnd,
                               darkGradientStart: base.darkGradientStart, darkGradientEnd: base.darkGradientEnd,
                               radialHighlight: accent.opacity(0.10), darkRadialHighlight: accent.opacity(0.10),
                               isImmersive: true)
        }
        if filter == .privacy {
            return ModuleTheme(
                featureGroup: .protection,
                accent: Color(red: 0.20, green: 0.78, blue: 0.55),
                gradientStart: Color(red: 0.045, green: 0.085, blue: 0.14),
                gradientEnd: Color(red: 0.04, green: 0.075, blue: 0.13),
                darkGradientStart: Color(red: 0.045, green: 0.085, blue: 0.14),
                darkGradientEnd: Color(red: 0.04, green: 0.075, blue: 0.13),
                radialHighlight: Color.blue.opacity(0.06),
                darkRadialHighlight: Color.blue.opacity(0.06),
                isImmersive: true
            )
        }
        if filter == .devCaches {
            return ModuleTheme(
                featureGroup: .cleanup,
                accent: Color(red: 0.95, green: 0.60, blue: 0.12),
                gradientStart: Color(red: 0.10, green: 0.09, blue: 0.065),
                gradientEnd: Color(red: 0.045, green: 0.048, blue: 0.055),
                darkGradientStart: Color(red: 0.10, green: 0.09, blue: 0.065),
                darkGradientEnd: Color(red: 0.045, green: 0.048, blue: 0.055),
                radialHighlight: Color.orange.opacity(0.10),
                darkRadialHighlight: Color.orange.opacity(0.10),
                isImmersive: true
            )
        }
        return theme(for: filter.featureGroup)
    }

    static func theme(for featureGroup: FeatureGroup) -> ModuleTheme {
        guard featureGroup != .settings else { return .neutral }
        let accent: Color
        switch featureGroup {
        case .smartScan: accent = Color(red: 0.23, green: 0.47, blue: 0.98)
        case .cleanup: accent = Color(red: 1.0, green: 0.42, blue: 0.12)
        case .protection: accent = Color(red: 0.20, green: 0.78, blue: 0.55)
        case .performance: accent = Color(red: 0.87, green: 0.31, blue: 0.70)
        case .applications: accent = Color(red: 0.58, green: 0.39, blue: 0.95)
        case .files: accent = Color(red: 0.55, green: 0.36, blue: 0.96)
        case .settings: accent = .accentColor
        }
        let start = featureGroup == .protection
            ? Color(red: 0.055, green: 0.105, blue: 0.125)
            : Color(red: 0.065, green: 0.10, blue: 0.23)
        let end = featureGroup == .protection
            ? Color(red: 0.045, green: 0.075, blue: 0.09)
            : Color(red: 0.04, green: 0.065, blue: 0.16)
        return ModuleTheme(
            featureGroup: featureGroup,
            accent: accent,
            gradientStart: start,
            gradientEnd: end,
            darkGradientStart: start,
            darkGradientEnd: end,
            radialHighlight: accent.opacity(0.10),
            darkRadialHighlight: accent.opacity(0.10),
            isImmersive: true
        )
    }
}

extension ReviewFilter {
    var featureGroup: FeatureGroup {
        switch self {
        case .overview:
            .smartScan
        case .green, .devCaches:
            .cleanup
        case .privacy:
            .protection
        case .healthHub:
            .protection
        case .utilityHub:
            .settings
        case .performance, .startup, .memory, .energy:
            .performance
        case .uninstall, .updater:
            .applications
        case .largeFiles, .migration, .duplicates:
            .files
        }
    }

    var moduleTheme: ModuleTheme {
        ModuleThemeCatalog.theme(for: self)
    }

    var pagePresentationStyle: ModulePresentationStyle {
        switch self {
        case .overview, .healthHub, .green, .privacy:
            .hero
        case .performance:
            .dashboard
        case .devCaches, .largeFiles, .migration, .duplicates, .utilityHub, .startup, .memory, .energy, .uninstall, .updater:
            .management
        }
    }

    var pageSubtitle: String {
        switch self {
        case .overview:
            L10n.text(
                "检查可清理垃圾与需要人工判断的文件",
                "Check cleanup candidates and files that need review"
            )
        case .healthHub:
            L10n.text("检查磁盘、电池与关键系统状态", "Check disk, battery, and essential system status")
        case .performance:
            L10n.text("评估 CPU、图形、媒体与持续性能", "Measure CPU, graphics, media, and sustained performance")
        case .green:
            L10n.text("扫描缓存、日志、临时文件与其他可安全清理内容", "Scan caches, logs, temporary files, and other safe-to-clean items")
        case .privacy:
            L10n.text("检查本机浏览记录中的隐私足迹", "Review privacy traces in local browser history")
        case .devCaches:
            L10n.text(
                "扫描 AI 开发工具、Agent 缓存、会话与可再生成产物",
                "Scan AI developer tools, agent caches, sessions, and regenerable artifacts"
            )
        case .largeFiles:
            L10n.text("浏览并定位占用空间的文件", "Browse and locate files using storage")
        case .duplicates:
            L10n.text("查找内容完全相同的文件，并在处理前逐组确认", "Find identical files and review each group before handling copies")
        case .migration:
            L10n.text("将文件或应用安全迁移到外接硬盘", "Safely move files or applications to an external drive")
        case .startup:
            L10n.text("管理登录时打开的应用、后台代理和系统守护进程", "Manage login apps, background agents, and system daemons")
        case .memory:
            L10n.text("查看内存占用并安全释放可回收资源", "Review memory usage and safely reclaim resources")
        case .energy:
            L10n.text("识别影响续航与发热的应用活动", "Identify app activity affecting battery life and heat")
        case .uninstall:
            L10n.text("卸载应用前先审阅相关文件", "Review related files before uninstalling apps")
        case .updater:
            L10n.text("从可信来源检查可用更新", "Check trusted sources for available updates")
        case .utilityHub:
            L10n.text("系统工具", "System tools")
        }
    }

    var sidebarGroup: SidebarGroup? {
        switch self {
        case .green, .devCaches:
            .cleanup
        case .healthHub, .privacy:
            .protection
        case .performance, .startup, .memory, .energy:
            .performance
        case .uninstall, .updater:
            .applications
        case .largeFiles, .migration, .duplicates:
            .files
        case .overview, .utilityHub:
            nil
        }
    }

    static func sidebarItems(in group: SidebarGroup) -> [ReviewFilter] {
        allCases.filter { $0.sidebarGroup == group }
    }
}

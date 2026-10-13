import Foundation

/// Display-only snapshot helpers. No filesystem, signature or permission reads.
enum UninstallPresentation {
    static func selectablePaths(_ app: InstalledAppItem) -> Set<String> {
        Set(app.relatedItems.filter {
            $0.scanIdentity != nil && $0.ownershipEvidence?.bundleID == app.bundleIdentifier
                && $0.ownershipEvidence?.applicationIdentity == app.scanIdentity
        }.map(\.path))
    }
    /// Verified rows that "Select All Verified" adds: high-value data
    /// (D87, for example browser profiles or Docker data) is ticked only one
    /// by one.
    static func bulkSelectablePaths(_ app: InstalledAppItem) -> Set<String> {
        selectablePaths(app).filter { UninstallVendorRules.highValueData(path: $0) == nil }
    }
    static func retainedItems(_ app: InstalledAppItem, report: CleanReport) -> [InstalledAppRelatedItem] {
        let processed = Set(report.items.map(\.sourcePath))
        return app.relatedItems.filter { !processed.contains($0.path) }
    }
    static func category(_ path: String) -> String {
        if path.contains("/Caches/") { return L10n.text("缓存", "Cache") }
        if path.contains("/Logs/") { return L10n.text("日志", "Logs") }
        if path.contains("/Preferences/") { return L10n.text("偏好设置", "Preferences") }
        if path.contains("/Group Containers/") { return L10n.text("共享应用数据", "Shared App Data") }
        if path.contains("/Containers/") { return L10n.text("应用数据", "App Data") }
        return L10n.text("支持文件", "Support Files")
    }
    static func displayPath(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }

    /// Short status for Operation History. Nil leaves the generic failure title.
    static func recordLabel(_ reason: UninstallFailureReason) -> String? {
        switch reason {
        case .systemRefused: L10n.text("未移动：系统拒绝（可检查“应用管理”）", "Not moved: refused by macOS (check App Management)")
        case .unsupportedLocation: L10n.text("未移动：请在访达中手动移动", "Not moved: move it in Finder")
        case .protectedApp: L10n.text("未移动：此应用不支持授权移动", "Not moved: not supported for authorized moves")
        case .locked: L10n.text("未移动：应用已锁定", "Not moved: the app is locked")
        case .authorizationIncomplete: L10n.text("未移动：授权未完成", "Not moved: authorization not completed")
        case .helperUnavailable: L10n.text("未移动：授权辅助程序不可用", "Not moved: authorization helper unavailable")
        case .changedSinceScan: L10n.text("未移动：扫描后已变化或正在运行", "Not moved: changed since the scan or running")
        case .applicationNotConfirmed: L10n.text("未处理：未确认应用本体已移走", "Not processed: app removal not confirmed")
        case .missing: L10n.text("未移动：项目已不存在", "Not moved: the item no longer exists")
        case .interrupted: L10n.text("未移动：任务被中断", "Not moved: the task was interrupted")
        case .refused: L10n.text("未移动：系统拒绝移入废纸篓", "Not moved: macOS refused the move to Trash")
        case .other: nil
        }
    }
}

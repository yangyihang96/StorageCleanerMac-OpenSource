import Foundation

struct UtilityListExportService {
    static func appUpdatesMarkdown(
        for apps: [AppUpdateItem],
        generatedAt: Date = Date()
    ) -> String {
        var lines = [String]()
        lines.append("# \(L10n.text("应用更新清单", "App Update List"))")
        lines.append("")
        lines.append("- \(L10n.text("生成时间", "Generated")): \(displayDate(generatedAt))")
        lines.append("- \(L10n.text("项目数量", "Items")): \(apps.count)")
        lines.append("- \(L10n.text("安全边界", "Safety boundary")): \(L10n.text("这份清单只记录当前可见的更新候选，不代表已经完成更新。", "This list records the currently visible update candidates and does not mean updates have already completed."))")
        lines.append("- \(L10n.text("清单动作", "List action")): \(L10n.text("复制或导出只会生成复核清单，不会打开更新器、运行命令或确认版本变化。", "Copying or exporting only creates a review list; it does not open updaters, run commands, or confirm version changes."))")
        lines.append("")

        if apps.isEmpty {
            lines.append(L10n.text("没有可复制的更新项目。", "No update items to copy."))
            return lines.joined(separator: "\n") + "\n"
        }

        lines.append("| \(L10n.text("应用", "App")) | \(L10n.text("来源", "Source")) | \(L10n.text("当前版本", "Current")) | \(L10n.text("最新版本", "Latest")) | \(L10n.text("处理方式", "Action")) | Bundle ID |")
        lines.append("| --- | --- | --- | --- | --- | --- |")
        for app in apps {
            lines.append("| \(tableText(app.name)) | \(tableText(app.method.title)) | \(tableText(app.currentVersionDisplay)) | \(tableText(app.latestVersionDisplay)) | \(tableText(updateAction(for: app))) | \(tableText(app.bundleIdentifier)) |")
        }

        lines.append("")
        lines.append("## \(L10n.text("路径", "Paths"))")
        lines.append("")
        for app in apps {
            lines.append("- **\(app.name)**: `\(app.path)`")
        }

        return lines.joined(separator: "\n") + "\n"
    }

    static func installedAppsMarkdown(
        for apps: [InstalledAppItem],
        generatedAt: Date = Date()
    ) -> String {
        let totalBytes = apps.reduce(Int64.zero) { $0 + $1.totalFootprintBytes }
        let relatedBytes = apps.reduce(Int64.zero) { $0 + $1.relatedBytes }

        var lines = [String]()
        lines.append("# \(L10n.text("应用卸载清单", "App Uninstall List"))")
        lines.append("")
        lines.append("- \(L10n.text("生成时间", "Generated")): \(displayDate(generatedAt))")
        lines.append("- \(L10n.text("项目数量", "Items")): \(apps.count)")
        lines.append("- \(L10n.text("合计占用", "Total footprint")): \(ByteFormat.string(totalBytes))")
        lines.append("- \(L10n.text("关联文件", "Associated files")): \(ByteFormat.string(relatedBytes))")
        lines.append("- \(L10n.text("安全边界", "Safety boundary")): \(L10n.text("卸载确认时可选择把应用文件和关联文件一起移到废纸篓，清空废纸篓前仍可恢复。", "Uninstall confirmation can move the app and associated files to Trash; they remain recoverable until Trash is emptied."))")
        lines.append("- \(L10n.text("清单动作", "List action")): \(L10n.text("复制或导出只会生成复核清单，不会卸载应用、移动关联文件或清空废纸篓。", "Copying or exporting only creates a review list; it does not uninstall apps, move associated files, or empty Trash."))")
        lines.append("")

        if apps.isEmpty {
            lines.append(L10n.text("没有可复制的应用项目。", "No app items to copy."))
            return lines.joined(separator: "\n") + "\n"
        }

        lines.append("| \(L10n.text("应用", "App")) | \(L10n.text("开发者", "Developer")) | \(L10n.text("版本", "Version")) | \(L10n.text("总占用", "Footprint")) | \(L10n.text("建议", "Recommendation")) | Bundle ID |")
        lines.append("| --- | --- | --- | ---: | --- | --- |")
        for app in apps {
            lines.append("| \(tableText(app.name)) | \(tableText(app.developerName.nonEmpty ?? "-")) | \(tableText(app.versionDisplay)) | \(ByteFormat.string(app.totalFootprintBytes)) | \(tableText(app.uninstallRecommendation.title)) | \(tableText(app.bundleIdentifier)) |")
        }

        let appsWithLeftovers = apps.filter { !$0.relatedItems.isEmpty }
        if !appsWithLeftovers.isEmpty {
            lines.append("")
            lines.append("## \(L10n.text("关联文件", "Associated Files"))")
            lines.append("")
            for app in appsWithLeftovers {
                lines.append("### \(app.name)")
                for item in app.relatedItems.prefix(5) {
                    lines.append("- `\(item.path)` · \(ByteFormat.string(item.sizeBytes))")
                }
                if app.relatedItems.count > 5 {
                    lines.append("- \(L10n.text("另有 \(app.relatedItems.count - 5) 个路径未展开。", "\(app.relatedItems.count - 5) more paths are not expanded."))")
                }
                lines.append("")
            }
        }

        return lines.joined(separator: "\n") + "\n"
    }

    private static func updateAction(for app: AppUpdateItem) -> String {
        switch app.method {
        case .appStore:
            L10n.text("App Store 更新页或批量更新", "App Store Updates or batch update")
        case .homebrew:
            app.homebrewCommand ?? L10n.text("Homebrew 手动确认", "Homebrew manual confirmation")
        case .sparkle:
            L10n.text("打开应用内更新", "Open in-app updater")
        case .manual:
            L10n.text("打开应用或官网检查", "Open app or website")
        }
    }

    private static func displayDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = L10n.locale
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    private static func tableText(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "|", with: "\\|")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmed
    }
}

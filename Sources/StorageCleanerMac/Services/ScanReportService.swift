import Foundation

enum ScanReportServiceError: LocalizedError {
    case missingDirectory

    var errorDescription: String? {
        switch self {
        case .missingDirectory:
            L10n.text("找不到可写入的报告目录", "Could not find a writable report directory")
        }
    }
}

struct ScanReportService {
    static func export(
        result: ScanResult,
        directory: URL? = nil,
        generatedAt: Date = Date(),
        fileManager: FileManager = .default
    ) throws -> URL {
        let reportDirectory = directory ?? defaultReportDirectory()
        guard let reportDirectory else { throw ScanReportServiceError.missingDirectory }

        try fileManager.createDirectory(at: reportDirectory, withIntermediateDirectories: true)

        let fileName = L10n.text("存储清理助手-扫描报告-", "StorageCleaner-Report-") + fileStamp(generatedAt) + ".md"
        let url = reportDirectory.appendingPathComponent(fileName)
        try markdown(for: result, generatedAt: generatedAt).write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    static func markdown(for result: ScanResult, generatedAt: Date = Date()) -> String {
        let topItems = result.topItems
        let developerArtifactItems = result.items(for: .devCaches)
        let movedCount = result.movedToTrashItems.count
        let scoreBreakdown = ScanHistoryService.scoreBreakdown(for: result, referenceDate: generatedAt)
        let coverage = ScanCoverageService.summary(deniedPaths: result.deniedPaths)
        let deniedPaths = coverage.deniedPaths
        let freshness = ScanFreshnessService.summary(generatedAt: result.generatedAt, referenceDate: generatedAt)

        var lines = [String]()
        lines.append("# \(L10n.text("存储清理助手扫描报告", "Storage Cleaner Scan Report"))")
        lines.append("")
        lines.append("- \(L10n.text("生成时间", "Generated")): \(displayDate(generatedAt))")
        lines.append("- \(L10n.text("扫描完成", "Scan completed")): \(displayDate(result.generatedAt))")
        lines.append("- \(L10n.text("扫描耗时", "Scan duration")): \(String(format: "%.1f", result.scanSeconds))s")
        lines.append("- \(L10n.text("系统", "System")): \(result.system.osName) \(result.system.build) (\(result.system.arch))")
        lines.append("")

        lines.append("## \(L10n.text("磁盘概览", "Disk Overview"))")
        lines.append("")
        lines.append("| \(L10n.text("项目", "Metric")) | \(L10n.text("数值", "Value")) |")
        lines.append("| --- | --- |")
        lines.append("| \(L10n.text("磁盘", "Disk")) | \(tableText(result.system.diskName)) |")
        lines.append("| \(L10n.text("文件系统", "Filesystem")) | \(tableText(result.system.filesystem)) |")
        lines.append("| \(L10n.text("总容量", "Capacity")) | \(ByteFormat.string(result.system.diskTotalBytes)) |")
        lines.append("| \(L10n.text("已使用", "Used")) | \(ByteFormat.string(result.system.diskUsedBytes)) (\(ByteFormat.percent(result.system.diskUsedBytes, of: result.system.diskTotalBytes))) |")
        lines.append("| \(L10n.text("可用", "Available")) | \(ByteFormat.string(result.system.diskFreeBytes)) (\(ByteFormat.percent(result.system.diskFreeBytes, of: result.system.diskTotalBytes))) |")
        if !result.system.purgeable.isEmpty {
            lines.append("| \(L10n.text("系统可清除", "Purgeable")) | \(tableText(result.system.purgeable)) |")
        }
        lines.append("")

        lines.append("## \(L10n.text("存储评分 v2 与可信度", "Storage Score v2 & Confidence"))")
        lines.append("")
        lines.append("| \(L10n.text("项目", "Metric")) | \(L10n.text("数值", "Value")) | \(L10n.text("说明", "Description")) |")
        lines.append("| --- | ---: | --- |")
        lines.append("| \(L10n.text("扫描模式", "Scan Mode")) | \(tableText(result.scanMode.title)) | \(tableText(result.scanMode.reportDescription)) |")
        lines.append("| \(L10n.text("存储评分 v2", "Storage Score v2")) | \(scoreBreakdown.score)/100 | \(tableText(scoreSummary(for: scoreBreakdown.score))) |")
        lines.append("| \(L10n.text("总扣分", "Total Deductions")) | \(scoreBreakdown.totalPenalty) | \(L10n.text("分数越高代表空间余量更充足、可安全清理积压与扫描缺口更少。", "Higher is better: more storage headroom, less safe-cleanup backlog, and fewer scan gaps.")) |")
        lines.append("| \(L10n.text("状态扣分", "Health Deductions")) | \(scoreBreakdown.healthPenalty) | \(L10n.text("来自可用空间与可安全清理积压。", "From available space and safe-cleanup backlog.")) |")
        lines.append("| \(L10n.text("可信度扣分", "Confidence Deductions")) | \(scoreBreakdown.confidencePenalty) | \(tableText(scoreBreakdown.confidenceDetail)) |")
        lines.append("| \(L10n.text("结果时效", "Result Freshness")) | \(tableText(freshnessValue(for: freshness))) | \(tableText(freshnessSummary(for: freshness))) |")
        lines.append("| \(L10n.text("权限覆盖率", "Access Coverage")) | \(coverage.estimatedCoveragePercent)% | \(tableText(coverageSummary(for: coverage))) |")
        lines.append("| \(L10n.text("扫描完成状态", "Scan Completion")) | \(result.scanWasLimited ? L10n.text("部分完成", "Partial") : L10n.text("完整完成", "Complete")) | \(result.scanWasLimited ? L10n.text("达到扫描预算或安全数量上限，部分位置未完成；建议重新扫描。", "A scan budget or safety cap was reached before every location completed; rescan is recommended.") : L10n.text("扫描在预算与安全上限内完成。", "The scan completed within its budget and safety caps.")) |")
        lines.append("| \(L10n.text("权限缺口", "Access Gaps")) | \(coverage.deniedCount) | \(coverage.deniedCount == 0 ? L10n.text("没有发现未读取位置。", "No unreadable locations were detected.") : L10n.text("授权后重新扫描可提高排行和评分准确度。", "Grant access and rescan to improve ranking and score accuracy.")) |")
        lines.append("")
        lines.append("| \(L10n.text("评分项", "Score Factor")) | \(L10n.text("扣分", "Deduction")) | \(L10n.text("状态", "Status")) | \(L10n.text("说明", "Detail")) |")
        lines.append("| --- | ---: | --- | --- |")
        for factor in scoreBreakdown.factors {
            lines.append("| \(tableText(factor.title)) | \(penaltyText(factor.penalty)) | \(tableText(severityText(factor.severity))) | \(tableText(factor.detail)) |")
        }
        lines.append("")

        lines.append("## \(L10n.text("清理分级", "Cleanup Tiers"))")
        lines.append("")
        lines.append("| \(L10n.text("分级", "Tier")) | \(L10n.text("数量", "Count")) | \(L10n.text("占用", "Size")) | \(L10n.text("说明", "Description")) |")
        lines.append("| --- | ---: | ---: | --- |")
        for tier in [StorageTier.green, .yellow, .red] {
            lines.append("| \(tableText(tier.title)) | \(result.items(forTier: tier).count) | \(ByteFormat.string(result.bytes(for: tier))) | \(tableText(tier.detail)) |")
        }
        lines.append("| \(L10n.text("已移到废纸篓", "Moved to Trash")) | \(movedCount) | - | \(L10n.text("仅表示已移到废纸篓，清空前仍可恢复；空间释放以清空废纸篓为准。", "Only moved to Trash; recoverable until emptied. Space is freed after Trash is emptied.")) |")
        lines.append("")

        lines.append("## \(L10n.text("建议", "Recommendations"))")
        lines.append("")
        if result.greenBytes > 0 {
            lines.append("- \(L10n.text("优先处理可安全清理项目：这些通常是缓存、临时文件或可重建内容，软件只会把它们移到废纸篓。", "Start with safe cleanup items: these are usually caches, temporary files, or rebuildable data, and the app only moves them to Trash."))")
        } else {
            lines.append("- \(L10n.text("当前没有可安全清理项目。", "There are no items ready for safe cleanup."))")
        }
        if result.yellowBytes > 0 {
            lines.append("- \(L10n.text("黄灯项目需要你确认内容是否还需要，例如下载、附件、离线文件或应用资料。", "Review yellow items manually, such as downloads, attachments, offline files, or app data."))")
        }
        if result.redBytes > 0 {
            lines.append("- \(L10n.text("红灯项目不要直接删除，建议先在访达或原应用里确认。", "Do not delete red items directly; inspect them in Finder or the original app first."))")
        }
        if !deniedPaths.isEmpty {
            lines.append("- \(L10n.text("有些路径因为 macOS 权限没有读取到，可在系统设置里给本软件授予完整磁盘访问权限后重新扫描。", "Some paths were not readable due to macOS permissions; grant Full Disk Access and scan again if needed."))")
        }
        if freshness.shouldRescan {
            lines.append("- \(L10n.text("这份报告基于较早的扫描结果；如果最近下载、删除、更新软件或清空废纸篓，请先重新扫描。", "This report is based on an older scan; rescan first if downloads, deletions, app updates, or Trash changes happened recently."))")
        }
        lines.append("")

        lines.append("## \(L10n.text("占用排行 Top 5", "Top 5 by Size"))")
        lines.append("")
        if topItems.isEmpty {
            lines.append(L10n.text("没有可展示项目。", "No items to show."))
        } else {
            lines.append("| \(L10n.text("项目", "Item")) | \(L10n.text("分级", "Tier")) | \(L10n.text("大小", "Size")) | \(L10n.text("建议", "Recommendation")) |")
            lines.append("| --- | --- | ---: | --- |")
            for item in topItems {
                lines.append("| \(tableText(item.title)) | \(tableText(item.tier.title)) | \(ByteFormat.string(item.sizeBytes)) | \(tableText(item.recommendation)) |")
            }
        }
        lines.append("")

        lines.append("## \(L10n.text("开发工具与产物", "Development Tools & Artifacts"))")
        lines.append("")
        lines.append(L10n.text(
            "明确缓存和临时文件可在退出相关应用后移到废纸篓；日志、截图、运行记录、安装包和发布产物仅定位，不会由本工具直接删除。",
            "Explicit caches and temporary files can move to Trash after related apps quit. Logs, screenshots, runtime records, installers, and release artifacts are located for review and are not deleted directly by this tool."
        ))
        lines.append("")
        if developerArtifactItems.isEmpty {
            lines.append(L10n.text("没有发现开发工具缓存或中间产物。", "No development-tool caches or artifacts were found."))
        } else {
            lines.append("| \(L10n.text("候选组", "Candidate Group")) | \(L10n.text("分级", "Tier")) | \(L10n.text("大小", "Size")) | \(L10n.text("路径", "Path")) | \(L10n.text("处理方式", "Action")) |")
            lines.append("| --- | --- | ---: | --- | --- |")
            for item in developerArtifactItems.prefix(50) {
                let action: String
                if item.status == .movedToTrash {
                    action = L10n.text("已移到废纸篓", "Moved to Trash")
                } else if item.canMoveToTrash {
                    action = L10n.text("确认关闭要求后可移到废纸篓", "Can move to Trash after confirming quit requirements")
                } else {
                    action = L10n.text("仅定位，人工复核", "Locate only; review manually")
                }
                lines.append("| \(tableText(item.title)) | \(tableText(item.tier.title)) | \(ByteFormat.string(item.sizeBytes)) | \(tableText(item.path)) | \(tableText(action)) |")
            }
            if developerArtifactItems.count > 50 {
                lines.append("")
                lines.append(L10n.text(
                    "另有 \(developerArtifactItems.count - 50) 组候选未列出。",
                    "\(developerArtifactItems.count - 50) more candidate groups omitted."
                ))
            }
        }
        lines.append("")

        lines.append("## \(L10n.text("无法读取的路径", "Unreadable Paths"))")
        lines.append("")
        if deniedPaths.isEmpty {
            lines.append(L10n.text("没有发现无法读取的路径。", "No unreadable paths were detected."))
        } else {
            for path in deniedPaths.prefix(40) {
                lines.append("- `\(path)`")
            }
            if deniedPaths.count > 40 {
                lines.append("- \(L10n.text("另有 \(deniedPaths.count - 40) 个路径未列出。", "\(deniedPaths.count - 40) more paths omitted."))")
            }
        }

        return lines.joined(separator: "\n") + "\n"
    }

    private static func defaultReportDirectory() -> URL? {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads", isDirectory: true)
    }

    private static func displayDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = L10n.locale
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    private static func fileStamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: date)
    }

    private static func tableText(_ value: String) -> String {
        value
            .replacingOccurrences(of: "|", with: "\\|")
            .replacingOccurrences(of: "\n", with: " ")
    }

    private static func scoreSummary(for score: Int) -> String {
        SmartScoreBand(score: score).summary
    }

    private static func coverageSummary(for coverage: ScanCoverageSummary) -> String {
        switch coverage.level {
        case .complete:
            return L10n.text("本次扫描口径完整。", "This scan had full coverage.")
        case .partial:
            return L10n.text("本次扫描局部受限。", "This scan was partially limited.")
        case .limited:
            return L10n.text("本次扫描明显受限。", "This scan was significantly limited.")
        }
    }

    private static func freshnessValue(for freshness: ScanFreshnessSummary) -> String {
        switch freshness.level {
        case .fresh:
            return L10n.text("2 小时内", "Under 2h")
        case .aging:
            return L10n.text("超过 2 小时", "Over 2h")
        case .stale:
            return L10n.text("超过 24 小时", "Over 24h")
        }
    }

    private static func freshnessSummary(for freshness: ScanFreshnessSummary) -> String {
        switch freshness.level {
        case .fresh:
            return L10n.text("结果仍可直接参考。", "The result is still current.")
        case .aging:
            return L10n.text("结果可能受近期下载、删除或更新影响。", "The result may be affected by recent downloads, deletions, or updates.")
        case .stale:
            return L10n.text("建议重新扫描后再执行清理。", "Rescan before performing cleanup.")
        }
    }

    private static func severityText(_ severity: SmartScoreSeverity) -> String {
        switch severity {
        case .good:
            return L10n.text("良好", "Good")
        case .notice:
            return L10n.text("提示", "Notice")
        case .warning:
            return L10n.text("注意", "Warning")
        case .critical:
            return L10n.text("关键", "Critical")
        }
    }

    private static func penaltyText(_ penalty: Int) -> String {
        penalty == 0 ? "0" : "-\(penalty)"
    }
}

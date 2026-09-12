import Foundation

enum MaintenanceChecklistServiceError: LocalizedError {
    case missingDirectory

    var errorDescription: String? {
        switch self {
        case .missingDirectory:
            L10n.text("找不到可写入的维护清单目录", "Could not find a writable checklist directory")
        }
    }
}

struct MaintenanceChecklistService {
    static func export(
        plan: SmartMaintenancePlan,
        result: ScanResult,
        directory: URL? = nil,
        generatedAt: Date = Date(),
        fileManager: FileManager = .default
    ) throws -> URL {
        let reportDirectory = directory ?? defaultReportDirectory()
        guard let reportDirectory else { throw MaintenanceChecklistServiceError.missingDirectory }

        try fileManager.createDirectory(at: reportDirectory, withIntermediateDirectories: true)

        let fileName = L10n.text("存储清理助手-维护清单-", "StorageCleaner-Maintenance-") + fileStamp(generatedAt) + ".md"
        let url = reportDirectory.appendingPathComponent(fileName)
        try markdown(for: plan, result: result, generatedAt: generatedAt).write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    static func markdown(
        for plan: SmartMaintenancePlan,
        result: ScanResult,
        generatedAt: Date = Date()
    ) -> String {
        let score = ScanHistoryService.scoreBreakdown(for: result, referenceDate: generatedAt).score

        var lines = [String]()
        lines.append("# \(L10n.text("存储清理助手今日维护清单", "Storage Cleaner Maintenance Checklist"))")
        lines.append("")
        lines.append("- \(L10n.text("生成时间", "Generated")): \(displayDate(generatedAt))")
        lines.append("- \(L10n.text("扫描完成", "Scan completed")): \(displayDate(result.generatedAt))")
        lines.append("- \(L10n.text("存储评分", "Storage score")): \(score)/100")
        lines.append("- \(L10n.text("维护状态", "Maintenance status")): \(plan.statusTitle)")
        lines.append("- \(L10n.text("安全收益", "Safe gain")): \(plan.opportunityBytes > 0 ? ByteFormat.string(plan.opportunityBytes) : L10n.text("无明显空间收益", "no obvious space gain"))")
        lines.append("")

        lines.append("## \(L10n.text("执行顺序", "Execution Order"))")
        lines.append("")
        lines.append("| \(L10n.text("优先级", "Priority")) | \(L10n.text("项目", "Item")) | \(L10n.text("数值", "Value")) | \(L10n.text("动作", "Action")) | \(L10n.text("说明", "Detail")) |")
        lines.append("| --- | --- | ---: | --- | --- |")
        if plan.tasks.isEmpty {
            lines.append("| - | \(L10n.text("暂无待处理项目", "No pending items")) | - | \(L10n.text("无需操作", "No action needed")) | \(L10n.text("当前扫描没有发现需要立即处理的维护项。", "The current scan has no maintenance items that need immediate action.")) |")
        } else {
            for task in plan.tasks {
                lines.append("| \(tableText(task.priority.title)) | \(tableText(task.title)) | \(tableText(task.value)) | \(tableText(actionText(for: task.action))) | \(tableText(task.detail)) |")
            }
        }
        lines.append("")

        lines.append("## \(L10n.text("可直接推进", "Can Start Directly"))")
        lines.append("")
        if plan.quickStartTasks.isEmpty {
            lines.append(L10n.text("没有可从总览直接启动的维护项。", "No maintenance items can start directly from Overview."))
        } else {
            for task in plan.quickStartTasks {
                lines.append("- **\(task.title)**: \(task.value) · \(task.detail)")
            }
        }
        lines.append("")

        lines.append("## \(L10n.text("需要人工确认", "Needs Manual Review"))")
        lines.append("")
        if plan.reviewTasks.isEmpty {
            lines.append(L10n.text("没有需要人工确认的维护项。", "No maintenance items need manual review."))
        } else {
            for task in plan.reviewTasks {
                lines.append("- **\(task.title)**: \(task.value) · \(task.detail)")
            }
        }
        lines.append("")

        lines.append("## \(L10n.text("清理安全边界", "Cleanup Safety Boundaries"))")
        lines.append("")
        lines.append("- \(L10n.text("这份清单只记录建议，不会自动删除任何文件。", "This checklist records recommendations only and does not delete files automatically."))")
        lines.append("- \(L10n.text("可安全清理项目也只会先移动到废纸篓，清空废纸篓前仍可恢复。", "Safe cleanup items are moved to Trash first and remain recoverable until Trash is emptied."))")
        lines.append("- \(L10n.text("需确认项、谨慎处理项、应用文件、云盘本地副本和重复文件都需要人工确认。", "Review items, careful items, app bundles, cloud-local copies, and duplicates need manual confirmation."))")
        if !result.deniedPaths.isEmpty {
            lines.append("- \(L10n.text("本次扫描有 \(result.deniedPaths.count) 个权限缺口；授权后重新扫描，清单会更准确。", "This scan had \(result.deniedPaths.count) access gaps; grant access and rescan for a more accurate checklist."))")
        }
        lines.append("")

        lines.append("## \(L10n.text("主要空间来源", "Main Storage Sources"))")
        lines.append("")
        let topItems = result.topItems
        if topItems.isEmpty {
            lines.append(L10n.text("没有可展示项目。", "No items to show."))
        } else {
            lines.append("| \(L10n.text("项目", "Item")) | \(L10n.text("分级", "Tier")) | \(L10n.text("大小", "Size")) | \(L10n.text("建议", "Recommendation")) |")
            lines.append("| --- | --- | ---: | --- |")
            for item in topItems {
                lines.append("| \(tableText(item.title)) | \(tableText(item.tier.title)) | \(ByteFormat.string(item.sizeBytes)) | \(tableText(item.recommendation)) |")
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

    private static func actionText(for action: SmartMaintenanceAction) -> String {
        switch action {
        case .cleanGreen:
            L10n.text("预览并移动可安全清理项目到废纸篓", "Preview and move safe cleanup items to Trash")
        case .openPermissions:
            L10n.text("打开完整磁盘访问权限设置", "Open Full Disk Access settings")
        case .review(let filter):
            L10n.text("打开 \(filter.sidebarDestination.title) 页面人工复核", "Open \(filter.sidebarDestination.title) for manual review")
        case .scanAppUpdates:
            L10n.text("扫描可升级程序", "Scan app updates")
        case .scanStartupItems:
            L10n.text("检查登录项与后台任务", "Check login items and background tasks")
        case .refreshMemory:
            L10n.text("读取内存状态", "Read memory status")
        case .optimizeMemory:
            L10n.text("请求系统回收文件缓存", "Request system file-cache reclaim")
        case .scanDuplicates:
            L10n.text("扫描重复文件候选", "Scan duplicate file candidates")
        case .exportReport:
            L10n.text("导出完整扫描报告", "Export full scan report")
        }
    }
}

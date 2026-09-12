import Foundation

enum SmartMaintenanceService {
    static func plan(
        result: ScanResult,
        appUpdateCount: Int,
        hasScannedAppUpdates: Bool,
        startupItemCount: Int,
        hasScannedStartupItems: Bool,
        memorySnapshot: MemorySnapshot?,
        hasScannedDuplicates: Bool,
        duplicateCount: Int
    ) -> SmartMaintenancePlan {
        let maintenanceTasks = tasks(
            result: result,
            appUpdateCount: appUpdateCount,
            hasScannedAppUpdates: hasScannedAppUpdates,
            startupItemCount: startupItemCount,
            hasScannedStartupItems: hasScannedStartupItems,
            memorySnapshot: memorySnapshot,
            hasScannedDuplicates: hasScannedDuplicates,
            duplicateCount: duplicateCount
        )
        let safeCleanupBytes = result.items(for: .green)
            .filter(\.canMoveToTrash)
            .reduce(Int64(0)) { $0 + $1.sizeBytes }
        return SmartMaintenancePlan(
            tasks: maintenanceTasks,
            quickStartTasks: maintenanceTasks.filter { $0.action.canStartFromOverview },
            reviewTasks: maintenanceTasks.filter { $0.action.needsHumanReview },
            safeCleanupBytes: safeCleanupBytes
        )
    }

    static func tasks(
        result: ScanResult,
        appUpdateCount: Int,
        hasScannedAppUpdates: Bool,
        startupItemCount: Int,
        hasScannedStartupItems: Bool,
        memorySnapshot: MemorySnapshot?,
        hasScannedDuplicates: Bool,
        duplicateCount: Int,
        limit: Int = .max
    ) -> [SmartMaintenanceTask] {
        var tasks = [SmartMaintenanceTask]()

        if !result.deniedPaths.isEmpty {
            tasks.append(
                SmartMaintenanceTask(
                    id: "permissions",
                    title: L10n.text("补齐磁盘访问权限", "Grant Disk Access"),
                    detail: L10n.text("有位置未能读取，授权后总览和清理建议会更准确。", "Some locations were not readable. Grant access for a more accurate scan."),
                    value: L10n.items(result.deniedPaths.count),
                    systemImage: "lock.fill",
                    priority: .urgent,
                    action: .openPermissions
                )
            )
        }

        let cleanableCount = result.items(for: .green).filter(\.canMoveToTrash).count
        if result.greenBytes > 0, cleanableCount > 0 {
            tasks.append(
                SmartMaintenanceTask(
                    id: "clean-green",
                    title: L10n.text("预览可安全清理项", "Preview Safe Cleanup"),
                    detail: L10n.text("仅移动到废纸篓，清空前可恢复；适合批量处理。", "Moves only safe items to Trash so they remain recoverable until Trash is emptied."),
                    value: ByteFormat.string(result.greenBytes),
                    systemImage: "sparkles",
                    priority: result.greenBytes > 1_000_000_000 ? .urgent : .recommended,
                    action: .cleanGreen
                )
            )
        }

        if result.redBytes > 0 {
            tasks.append(
                SmartMaintenanceTask(
                    id: "review-careful",
                    title: L10n.text("复核谨慎处理项", "Review Careful Items"),
                    detail: L10n.text("这些通常是应用文件或高风险路径，不会自动删除。", "These are usually app bundles or risky paths and are never removed automatically."),
                    value: ByteFormat.string(result.redBytes),
                    systemImage: "exclamationmark.triangle.fill",
                    priority: .recommended,
                    action: .review(.green)
                )
            )
        } else if result.yellowBytes > 0 {
            tasks.append(
                SmartMaintenanceTask(
                    id: "review-manual",
                    title: L10n.text("检查需确认项", "Review Manual Items"),
                    detail: L10n.text("通常是下载、离线内容或用户资料，先确认再处理。", "Usually downloads, offline content, or user data. Review before taking action."),
                    value: ByteFormat.string(result.yellowBytes),
                    systemImage: "questionmark.circle.fill",
                    priority: .recommended,
                    action: .review(.green)
                )
            )
        }

        if appUpdateCount > 0 {
            tasks.append(
                SmartMaintenanceTask(
                    id: "app-updates",
                    title: L10n.text("处理应用更新", "Update Apps"),
                    detail: L10n.text("已读取当前版本与可用版本，可进入系统工具的应用更新页处理。", "Current and available versions were read; use App Updates in System Tools."),
                    value: L10n.items(appUpdateCount),
                    systemImage: "arrow.triangle.2.circlepath",
                    priority: .recommended,
                    action: .review(.updater)
                )
            )
        } else if !hasScannedAppUpdates {
            tasks.append(
                SmartMaintenanceTask(
                    id: "scan-app-updates",
                    title: L10n.text("检查应用更新", "Check App Updates"),
                    detail: L10n.text("读取 App Store 与 Homebrew 的最新版本，已是最新的软件不会显示。", "Reads App Store and Homebrew latest versions; current apps stay hidden."),
                    value: L10n.text("未扫描", "Not scanned"),
                    systemImage: "bag.fill",
                    priority: .routine,
                    action: .scanAppUpdates
                )
            )
        }

        if duplicateCount > 0 {
            tasks.append(
                SmartMaintenanceTask(
                    id: "review-duplicates",
                    title: L10n.text("复核重复文件", "Review Duplicates"),
                    detail: L10n.text("重复文件只提示不自动删除，避免误删用户资料。", "Duplicates are review-only to avoid deleting personal files by mistake."),
                    value: L10n.items(duplicateCount),
                    systemImage: "equal",
                    priority: .recommended,
                    action: .review(.duplicates)
                )
            )
        } else if !hasScannedDuplicates {
            tasks.append(
                SmartMaintenanceTask(
                    id: "scan-duplicates",
                    title: L10n.text("扫描重复文件", "Scan Duplicates"),
                    detail: L10n.text("单独检查下载、桌面和文稿中的疑似重复大型文件。", "Checks possible duplicate large files in Downloads, Desktop, and Documents."),
                    value: L10n.text("可检查", "Available"),
                    systemImage: "doc.on.doc.fill",
                    priority: .routine,
                    action: .scanDuplicates
                )
            )
        }

        if let memorySnapshot {
            if !memorySnapshot.recommendedQuitApps.isEmpty {
                tasks.append(
                    SmartMaintenanceTask(
                        id: "review-memory-apps",
                        title: L10n.text("查看高占用应用", "Review Heavy Apps"),
                        detail: L10n.text("内存压力正常，不建议清缓存；可按需正常退出高占用应用。", "Memory pressure is normal, so cache clearing is not recommended; quit heavy apps normally if needed."),
                        value: L10n.items(memorySnapshot.recommendedQuitApps.count),
                        systemImage: "app.badge.checkmark",
                        priority: .routine,
                        action: .refreshMemory
                    )
                )
            }
        } else {
            tasks.append(
                SmartMaintenanceTask(
                    id: "refresh-memory",
                    title: L10n.text("读取内存状态", "Read Memory Status"),
                    detail: L10n.text("查看内存压力、交换趋势和高占用进程。", "Shows memory pressure, swap trends, and heavy processes."),
                    value: L10n.text("未读取", "Not read"),
                    systemImage: "memorychip",
                    priority: .routine,
                    action: .refreshMemory
                )
            )
        }

        if startupItemCount > 0 {
            tasks.append(
                SmartMaintenanceTask(
                    id: "startup-items",
                    title: L10n.text("检查登录项与后台任务", "Review Login Items & Background Tasks"),
                    detail: L10n.text("复核不需要的登录项与后台任务。", "Review unneeded login items and background tasks."),
                    value: L10n.items(startupItemCount),
                    systemImage: "powerplug.fill",
                    priority: .routine,
                    action: .review(.startup)
                )
            )
        } else if !hasScannedStartupItems {
            tasks.append(
                SmartMaintenanceTask(
                    id: "scan-startup",
                    title: L10n.text("读取登录项与后台任务", "Scan Login Items & Background Tasks"),
                    detail: L10n.text("读取登录项、后台任务和只读系统项。", "Reads login items, background tasks, and read-only system items."),
                    value: L10n.text("未检测", "Not scanned"),
                    systemImage: "powerplug",
                    priority: .routine,
                    action: .scanStartupItems
                )
            )
        }

        if tasks.isEmpty {
            tasks.append(
                SmartMaintenanceTask(
                    id: "all-clear",
                    title: L10n.text("当前状态良好", "All Clear"),
                    detail: L10n.text("没有明显需要优先处理的项目，可导出本次扫描报告留档。", "No obvious priority items. Export this scan report for your records."),
                    value: L10n.text("完成", "Done"),
                    systemImage: "checkmark.seal.fill",
                    priority: .complete,
                    action: .exportReport
                )
            )
        }

        return Array(
            tasks
                .sorted {
                    if $0.priority == $1.priority {
                        return taskRank($0.id) < taskRank($1.id)
                    }
                    return $0.priority < $1.priority
                }
                .prefix(limit)
        )
    }

    private static func taskRank(_ id: String) -> Int {
        [
            "permissions",
            "clean-green",
            "review-careful",
            "review-manual",
            "app-updates",
            "scan-app-updates",
            "review-duplicates",
            "scan-duplicates",
            "optimize-memory",
            "refresh-memory",
            "startup-items",
            "scan-startup",
            "all-clear"
        ].firstIndex(of: id) ?? Int.max
    }
}

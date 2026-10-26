import Foundation

struct MyActivityRecommendation: Identifiable, Equatable, Sendable {
    enum Kind: String, CaseIterable, Sendable {
        case health, trash, updates, smartScan, loginItems, maintenance, protection, cloud
    }

    let kind: Kind
    let title: String
    let detail: String
    let destination: ReviewFilter
    let buttonTitle: String
    let priority: Int
    var id: Kind { kind }
    var isGuide: Bool { kind == .protection || kind == .cloud }
}

/// D187: all inputs are values from existing stores. This policy never
/// scans, connects an account, clears Trash, or starts an update or task.
enum MyActivityRecommendations {
    struct State: Equatable, Sendable {
        var latestSmartScanAt: Date?
        var recoverableTrashBytes: Int64 = 0
        var availableUpdateCount = 0
        var loginItemCount = 0
        var managedItemCoverageAvailable = false
        var recommendedMaintenanceCount = 0
        var health = MyActivityHealth(grade: nil, reasons: [], checkedAt: nil)
        var hasProtectionScan = false
        var thirdPartyCloudFolderCount = 0
        var iCloudAvailable = false
        var iCloudLocalBytes: Int64 = 0
        var hasCloudStatistics = false
    }

    static let largeCloudBytes: Int64 = 1_000_000_000
    static let maximumCount = MyActivityRecommendation.Kind.allCases.count
    static let previewCount = 3

    static func title(count: Int) -> String {
        L10n.text("\(ByteFormat.count(count)) 条推荐", "\(ByteFormat.count(count)) Recommendations")
    }

    static func make(_ state: State, now: Date, limit: Int = maximumCount) -> [MyActivityRecommendation] {
        var items: [MyActivityRecommendation] = []
        func add(_ kind: MyActivityRecommendation.Kind, _ priority: Int, _ title: String,
                 _ detail: String, _ destination: ReviewFilter, _ button: String) {
            items.append(.init(kind: kind, title: title, detail: detail, destination: destination,
                               buttonTitle: button, priority: priority))
        }
        if state.health.grade != .good {
            let problem = state.health.grade == .problem
            add(.health, problem ? 0 : 45,
                state.health.grade == nil ? L10n.text("了解这台 Mac 的健康状况", "Check This Mac’s Health")
                    : L10n.text("查看健康检查中的提醒", "Review Health Findings"),
                state.health.helpText, .healthHub, L10n.text("去健康检查", "Open Health Check"))
        }
        if state.recoverableTrashBytes > 0 {
            add(.trash, 10, L10n.text("废纸篓中还有可恢复项目", "Restorable Items Remain in Trash"),
                L10n.text("已核对的可恢复项目至少占 \(ByteFormat.storageString(state.recoverableTrashBytes))。查看后再决定是否清空废纸篓。",
                          "Verified restorable items account for at least \(ByteFormat.storageString(state.recoverableTrashBytes)). Review them before deciding to empty the Trash."),
                .green, L10n.text("去垃圾清理", "Open Cleanup"))
        }
        if state.availableUpdateCount > 0 {
            add(.updates, 20, L10n.text("有应用可以更新", "App Updates Are Available"),
                L10n.text("现有清单中有 \(ByteFormat.count(state.availableUpdateCount)) 个应用提供更新。",
                          "The current list has updates for \(ByteFormat.count(state.availableUpdateCount)) apps."),
                .updater, L10n.text("去应用管理", "Open Applications"))
        }
        let age = state.latestSmartScanAt.map { now.timeIntervalSince($0) }
        if age == nil || age.map({ !$0.isFinite || $0 < 0 || $0 > 7 * 86_400 }) == true {
            add(.smartScan, 30, L10n.text("给 Mac 做一次智能扫描", "Run a Smart Scan"),
                state.latestSmartScanAt == nil
                    ? L10n.text("还没有已完成的智能扫描记录。", "No completed Smart Scan is recorded yet.")
                    : L10n.text("最近一次智能扫描已超过 7 天，或记录时间需要重新确认。", "The last Smart Scan is over 7 days old, or its date needs checking."),
                .overview, L10n.text("去智能扫描", "Open Smart Scan"))
        }
        if state.managedItemCoverageAvailable && state.loginItemCount >= 5 {
            add(.loginItems, 35, L10n.text("检查登录时启动的项目", "Review Login Items"),
                L10n.text("现有扫描列出 \(ByteFormat.count(state.loginItemCount)) 个登录项，可查看哪些还需要自动启动。",
                          "The current scan lists \(ByteFormat.count(state.loginItemCount)) login items. Review which ones still need to start automatically."),
                .startup, L10n.text("去性能优化", "Open Performance"))
        }
        if state.recommendedMaintenanceCount > 0 {
            add(.maintenance, 40, L10n.text("有维护任务可供查看", "Review Maintenance Tasks"),
                L10n.text("维护检查推荐了 \(ByteFormat.count(state.recommendedMaintenanceCount)) 项任务。运行前可查看影响。",
                          "The maintenance check recommends \(ByteFormat.count(state.recommendedMaintenanceCount)) tasks. Review their effects before running them."),
                .startup, L10n.text("去性能优化", "Open Performance"))
        }
        if !state.hasProtectionScan {
            add(.protection, 60, L10n.text("还没查看过防护项目", "Review Protection for the First Time"),
                L10n.text("还没有可用的安全防护扫描结果。可以先查看浏览器中的隐私记录。",
                          "No Protection scan result is available yet. Start by reviewing privacy records in your browsers."),
                .privacy, L10n.text("去安全防护", "Open Protection"))
        }
        let cloudGuide = !state.hasCloudStatistics && (state.iCloudAvailable || state.thirdPartyCloudFolderCount > 0)
        if cloudGuide || state.thirdPartyCloudFolderCount > 0 || state.iCloudLocalBytes >= largeCloudBytes {
            add(.cloud, 70, cloudGuide
                    ? L10n.text("统计云盘的本机占用", "Measure Local Cloud Storage")
                    : L10n.text("查看云盘的本机副本", "Review Local Cloud Copies"),
                state.iCloudLocalBytes >= largeCloudBytes
                    ? L10n.text("现有结果中 iCloud 云盘的本机文件占 \(ByteFormat.storageString(state.iCloudLocalBytes))。",
                              "The current result shows \(ByteFormat.storageString(state.iCloudLocalBytes)) of local iCloud Drive files.")
                    : L10n.text("这台 Mac 上有云盘文件夹，可统计本机副本的占用。", "Cloud folders are present on this Mac. Check how much space their local copies use."),
                .cloudCleanup, L10n.text("去云盘清理", "Open Cloud Cleanup"))
        }
        // One recommendation per rule, including one cloud rule for any
        // number of providers. Shared destinations do not merge distinct advice.
        return Array(items.sorted { $0.priority < $1.priority }.prefix(max(0, min(limit, maximumCount))))
    }
}

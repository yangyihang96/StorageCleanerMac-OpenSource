import Foundation

/// D187: our own estimates of the manual time per completed operation, in
/// minutes. These are product estimates, not measured elapsed time or a
/// claim about another app. No estimate changes receipt byte totals (D93).
struct MyActivityTimeSavings: Equatable, Sendable {
    enum Category: String, CaseIterable, Sendable {
        case uninstall, update, cleanup, maintenance, privacy

        var minutesPerOperation: Int {
            switch self {
            case .uninstall: 10
            case .update: 6
            case .cleanup: 5
            case .maintenance: 3
            case .privacy: 4
            }
        }

        var title: String {
            switch self {
            case .uninstall: L10n.text("卸载应用及残留", "Uninstall Apps and Leftovers")
            case .update: L10n.text("更新应用", "Update Apps")
            case .cleanup: L10n.text("垃圾清理", "Junk Cleanup")
            case .maintenance: L10n.text("维护任务", "Maintenance Tasks")
            case .privacy: L10n.text("隐私清理", "Privacy Cleanup")
            }
        }
    }

    struct Record: Equatable, Sendable {
        let id: String
        let category: Category
        var count = 1
    }

    let counts: [Category: Int]
    let totalMinutes: Int

    static var title: String { L10n.text("节省的时间（估算）", "Time Saved (Estimated)") }
    static var explanation: String {
        L10n.text("按已记录的成功操作和我们自己的手动用时估计计算。更新、维护和隐私只含当前保留的结果。",
                  "Based on recorded successful operations and our own estimates of manual effort. Updates, maintenance and privacy include only retained results.")
    }

    init(records: [Record] = []) {
        // A result may be visible in both a queue and a completion surface.
        // Keep the maximum count per stable operation identity, once only.
        var unique: [String: Record] = [:]
        for record in records where record.count > 0 {
            let key = record.category.rawValue + ":" + record.id
            if record.count > (unique[key]?.count ?? 0) { unique[key] = record }
        }
        var counts: [Category: Int] = [:]
        for record in unique.values {
            counts[record.category] = Self.add(record.count, to: counts[record.category] ?? 0)
        }
        self.counts = counts
        self.totalMinutes = Category.allCases.reduce(0) { total, category in
            let count = counts[category] ?? 0
            let product = count.multipliedReportingOverflow(by: category.minutesPerOperation)
            return Self.add(product.overflow ? Int.max : product.partialValue, to: total)
        }
    }

    func minutes(for category: Category) -> Int {
        let product = (counts[category] ?? 0).multipliedReportingOverflow(by: category.minutesPerOperation)
        return product.overflow ? Int.max : product.partialValue
    }

    static func duration(_ minutes: Int) -> String {
        let value = max(0, minutes)
        if value < 60 {
            return L10n.text("\(ByteFormat.count(value)) 分钟", "\(ByteFormat.count(value)) " + (value == 1 ? "minute" : "minutes"))
        }
        let hours = ByteFormat.count(value / 60)
        let hourText = L10n.text("\(hours) 小时", value / 60 == 1 ? "\(hours) hour" : "\(hours) hours")
        guard value % 60 > 0 else { return hourText }
        return hourText + L10n.text(" \(ByteFormat.count(value % 60)) 分钟",
                                     " \(ByteFormat.count(value % 60)) " + (value % 60 == 1 ? "minute" : "minutes"))
    }

    /// One receipt per application. A reset or leftovers-only cleanup is
    /// not an uninstall: require the application bundle itself to be moved.
    static func receiptRecord(_ index: CleanupReportIndex, detail: CleanReport?) -> Record? {
        guard !OperationRecordPresentation.isTemporaryResource(index.rulesVersion), !index.needsVerification,
              index.outcome == .completed || index.outcome == .partiallyCompleted else { return nil }
        if index.rulesVersion.hasPrefix("uninstall.") {
            guard let detail, detail.persistenceFailure == nil else { return nil }
            let appPaths = Set(detail.items.compactMap { item -> String? in
                guard case .moved(let receipt) = item.outcome, receipt.isRestorable,
                      URL(fileURLWithPath: item.sourcePath).pathExtension.lowercased() == "app" else { return nil }
                return item.sourcePath
            })
            guard !appPaths.isEmpty else { return nil }
            return Record(id: index.id.uuidString, category: .uninstall, count: appPaths.count)
        }
        guard MyActivitySummary.category(for: index.rulesVersion) == .systemJunk,
              ToolboxOperationTitles.prefix(for: index.rulesVersion) == nil,
              index.summary.movedItemCount > 0 || (index.summary.deletedItemCount ?? 0) > 0 else { return nil }
        return Record(id: index.id.uuidString, category: .cleanup)
    }

    static func retainedRecords(updates: ApplicationUpdateQueueSnapshot?, website: WebsiteUpdateQueueSnapshot?,
                                maintenance: [SystemMaintenanceRunResult], privacy: BrowserPrivacyProcessingReport?) -> [Record] {
        var records = (updates?.tasks ?? []).filter { $0.state == .completed && !$0.requiresInstallationReconciliation }
            .map { Record(id: $0.id.uuidString, category: .update) }
        records += (website?.items ?? []).filter { $0.state == .completed }
            .map { Record(id: $0.id.uuidString, category: .update) }
        records += maintenance.filter { $0.outcome == .succeeded }.map {
            Record(id: $0.task.rawValue + ":" + String($0.finishedAt.timeIntervalSinceReferenceDate), category: .maintenance)
        }
        if let privacy, privacy.entries.contains(where: { !$0.verifiedDeletedRecordIDs.isEmpty }) {
            // One confirmed cleanup batch, not one estimate per browser row.
            records.append(Record(id: "retained-privacy-report", category: .privacy))
        }
        return records
    }

    private static func add(_ value: Int, to total: Int) -> Int {
        let sum = total.addingReportingOverflow(value)
        return sum.overflow ? Int.max : sum.partialValue
    }
}

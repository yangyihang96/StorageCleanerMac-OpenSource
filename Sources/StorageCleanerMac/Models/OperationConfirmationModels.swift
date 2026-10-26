import Foundation

// D93：所有清理／卸载类确认页与完成页共用的口径。
// 确认页固定列出六个字段：动作、对象、容量、需退出的应用、恢复方式、权限覆盖；
// 完成页固定分成完成／跳过／失败／待核实四组，“移到废纸篓”只算已移到废纸篓，
// 只有永久删除并回读确认（或清空废纸篓）的部分才计为实际释放。
// 本文件只做展示模型，不改变任何执行、预选或恢复行为（D19/D23/D47/D52 不变）。

/// 接入共享确认／完成口径的页面（D93 ④ 覆盖范围）。
enum OperationSurface: String, CaseIterable, Sendable {
    case safeCleanup
    case developerTools
    case smartScan
    case uninstall
    case duplicateFiles
    case fileAnalysis
    case browserHistory
    case emptyTrash

    var title: String {
        switch self {
        case .safeCleanup: L10n.text("安全清理", "Safe Cleanup")
        case .developerTools: L10n.text("开发工具与产物", "Developer Tools & Artifacts")
        case .smartScan: L10n.text("智能扫描结果", "Smart Scan Results")
        case .uninstall: L10n.text("卸载（含残留）", "Uninstall (Including Leftovers)")
        case .duplicateFiles: L10n.text("重复文件", "Duplicate Files")
        case .fileAnalysis: L10n.text("文件分析移到废纸篓", "File Analysis: Move to Trash")
        case .browserHistory: L10n.text("浏览器隐私历史删除", "Browser History Deletion")
        case .emptyTrash: L10n.text("清空废纸篓", "Empty Trash")
        }
    }
}

extension OperationSurface {
    /// 同一张冻结计划确认表服务安全清理、开发工具与产物、智能扫描和重复文件。
    /// 智能扫描由计划所属的扫描会话判断（会话带智能扫描范围且与计划同一会话）。
    static func inferred(for plan: CleanPlan, session: ScanSession?) -> OperationSurface {
        let fromSmartScan = session.map { $0.id == plan.sessionID && $0.smartScanScopes != nil } ?? false
        return inferred(for: plan.items, fromSmartScan: fromSmartScan)
    }

    static func inferred(for items: [CleanPlanItem], fromSmartScan: Bool = false) -> OperationSurface {
        if !items.isEmpty, items.allSatisfy({ $0.verifiedDuplicateEvidence != nil }) { return .duplicateFiles }
        if fromSmartScan { return .smartScan }
        if !items.isEmpty, items.allSatisfy({ $0.ruleID.hasPrefix("developer.") }) { return .developerTools }
        return .safeCleanup
    }
}

/// 确认页“动作”字段。
enum OperationActionKind: String, CaseIterable, Sendable {
    case moveToTrash
    case moveToQuarantine
    case permanentDeletion
    case uninstall
    case releaseLocalCopy
    case deleteBrowserHistory
    case inBrowserSteps

    var title: String {
        switch self {
        case .moveToTrash: L10n.text("移到废纸篓", "Move to Trash")
        case .moveToQuarantine: L10n.text("移入隔离区", "Move to Quarantine")
        case .permanentDeletion: L10n.text("永久删除（不可恢复）", "Delete Permanently (Cannot Be Undone)")
        case .uninstall: L10n.text("卸载（应用移到废纸篓）", "Uninstall (App Moves to Trash)")
        case .releaseLocalCopy: L10n.text("释放本地副本（云端保留）", "Remove Local Copy (Kept in the Cloud)")
        case .deleteBrowserHistory: L10n.text("删除浏览记录", "Delete Browsing History")
        case .inBrowserSteps: L10n.text("只生成浏览器内处理步骤", "In-Browser Steps Only")
        }
    }
}

/// 确认页“恢复方式”字段。
enum OperationRecoveryMethod: String, CaseIterable, Sendable {
    case trashAndOperationHistory
    case otherVolumeTrash
    case quarantine
    case browserBackup
    case notRecoverable
    case noChange

    var text: String {
        switch self {
        case .trashAndOperationHistory:
            L10n.text("可从废纸篓放回，或在“操作记录”中恢复到原位置", "Put back from the Trash, or restore from Operation History")
        case .otherVolumeTrash:
            L10n.text("其他卷上的项目进入该卷的废纸篓，需要时在访达中放回", "Items on other volumes go to that volume's Trash; put them back in Finder")
        case .quarantine:
            L10n.text("可从隔离区恢复", "Restorable from Quarantine")
        case .browserBackup:
            L10n.text("删除前备份历史数据库，可在“最近的删除”中恢复（有保留期）", "The history database is backed up first; restore from Recent Deletions within the retention period")
        case .notRecoverable:
            L10n.text("永久删除的部分不可恢复", "Permanently deleted items cannot be restored")
        case .noChange:
            L10n.text("本应用不修改数据，无需恢复", "This app changes nothing, so nothing needs restoring")
        }
    }
}

/// 确认页“权限覆盖”字段：完全磁盘访问缺失时哪些会被跳过。
enum OperationPermissionCoverage: Equatable, Sendable {
    case verified
    case missingFullDiskAccess(limitedLocations: [String])
    case unknown
    case notRequired

    static func from(_ summary: ScanReadinessSummary?) -> Self {
        guard let summary else { return .unknown }
        if summary.isFullDiskAccessVerified { return .verified }
        if summary.fullDiskAccessState == .unknown && summary.blockedCount == 0 { return .unknown }
        return .missingFullDiskAccess(limitedLocations: summary.blockedItems.map(\.location.title))
    }

    /// 页面没有现成的权限检查结果时（文件分析），读一次完全磁盘访问探针。
    static func from(_ state: FullDiskAccessState) -> Self {
        switch state {
        case .verified: .verified
        case .notVerified: .missingFullDiskAccess(limitedLocations: [])
        case .unknown: .unknown
        }
    }

    var isLimited: Bool {
        switch self {
        case .verified, .notRequired: false
        case .missingFullDiskAccess, .unknown: true
        }
    }

    var text: String {
        switch self {
        case .verified:
            return L10n.text("完全磁盘访问已生效；所列项目都在可处理范围内", "Full Disk Access is active; every listed item is within reach")
        case .missingFullDiskAccess(let locations):
            let list = OperationConfirmationFacts.abbreviatedList(locations)
            let named = locations.isEmpty ? "" : L10n.text("（\(list)）", " (\(list))")
            return L10n.text(
                "未授予完全磁盘访问：受保护位置\(named)本次未列出；无权限的项目会跳过，完成页逐项说明",
                "No Full Disk Access: protected locations\(named) were not listed; items without access are skipped and explained afterward"
            )
        case .unknown:
            return L10n.text(
                "尚未确认完全磁盘访问；没有权限的项目会跳过，并在完成页逐项说明",
                "Full Disk Access is not confirmed; items without permission are skipped and explained on the result page"
            )
        case .notRequired:
            return L10n.text("不需要额外权限", "No extra permission needed")
        }
    }
}

/// 确认页对象清单的一行。
struct OperationConfirmationItem: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let path: String?
    let bytes: Int64?
    /// 归属、影响或不会执行的原因；为空时视图只显示名称与路径。
    var detail: String? = nil
}

/// 确认页六个固定字段。
struct OperationConfirmationFacts: Equatable, Sendable {
    enum Field: String, CaseIterable, Sendable {
        case action, objects, capacity, appsToQuit, recovery, permission

        var title: String {
            switch self {
            case .action: L10n.text("动作", "Action")
            case .objects: L10n.text("对象", "Items")
            case .capacity: L10n.text("容量", "Space")
            case .appsToQuit: L10n.text("需退出的应用", "Apps to Quit")
            case .recovery: L10n.text("恢复方式", "Recovery")
            case .permission: L10n.text("权限覆盖", "Permission Coverage")
            }
        }
    }

    struct Row: Identifiable, Equatable, Sendable {
        var id: Field { field }
        let field: Field
        let value: String
        let isWarning: Bool
    }

    var surface: OperationSurface
    var actions: [OperationActionKind]
    var items: [OperationConfirmationItem]
    /// 不会执行的项目数（未通过检查、被保护等），只计数并说明。
    var notRunCount: Int = 0
    /// D84 本地占用。nil 表示不涉及磁盘空间（例如浏览记录）。
    var localBytes: Int64?
    /// 有项目大小未知或只量到下限。
    var bytesAreLowerBound: Bool = false
    /// 移到废纸篓的部分含 APFS 克隆（已核实重复文件）或另有硬链接：清空废纸篓后
    /// 最多释放这么多，实际可回收量待确认（与执行器 `reclaimableAfterEmptyingTrashBytes == nil` 同口径）。
    var physicalReleaseUnknown: Bool = false
    /// 其中移到废纸篓／隔离区的部分（不释放空间）。
    var trashBytes: Int64 = 0
    /// D104 G1：移到废纸篓的部分里有明显一部分与 APFS 克隆共享或被本地快照占用时，
    /// 清空废纸篓后预计释放的量；文件夹不逐项读取，按完整大小计。
    var trashReclaimable: TrashReclaimable? = nil
    var quarantineBytes: Int64 = 0
    /// 其中永久删除的部分（删除后回读确认才计为释放）。
    var permanentDeletionBytes: Int64 = 0
    var appsToQuit: [String] = []
    var recovery: [OperationRecoveryMethod]
    var permission: OperationPermissionCoverage
    /// 浏览记录按访问条数计，清单按浏览器列出。
    var recordCount: Int? = nil
    /// 对象字段的额外警示（例如卸载勾选了含个人资料的项目）。
    var objectWarnings: [String] = []

    var itemCount: Int { items.count }
    /// 将执行的数量，与确认表头部“检查通过”同数。
    var readyCount: Int { max(0, itemCount - notRunCount) }

    var rows: [Row] {
        Field.allCases.map { field in
            Row(field: field, value: value(for: field), isWarning: isWarning(field))
        }
    }

    func value(for field: Field) -> String {
        switch field {
        case .action:
            let titles = actions.map(\.title)
            return titles.isEmpty ? L10n.text("没有可执行的动作", "Nothing to run") : titles.joined(separator: L10n.text("、", ", "))
        case .objects:
            var text: String
            if let recordCount {
                let names = items.map(\.title).joined(separator: L10n.text("、", ", "))
                text = L10n.text("\(ByteFormat.count(recordCount)) 条浏览记录（\(names)）", "\(ByteFormat.count(recordCount)) browsing records (\(names))")
            } else if notRunCount > 0 {
                // P1-1：总数拆成将执行与不会执行，不把跳过的项目算两次。
                text = L10n.text(
                    "共 \(ByteFormat.count(itemCount)) 项：\(ByteFormat.count(readyCount)) 项将执行，\(ByteFormat.count(notRunCount)) 项不会执行（原因见清单）",
                    "\(ByteFormat.count(itemCount)) items in total: \(ByteFormat.count(readyCount)) will run, \(ByteFormat.count(notRunCount)) will not (reasons in the list)"
                )
            } else {
                text = L10n.items(itemCount)
            }
            for warning in objectWarnings {
                text += L10n.text("；", "; ") + warning
            }
            return text
        case .capacity:
            return capacityText
        case .appsToQuit:
            guard !appsToQuit.isEmpty else { return L10n.text("无需退出应用", "No app needs to quit") }
            let names = Self.abbreviatedList(appsToQuit)
            return L10n.text(
                "需先正常退出：\(names)；仍在运行时相关项目会跳过",
                "Quit first: \(names); related items are skipped while running"
            )
        case .recovery:
            return recovery.map(\.text).joined(separator: L10n.text("；", "; "))
        case .permission:
            return permission.text
        }
    }

    private func isWarning(_ field: Field) -> Bool {
        switch field {
        case .action: actions.contains(.permanentDeletion)
        case .objects: notRunCount > 0 || !objectWarnings.isEmpty
        case .capacity: bytesAreLowerBound || physicalReleaseUnknown
        case .appsToQuit: !appsToQuit.isEmpty
        case .recovery: recovery.contains(.notRecoverable)
        case .permission: permission.isLimited
        }
    }

    /// D84 口径：本地占用；移到废纸篓的部分写明“清空废纸篓后才释放”。
    /// 名称最多列 3 个，其余写“等 N 个”，避免确认页被长名单撑高（D77）。
    static func abbreviatedList(_ names: [String], limit: Int = 3) -> String {
        guard names.count > limit else { return names.joined(separator: L10n.text("、", ", ")) }
        let shown = names.prefix(limit).joined(separator: L10n.text("、", ", "))
        let rest = names.count - limit
        return L10n.text("\(shown) 等 \(ByteFormat.count(names.count)) 个", "\(shown) and \(ByteFormat.count(rest)) more")
    }

    var capacityText: String {
        guard let localBytes else {
            return L10n.text("不涉及磁盘空间（只删除记录，不释放本地占用）", "No disk space involved (records only; no local space is freed)")
        }
        let format: (Int64) -> String = { ByteFormat.storageString($0) }
        // “至少”只用于大小未知或只量到下限（真正的下限）。
        let lowerBound = bytesAreLowerBound ? L10n.text("至少 ", "at least ") : ""
        // 有不会执行的项目时写明口径：只算将执行的项目，与表头同一组数字。
        let scope = notRunCount > 0 && recordCount == nil
            ? L10n.text("（将执行的 \(ByteFormat.count(readyCount)) 项）", " (the \(ByteFormat.count(readyCount)) that will run)") : ""
        var parts = [L10n.text(
            "本地占用\(scope) \(lowerBound)\(format(localBytes))",
            "Local usage\(scope) \(lowerBound)\(format(localBytes))"
        )]
        if trashBytes > 0 {
            if physicalReleaseUnknown {
                // P1-2：APFS 克隆或硬链接，清空废纸篓后最多释放这么多，可能一点也不释放。
                parts.append(L10n.text(
                    "其中 \(format(trashBytes)) 移到废纸篓；清空废纸篓后最多释放 \(format(trashBytes))，可回收量待确认（APFS 克隆或硬链接可能不释放空间）",
                    "\(format(trashBytes)) goes to the Trash; emptying it frees at most \(format(trashBytes)), actual amount unconfirmed (APFS clones or hard links may free nothing)"
                ))
            } else if let trashReclaimable {
                // D104 G1：与扫描结果表头同一口径。
                let possible = trashReclaimable.possibleCloneBytes > 0
                    ? L10n.text("，所选完整克隆另可能释放 \(format(trashReclaimable.possibleCloneBytes))",
                                ", plus up to \(format(trashReclaimable.possibleCloneBytes)) from clones selected together")
                    : ""
                let folders = trashReclaimable.countsFoldersWhole
                    ? L10n.text("；文件夹按完整大小计", "; folders count at full size") : ""
                parts.append(L10n.text(
                    "其中 \(format(trashBytes)) 移到废纸篓；清空废纸篓后预计释放 \(format(trashReclaimable.bytes))\(possible)；与 APFS 克隆共享或被本地快照占用的部分不释放\(folders)",
                    "\(format(trashBytes)) goes to the Trash; emptying it frees about \(format(trashReclaimable.bytes))\(possible); blocks shared with APFS clones or held by a local snapshot stay\(folders)"
                ))
            } else {
                parts.append(L10n.text(
                    "其中 \(format(trashBytes)) 移到废纸篓，清空废纸篓后才释放",
                    "\(format(trashBytes)) goes to the Trash, freed only after emptying it"
                ))
            }
        }
        if quarantineBytes > 0 {
            parts.append(L10n.text(
                "其中 \(format(quarantineBytes)) 移入隔离区，不释放空间",
                "\(format(quarantineBytes)) moves to Quarantine and frees no space"
            ))
        }
        if permanentDeletionBytes > 0 {
            parts.append(L10n.text(
                "其中 \(format(permanentDeletionBytes)) 永久删除，删除后回读确认才计为已释放",
                "\(format(permanentDeletionBytes)) is deleted permanently, counted as freed only after read-back"
            ))
        }
        return parts.joined(separator: L10n.text("；", "; "))
    }

    /// D104 G1：清空废纸篓后预计释放的量。
    struct TrashReclaimable: Equatable, Sendable {
        let bytes: Int64
        /// 所选项目包含同一组的全部完整克隆时，可能另外释放的一份；0 表示不提。
        var possibleCloneBytes: Int64 = 0
        /// 将移走的项目里有文件夹：其内容没有读取共享情况，按完整大小计。
        var countsFoldersWhole = false
    }

    /// 只能用纯文本的确认框（例如系统确认对话框）使用的同一组字段。
    var plainText: String {
        rows.map { "\($0.field.title)\(L10n.text("：", ": "))\($0.value)" }
            .joined(separator: "\n")
    }
}

// MARK: - 完成页

/// 完成页四组。
enum OperationCompletionBucket: String, CaseIterable, Sendable {
    case completed, skipped, failed, needsVerification

    var title: String {
        switch self {
        case .completed: L10n.text("完成", "Completed")
        case .skipped: L10n.text("跳过", "Skipped")
        case .failed: L10n.text("失败", "Failed")
        case .needsVerification: L10n.text("待核实", "Needs Verification")
        }
    }

    var systemImage: String {
        switch self {
        case .completed: "checkmark.circle"
        case .skipped: "minus.circle"
        case .failed: "xmark.octagon"
        case .needsVerification: "questionmark.circle"
        }
    }
}

struct OperationCompletionEntry: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let path: String?
    let bucket: OperationCompletionBucket
    /// 逐项原因或结果（跳过、失败、待核实时必有）。
    let detail: String
    /// 一行代表的数量（浏览记录一行可能是多条访问）。
    var count: Int = 1
}

/// 完成页的统一统计。容量只分三种：已移到废纸篓（未释放）、
/// 已移入隔离区（未释放）、永久删除并回读确认（实际释放）。
struct OperationCompletionTally: Equatable, Sendable {
    var entries: [OperationCompletionEntry]
    var movedToTrashBytes: Int64 = 0
    var movedToQuarantineBytes: Int64 = 0
    /// 只来自永久删除且删除后回读确认已不存在的项目。
    var releasedBytes: Int64 = 0
    /// false：动作与磁盘空间无关（浏览记录）。
    var affectsDiskSpace = true
    /// 回执未完整保存：所有结论都要以“操作记录”核对为准。
    var receiptIncomplete = false
    /// 已移到废纸篓的部分含 APFS 克隆或硬链接：清空废纸篓后最多释放这么多（P1-2）。
    var reclaimableUnknown = false
    /// 已移动但新位置身份待核实、或恢复结果未确认的体积；不计入“已移到废纸篓”，单列一行，
    /// 让它与“原操作移走体积”对得上（P2-1）。
    var unverifiedMovedBytes: Int64 = 0
    /// 已恢复到原位置的体积；不再计入“已移到废纸篓”。
    var restoredBytes: Int64 = 0

    func count(_ bucket: OperationCompletionBucket) -> Int {
        entries.filter { $0.bucket == bucket }.reduce(0) { $0 + $1.count }
    }

    func entries(in bucket: OperationCompletionBucket) -> [OperationCompletionEntry] {
        entries.filter { $0.bucket == bucket }
    }

    /// “完成 a · 跳过 b · 失败 c · 待核实 d”，四组都写，0 也写。
    var headline: String {
        OperationCompletionBucket.allCases
            .map { "\($0.title) \(count($0))" }
            .joined(separator: " · ")
    }

    /// 容量口径。不会把移到废纸篓写成“已释放”。
    var capacityLines: [String] {
        guard affectsDiskSpace else { return spaceLines }
        return spaceLines + (receiptIncomplete ? [Self.receiptIncompleteLine] : [])
    }

    static var receiptIncompleteLine: String {
        L10n.text("回执未完整保存，请以“操作记录”为准", "The receipt was not fully saved; check Operation History")
    }

    /// 只有容量，不含回执提示；页面自己已经提示回执不完整时用它（P2-7）。
    var spaceLines: [String] {
        guard affectsDiskSpace else {
            return [L10n.text("删除浏览记录不涉及释放磁盘空间", "Deleting browsing history does not free disk space")]
        }
        let format: (Int64) -> String = { ByteFormat.storageString($0) }
        var lines: [String] = []
        if movedToTrashBytes > 0 {
            if reclaimableUnknown {
                lines.append(L10n.text(
                    "已移到废纸篓 \(format(movedToTrashBytes))（未释放；清空废纸篓后最多释放 \(format(movedToTrashBytes))，可回收量待确认）",
                    "Moved to the Trash: \(format(movedToTrashBytes)) (not freed; emptying the Trash frees at most \(format(movedToTrashBytes)), actual amount unconfirmed)"
                ))
            } else {
                lines.append(L10n.text(
                    "已移到废纸篓 \(format(movedToTrashBytes))（未释放，清空废纸篓后才释放）",
                    "Moved to the Trash: \(format(movedToTrashBytes)) (not freed until the Trash is emptied)"
                ))
            }
        }
        if movedToQuarantineBytes > 0 {
            lines.append(L10n.text(
                "已移入隔离区 \(format(movedToQuarantineBytes))（未释放）",
                "Moved to Quarantine: \(format(movedToQuarantineBytes)) (not freed)"
            ))
        }
        if unverifiedMovedBytes > 0 {
            lines.append(L10n.text(
                "另有 \(format(unverifiedMovedBytes)) 已移动但结果待核实，未计入上面",
                "Another \(format(unverifiedMovedBytes)) was moved but needs verification; not counted above"
            ))
        }
        if restoredBytes > 0 {
            lines.append(L10n.text(
                "已恢复到原位置 \(format(restoredBytes))，不再计入",
                "Restored to the original location: \(format(restoredBytes)); no longer counted"
            ))
        }
        if releasedBytes > 0 {
            lines.append(L10n.text(
                "实际释放 \(format(releasedBytes))（永久删除并回读确认）",
                "Actually freed: \(format(releasedBytes)) (permanently deleted, confirmed by read-back)"
            ))
        }
        if movedToTrashBytes == 0, movedToQuarantineBytes == 0, releasedBytes == 0 {
            lines.append(L10n.text("本次没有释放磁盘空间", "No disk space was freed this time"))
        }
        return lines
    }

    init(entries: [OperationCompletionEntry], movedToTrashBytes: Int64 = 0, movedToQuarantineBytes: Int64 = 0,
         releasedBytes: Int64 = 0, affectsDiskSpace: Bool = true, receiptIncomplete: Bool = false) {
        self.entries = entries
        self.movedToTrashBytes = movedToTrashBytes
        self.movedToQuarantineBytes = movedToQuarantineBytes
        self.releasedBytes = releasedBytes
        self.affectsDiskSpace = affectsDiskSpace
        self.receiptIncomplete = receiptIncomplete
    }

    /// 清理、开发工具、智能扫描、重复文件与卸载共用的回执。
    /// 恢复过的项目不再计入“已移到废纸篓”；恢复结果未确认的归入待核实（P2-2）。
    /// `classifyFailure` 让卸载页把“应用正在运行”的拒绝写成跳过（P2-3）。
    init(report: CleanReport, title: ((CleanReportItem) -> String)? = nil,
         classifyFailure: ((CleanReportItem, CleanFailure) -> (OperationCompletionBucket, String)?)? = nil) {
        let attempts = report.recoveryAttempts ?? []
        let restoredPaths = Set(attempts.flatMap(\.items)
            .filter { $0.outcome == .restored }.map(\.originalPath))
        // 与 OperationResultPresentation 同口径：恢复结果未知、或恢复回执未保存的尝试。
        let unconfirmedRecoveryPaths = Set(attempts.flatMap { attempt in
            attempt.items.filter { $0.outcome == .outcomeUnknown || attempt.persistenceFailure != nil }
        }.map(\.originalPath)).subtracting(restoredPaths)
        let recoveryReceiptIncomplete = attempts.contains { $0.persistenceFailure != nil }
        var entries: [OperationCompletionEntry] = []
        var trash: Int64 = 0, quarantine: Int64 = 0, released: Int64 = 0
        var unverified: Int64 = 0, restored: Int64 = 0
        for item in report.items {
            let name = title?(item) ?? URL(fileURLWithPath: item.sourcePath).lastPathComponent
            func entry(_ bucket: OperationCompletionBucket, _ detail: String) {
                entries.append(.init(id: item.id.uuidString, title: name, path: item.sourcePath,
                                     bucket: bucket, detail: detail))
            }
            switch item.outcome {
            case .moved(let receipt):
                if restoredPaths.contains(item.sourcePath) {
                    restored += max(0, item.estimatedBytes)
                    entry(.completed, L10n.text("已移走，之后已恢复到原位置", "Moved, then restored to the original location"))
                } else if unconfirmedRecoveryPaths.contains(item.sourcePath) {
                    unverified += max(0, item.estimatedBytes)
                    entry(.needsVerification, L10n.text("恢复结果未确认，请在“操作记录”中核对，勿重复操作",
                                                        "The restore is unconfirmed; check Operation History and do not repeat it"))
                } else if !receipt.isRestorable {
                    unverified += max(0, item.estimatedBytes)
                    entry(.needsVerification, L10n.text("已移动，但新位置身份待核实，不提供自动恢复",
                                                        "Moved, but the new location's identity is unverified; no automatic restore"))
                } else if receipt.disposition == .quarantine {
                    quarantine += max(0, item.estimatedBytes)
                    entry(.completed, L10n.text("已移入隔离区（未释放）", "Moved to Quarantine (not freed)"))
                } else {
                    trash += max(0, item.estimatedBytes)
                    entry(.completed, L10n.text("已移到废纸篓（未释放）", "Moved to the Trash (not freed)"))
                }
            case .deleted:
                released += max(0, item.estimatedBytes)
                entry(.completed, L10n.text("已永久删除，回读确认已不存在", "Permanently deleted; read-back confirms it is gone"))
            case .skipped(let reason):
                entry(.skipped, CleanSkipReasonPresentation.title(reason))
            case .notProcessed:
                entry(.skipped, L10n.text("未执行，原文件保留", "Not run; the original is kept"))
            case .failed(let failure):
                if let custom = classifyFailure?(item, failure) {
                    entry(custom.0, custom.1)
                    break
                }
                let unknown = failure.code == .moveOutcomeUnknown || failure.code == .deletionOutcomeUnknown
                entry(unknown ? .needsVerification : .failed, CleanFailurePresentation.title(failure))
            }
        }
        self.init(entries: entries, movedToTrashBytes: trash, movedToQuarantineBytes: quarantine,
                  releasedBytes: released, receiptIncomplete: report.persistenceFailure != nil || recoveryReceiptIncomplete)
        unverifiedMovedBytes = unverified
        restoredBytes = restored
        // P1-2：沿用执行器的口径，移到废纸篓却没有“清空后可回收”数字（含已核实的重复文件／APFS 克隆）时，
        // 清空废纸篓后最多释放这么多，可回收量待确认。
        reclaimableUnknown = trash > 0 && report.disposition == .trash
            && report.summary.reclaimableAfterEmptyingTrashBytes == nil
    }

    /// 卸载（含残留）：应用仍在运行时被拒绝的项目写成“跳过（应用正在运行）”，
    /// 与确认页“仍在运行时相关项目会跳过”一致；其余拒绝用卸载自己的原因（P2-3）。
    init(uninstall report: CleanReport, app: InstalledAppItem, appIsRunning: Bool) {
        self.init(report: report, title: {
            $0.sourcePath == app.path ? app.name : UninstallPresentation.category($0.sourcePath)
        }, classifyFailure: { _, failure in
            guard let reason = UninstallFailureReason(failure) else { return nil }
            if reason == .changedSinceScan, appIsRunning {
                return (.skipped, L10n.text("跳过（应用正在运行）", "Skipped (the app is running)"))
            }
            return UninstallPresentation.recordLabel(reason).map { (.failed, $0) }
        })
    }

    /// 文件分析移到废纸篓：回执里的结果加上审阅后未移动的项目。
    init(fileAnalysis outcome: FileAnalysisTrashOutcome) {
        var tally: OperationCompletionTally
        if let report = outcome.report {
            tally = OperationCompletionTally(report: report)
        } else {
            tally = OperationCompletionTally(entries: outcome.movedPaths.map {
                OperationCompletionEntry(id: $0, title: URL(fileURLWithPath: $0).lastPathComponent, path: $0,
                    bucket: .completed, detail: L10n.text("已移到废纸篓（未释放）", "Moved to the Trash (not freed)"))
            }, movedToTrashBytes: max(0, outcome.movedBytes))
        }
        // P1-2：移走的文件另有硬链接时，清空废纸篓后不一定释放。
        if !outcome.otherHardLinkPaths.isDisjoint(with: outcome.movedPaths) {
            tally.reclaimableUnknown = tally.movedToTrashBytes > 0
        }
        let known = Set(tally.entries.compactMap(\.path))
        for skipped in outcome.skipped where !known.contains(skipped.path) {
            tally.entries.append(.init(id: skipped.path, title: skipped.title, path: skipped.path,
                                       bucket: .skipped, detail: skipped.reason))
        }
        tally.receiptIncomplete = tally.receiptIncomplete || outcome.receiptIncomplete
        self = tally
    }

    /// 浏览记录：删除后回读确认的才算完成；结果不确定的为待核实；
    /// 只能在浏览器内处理的为跳过（逐项给出原因）。
    init(browser report: BrowserPrivacyProcessingReport) {
        let entries = report.entries.map { entry -> OperationCompletionEntry in
            let bucket: OperationCompletionBucket
            let fallback: String
            switch entry.outcome {
            case .deleted:
                bucket = .completed
                fallback = L10n.text("已删除，回读确认", "Deleted; confirmed by read-back")
            case .failed:
                bucket = .failed
                fallback = L10n.text("删除失败，未修改", "Deletion failed; nothing changed")
            case .indeterminate:
                bucket = .needsVerification
                fallback = L10n.text("结果无法确认，请重新扫描核对", "The result could not be confirmed; scan again to check")
            case .manual, .unsupported:
                bucket = .skipped
                fallback = L10n.text("需在浏览器内处理", "Must be handled in the browser")
            }
            let count = entry.outcome == .deleted ? entry.verifiedDeletedRecordIDs.count : entry.recordCount
            return OperationCompletionEntry(
                id: entry.id,
                title: "\(entry.browser.displayName) · \(entry.resolvedProfileDisplayName)",
                path: nil, bucket: bucket,
                detail: entry.detail.isEmpty ? fallback : entry.detail,
                count: count
            )
        }
        self.init(entries: entries, affectsDiskSpace: false)
    }
}

// MARK: - 结果行三段说明（D82 规则来源）

/// 安全清理、开发工具与智能扫描结果行的三段说明：属于什么应用、
/// 处理后影响、为什么预选（或为什么不预选）。数据来自 D82 规则来源；
/// 缺失时用保守文案，不留空白。
enum CleanupPreselectionReason: String, CaseIterable, Sendable {
    case ownerRunning, freesLittle, preselected, permanentDeletion, protected, reviewRequired, notReady

    var title: String {
        switch self {
        case .ownerRunning:
            L10n.text("所属应用正在运行，本次不预选", "Not preselected: its app is running")
        case .freesLittle:
            L10n.text("清空废纸篓后预计释放不到 1 MB 或不到列出大小的十分之一，本次不预选",
                      "Not preselected: emptying the Trash is expected to free under 1 MB or under a tenth of its size")
        case .preselected:
            L10n.text("绿色项目符合本次安全策略，按默认规则预选；执行前仍会复查", "Preselected: a green item that meets the safety policy; rechecked before cleanup")
        case .permanentDeletion:
            L10n.text("永久删除需要单独确认，不预选", "Not preselected: permanent deletion needs its own confirmation")
        case .protected:
            L10n.text("最近仍在使用或风险较高，需要两次确认，不预选", "Not preselected: recently used or higher risk; needs two confirmations")
        case .reviewRequired:
            L10n.text("需要判断是否仍有用途，不预选", "Not preselected: check whether it is still needed")
        case .notReady:
            L10n.text("测量或执行条件尚不满足，不预选", "Not preselected: measurement or run conditions are not met")
        }
    }
}

struct CleanupRuleExplanation: Equatable, Sendable {
    let ownership: String
    let impact: String
    let preselection: String
    /// 规则没有登记处理影响，用了保守文案。
    let usesImpactFallback: Bool

    init(candidate: ScanCandidate) {
        ownership = Self.ownership(candidate)
        let recorded = candidate.cleanupImpactText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        // 规则库登记的是中文影响说明；英文界面用 `CleanupImpactText.english` 的对应译文，
        // 没有译文时才用英文通用说明，英文界面不出现中文（P2-4）。
        if !recorded.isEmpty, L10n.usesChinese {
            impact = recorded
            usesImpactFallback = false
        } else if !recorded.isEmpty, let english = CleanupImpactText.english(for: recorded) {
            impact = english
            usesImpactFallback = false
        } else {
            impact = Self.fallbackImpact(candidate, hasRecordedImpact: !recorded.isEmpty)
            usesImpactFallback = true
        }
        preselection = candidate.preselectionReason.title
    }

    var lines: [(title: String, value: String)] {
        [
            (L10n.text("属于", "Belongs to"), ownership),
            (L10n.text("处理后影响", "After cleanup"), impact),
            (L10n.text("预选", "Preselection"), preselection),
        ]
    }

    /// 单行文本（行悬停与辅助功能）。
    var summary: String {
        lines.map { "\($0.title)\(L10n.text("：", ": "))\($0.value)" }.joined(separator: " · ")
    }

    private static func ownership(_ candidate: ScanCandidate) -> String {
        if let tool = candidate.developerTool { return tool.displayName }
        if let name = candidate.ruleOwnerDisplayName, !name.isEmpty { return name }
        if !candidate.ownerBundleIdentifiers.isEmpty {
            return candidate.ownerBundleIdentifiers.joined(separator: L10n.text("、", ", "))
        }
        return candidate.ownerResolution == .unresolved
            ? L10n.text("未识别所属应用", "Owning app not identified")
            : L10n.text("系统或命令行工具", "System or command-line tool")
    }

    private static func fallbackImpact(_ candidate: ScanCandidate, hasRecordedImpact: Bool) -> String {
        if candidate.action.permanentlyDeletes {
            return L10n.text("永久删除，无法从废纸篓或“操作记录”恢复", "Deleted permanently; cannot be restored from the Trash or Operation History")
        }
        if hasRecordedImpact {
            // 只在英文界面、且该条中文说明还没有译文时出现：不说“未登记”。
            return L10n.text(
                "只会移到废纸篓，可从废纸篓或“操作记录”恢复；不确定用途时请不要勾选",
                "It only moves to the Trash and can be restored from the Trash or Operation History; leave it unchecked if unsure"
            )
        }
        return L10n.text(
            "未登记具体影响：只会移到废纸篓，可从废纸篓或“操作记录”恢复；不确定用途时请不要勾选",
            "No specific impact recorded: it only moves to the Trash and can be restored from the Trash or Operation History; leave it unchecked if unsure"
        )
    }

    /// lightfield 单行结果的详情：D47 重建代价提示放最前（中间截断时保住开头），
    /// 其后是 D100 G1 预计释放提示、所属状态、“属于 X”，最后是路径（P2-6）。
    static func lightfieldDetail(rebuildCost: String?, reclaimable: String? = nil, ownerStatus: String?,
                                 ownership: String, path: String) -> String {
        let parts: [String?] = [rebuildCost, reclaimable, ownerStatus, L10n.text("属于 ", "Belongs to ") + ownership, path]
        return parts.compactMap { $0 }.joined(separator: " · ")
    }
}

/// D82 规则来源登记的处理影响说明的英文译文（P2-4）。规则库只登记中文；
/// 每条中文说明在这里有一条英文，测试核对所有已加载规则都有译文。
enum CleanupImpactText {
    static let englishByChinese: [String: String] = [
        "应用会恢复默认设置并按需重新生成设置文件":
            "The app returns to its default settings and creates a new settings file as needed",
        "应用或工具会重新生成缓存，首次使用可能稍慢或需要联网":
            "The app or tool rebuilds its cache; first use may be slower or need the internet",
        "应用会重新生成缓存，首次打开可能稍慢或需要联网":
            "The app rebuilds its cache; it may open more slowly or need the internet the first time",
        "工具会重新生成缓存，首次使用可能稍慢或需要联网":
            "The tool rebuilds its cache; first use may be slower or need the internet",
        "系统会重新生成缓存，首次同步可能稍慢":
            "macOS rebuilds the cache; the first sync may be slower",
        "应用会重新生成日志，旧诊断记录将移入废纸篓":
            "The app writes new logs; old diagnostic records move to the Trash",
        "工具会重新生成日志，旧诊断记录将移入废纸篓":
            "The tool writes new logs; old diagnostic records move to the Trash",
        "Xcode 会重新构建派生文件，下次编译可能较慢":
            "Xcode rebuilds derived data; the next build may be slower",
        "Bun 下次安装时会重新下载；启用全局存储（globalStore）的项目需要重新运行 bun install":
            "Bun downloads the packages again on the next install; projects that use its global store (globalStore) need bun install again",
        "iStat Menus 的历史图表会清空，之后重新开始记录":
            "iStat Menus history charts start empty and recording begins again",
        "重复应用副本将移入废纸篓，保留的同版本副本不受影响":
            "The duplicate app copy moves to the Trash; the kept copy of the same version is not affected",
        "已打开附件的下载副本将移入废纸篓，邮件原件不受影响":
            "Downloaded copies of opened attachments move to the Trash; the original emails are not affected",
        "附件将移入废纸篓，可放回。IMAP 等服务器邮件打开时会重新下载附件；仅存本机的邮件（如 POP 或“我的 Mac 上”邮箱）需从废纸篓放回附件后才能再查看":
            "Attachments move to the Trash and can be put back. Mail downloads them again when you open messages on a server, such as IMAP. For messages stored only on this Mac, including POP or On My Mac mailboxes, put the attachments back from the Trash to view them again",
        "将永久删除扫描时已有的废纸篓项目，无法通过本应用恢复":
            "Items already in the Trash at scan time are deleted permanently and cannot be restored with this app",
        "会从你所有设备上的 iCloud 云盘永久删除，不能撤销":
            "Permanently deletes from iCloud Drive on all your devices; this cannot be undone",
        "将永久删除扫描时外接硬盘废纸篓里已有的项目，无法通过本应用恢复":
            "Items already in another drive's Trash at scan time are deleted permanently and cannot be restored with this app",
    ]

    static func english(for chinese: String) -> String? {
        englishByChinese[chinese.trimmingCharacters(in: .whitespacesAndNewlines)]
    }
}

extension ScanCandidate {
    /// D93：预选原因的唯一来源；`preselectionExplanationText`（D82）是它的中文记录。
    var preselectionReason: CleanupPreselectionReason {
        if isOwnerRunning { return .ownerRunning }
        if isPreselectedByDefault { return .preselected }
        if freesTooLittleToPreselect, selectionEligibility == .selectable, defaultSelection != .forbidden {
            return .freesLittle
        }
        if action == .emptyTrash { return .permanentDeletion }
        if risk == .protected { return .protected }
        if risk == .reviewOnly { return .reviewRequired }
        return .notReady
    }

    var ruleExplanation: CleanupRuleExplanation { CleanupRuleExplanation(candidate: self) }
}

// MARK: - 勾选时提示需退出的应用

enum OperationQuitNotice {
    /// 已勾选、所属应用正在运行的行：在勾选时就说明执行前需退出，
    /// 不等到执行时才跳过。没有这类行时返回 nil。
    static func text(forSelected candidates: [ScanCandidate]) -> String? {
        let names = appNames(forSelected: candidates)
        guard !names.isEmpty else { return nil }
        let running = candidates.filter(\.isOwnerRunning).count
        return L10n.text(
            "已勾选的 \(ByteFormat.count(running)) 项属于正在运行的 \(names.joined(separator: "、"))：清理前需正常退出，否则这些项目会被跳过",
            "\(L10n.items(running)) you checked belong to running \(names.joined(separator: ", ")): quit normally before cleanup, or these items are skipped"
        )
    }

    static func appNames(forSelected candidates: [ScanCandidate]) -> [String] {
        var seen = Set<String>()
        return candidates.filter(\.isOwnerRunning)
            .map { CleanupRuleExplanation(candidate: $0).ownership }
            .filter { seen.insert($0).inserted }
    }

    /// 冻结计划里因应用仍在运行而跳过的项目对应的应用名（可退出与需手动退出）。
    static func appNames(_ options: CleanupOwnerQuitService.Options) -> [String] {
        var seen = Set<String>()
        return (options.quittable + options.manual).map(\.displayName).filter { seen.insert($0).inserted }
    }

    /// 浏览记录：只有可直接删除（有定位信息）的所选记录才需要退出所在浏览器；
    /// 只能在浏览器内处理的记录不写入，不需要退出（P2-5）。
    static func runningBrowserNames(selected records: [BrowserPrivacyRecord], runningBrowserIDs: Set<String>) -> [String] {
        var seen = Set<String>()
        return records.filter { $0.locator != nil && runningBrowserIDs.contains($0.browser.id) }
            .map(\.browser.displayName).filter { seen.insert($0).inserted }
    }

    /// 浏览记录：所选记录所在的浏览器正在运行。
    static func text(runningBrowsers names: [String]) -> String? {
        guard !names.isEmpty else { return nil }
        return L10n.text(
            "所选记录所在的 \(names.joined(separator: "、")) 正在运行：删除前需正常退出，或在确认时跳过这些浏览器",
            "\(names.joined(separator: ", ")) holding the selected records is running: quit it normally before deletion, or skip it when confirming"
        )
    }
}

// MARK: - 各页的确认字段

extension OperationConfirmationFacts {
    /// 安全清理、开发工具与产物、智能扫描结果、重复文件：同一份冻结计划。
    /// 只统计通过执行前检查的项目；其余计入“不会执行”并在清单里写原因。
    static func cleanupPlan(
        _ plan: CleanPlan,
        preflight: CleanPreflightReport?,
        surface: OperationSurface,
        appsToQuit: [String],
        permission: OperationPermissionCoverage
    ) -> OperationConfirmationFacts {
        var skipped: [UUID: CleanSkipReason] = [:]
        if let preflight, preflight.planID == plan.id {
            for item in preflight.items {
                if case .skipped(let reason) = item.status { skipped[item.planItemID] = reason }
            }
        }
        return cleanupPlanItems(
            plan.items,
            disposition: plan.disposition,
            skipped: skipped,
            surface: surface,
            appsToQuit: appsToQuit,
            permission: permission
        )
    }

    /// 冻结计划的项目与执行前检查跳过原因（按计划项 ID）；供计划确认表与测试共用。
    static func cleanupPlanItems(
        _ planItems: [CleanPlanItem],
        disposition: CleanupDisposition,
        skipped: [UUID: CleanSkipReason],
        surface: OperationSurface,
        appsToQuit: [String],
        permission: OperationPermissionCoverage
    ) -> OperationConfirmationFacts {
        // P2-11：按 Set 过滤，大型计划（几千项、几百项跳过）保持 O(n)。
        let planIDs = Set(planItems.map(\.id))
        let skipped = skipped.filter { id, _ in planIDs.contains(id) }
        let ready = planItems.filter { skipped[$0.id] == nil }
        let deletions = ready.filter { $0.action.permanentlyDeletes }
        let moves = ready.filter { !$0.action.permanentlyDeletes }
        let moveBytes = moves.reduce(Int64(0)) { $0 + max(0, $1.estimatedSizeBytes) }
        let deleteBytes = deletions.reduce(Int64(0)) { $0 + max(0, $1.estimatedSizeBytes) }
        var actions: [OperationActionKind] = []
        var recovery: [OperationRecoveryMethod] = []
        if !moves.isEmpty {
            actions.append(disposition == .quarantine ? .moveToQuarantine : .moveToTrash)
            recovery.append(disposition == .quarantine ? .quarantine : .trashAndOperationHistory)
        }
        if !deletions.isEmpty {
            actions.append(.permanentDeletion)
            recovery.append(.notRecoverable)
        }
        if recovery.isEmpty { recovery = [.noChange] }
        let items = planItems.map { item in
            OperationConfirmationItem(
                id: item.id.uuidString,
                title: item.sourceURL.lastPathComponent,
                path: item.sourceURL.path,
                bytes: item.estimatedSizeBytes,
                detail: skipped[item.id].map {
                    L10n.text("不会执行：", "Will not run: ") + CleanSkipReasonPresentation.title($0)
                } ?? (item.action.permanentlyDeletes
                    ? OperationActionKind.permanentDeletion.title : nil)
            )
        }
        return OperationConfirmationFacts(
            surface: surface,
            actions: actions,
            items: items,
            notRunCount: skipped.count,
            localBytes: moveBytes + deleteBytes,
            bytesAreLowerBound: ready.contains { !$0.measurementCompleteness.isComplete },
            physicalReleaseUnknown: disposition == .trash && moves.contains { $0.verifiedDuplicateEvidence != nil },
            trashBytes: disposition == .trash ? moveBytes : 0,
            quarantineBytes: disposition == .quarantine ? moveBytes : 0,
            permanentDeletionBytes: deleteBytes,
            appsToQuit: appsToQuit,
            recovery: recovery,
            permission: permission
        )
    }

    /// P2-12：计划确认表标题，与表头“项目”和“对象”字段同一口径——全部计划项，
    /// 有不会执行的项目时写明将执行几项。
    func cleanupPlanTitle(planHasMoves: Bool, planHasPermanentDeletion: Bool) -> String {
        let zhScope = notRunCount > 0 ? "（将执行 \(ByteFormat.count(readyCount)) 项）" : ""
        let enScope = notRunCount > 0 ? " (\(ByteFormat.count(readyCount)) will run)" : ""
        if !planHasPermanentDeletion {
            return L10n.text("清理 \(ByteFormat.count(itemCount)) 个项目\(zhScope)？", "Clean \(ByteFormat.count(itemCount)) Item(s)\(enScope)?")
        }
        if !planHasMoves {
            return L10n.text("清空废纸篓：\(ByteFormat.count(itemCount)) 个项目\(zhScope)？", "Empty Trash: \(ByteFormat.count(itemCount)) Item(s)\(enScope)?")
        }
        return L10n.text(
            "清理 \(ByteFormat.count(itemCount)) 个项目并清空废纸篓\(zhScope)？",
            "Clean \(ByteFormat.count(itemCount)) Item(s) and Empty Trash\(enScope)?"
        )
    }

    /// P2-12：移到废纸篓的释放提示。计划里没有移入项时为 nil；移入项全部不会执行时
    /// 写明本次不会移动任何项目，不再显示“最多可释放 0 B”。
    func cleanupTrashReleaseNote(planHasTrashMoves: Bool) -> String? {
        guard planHasTrashMoves else { return nil }
        guard actions.contains(.moveToTrash) else {
            return L10n.text(
                "移到废纸篓的项目都不会执行，本次不会移动任何项目。",
                "None of the items to move to the Trash will run; nothing will be moved this time."
            )
        }
        let format: (Int64) -> String = { ByteFormat.storageString($0) }
        return L10n.text(
            "清空废纸篓后最多可释放 \(format(trashBytes))；当前立即释放取决于废纸篓和文件系统状态。",
            "Up to \(format(trashBytes)) may be released after Trash is emptied; immediate release depends on Trash and file-system state."
        )
    }

    /// 卸载（含残留）：应用本体与勾选的关联文件一起移到废纸篓。
    static func uninstall(
        app: InstalledAppItem,
        selected: [InstalledAppRelatedItem],
        residual: Bool,
        runningAppNames: [String],
        permission: OperationPermissionCoverage
    ) -> OperationConfirmationFacts {
        var items: [OperationConfirmationItem] = []
        if !residual {
            items.append(.init(id: app.path, title: app.name, path: app.path, bytes: app.sizeBytes,
                               detail: L10n.text("应用本体", "Application")))
        }
        items += selected.map {
            OperationConfirmationItem(id: $0.path, title: UninstallPresentation.category($0.path), path: $0.path,
                                      bytes: $0.sizeIsKnown ? $0.sizeBytes : nil,
                                      detail: L10n.text("属于 \(app.name)", "Belongs to \(app.name)")
                                          + (UninstallVendorRules.highValueData(path: $0.path).map { " · " + $0.title } ?? ""))
        }
        let known = items.compactMap(\.bytes).reduce(Int64(0)) { $0 + max(0, $1) }
        // P2-10（D87）：勾选了含个人资料／含镜像与数据卷的项目时在“对象”字段警示。
        var warnings: [String] = []
        for kind in UninstallVendorRules.HighValueData.allCases {
            let count = selected.filter { UninstallVendorRules.highValueData(path: $0.path) == kind }.count
            guard count > 0 else { continue }
            warnings.append(L10n.text(
                "其中 \(ByteFormat.count(count)) 项\(kind.title)，会一并移到废纸篓，请先确认已备份",
                "includes \(L10n.items(count)) marked “\(kind.title)” that also move to the Trash; back them up first"
            ))
        }
        return OperationConfirmationFacts(
            surface: .uninstall,
            actions: residual ? [.moveToTrash] : (selected.isEmpty ? [.uninstall] : [.uninstall, .moveToTrash]),
            items: items,
            localBytes: known,
            bytesAreLowerBound: items.contains { $0.bytes == nil },
            trashBytes: known,
            appsToQuit: runningAppNames,
            recovery: [.trashAndOperationHistory],
            permission: permission,
            objectWarnings: warnings
        )
    }

    /// 文件分析移到废纸篓：审阅清单里可以移的项目；其余计入“不会执行”。
    static func fileAnalysis(
        _ review: FileAnalysisTrashReview,
        permission: OperationPermissionCoverage
    ) -> OperationConfirmationFacts {
        let items = review.items.map { item -> OperationConfirmationItem in
            var detail: String? = nil
            if case .blocked(let block) = item.status {
                detail = L10n.text("不会执行：", "Will not run: ")
                    + block.explanation(naming: review.unknownRunningApplicationNames)
            } else if item.hasOtherHardLinks {
                detail = FileAnalysisTrashPresentation.otherHardLinksNote
            } else {
                detail = FileAnalysisTrashPresentation.reclaimableNote(item)
            }
            return OperationConfirmationItem(id: item.id, title: item.selection.title, path: item.selection.path,
                                             bytes: item.selection.bytes, detail: detail)
        }
        var recovery: [OperationRecoveryMethod] = [.trashAndOperationHistory]
        if !review.externalVolumeNames.isEmpty { recovery.append(.otherVolumeTrash) }
        let runningBlocked = review.items.contains {
            if case .blocked(.containsRunningApplication) = $0.status { return true }
            return false
        }
        var apps = review.unknownRunningApplicationNames
        if runningBlocked, apps.isEmpty {
            apps = [L10n.text("所选文件夹里正在运行的应用", "the running apps inside the selected folders")]
        }
        return OperationConfirmationFacts(
            surface: .fileAnalysis,
            actions: review.readyItems.isEmpty ? [] : [.moveToTrash],
            items: items,
            notRunCount: review.blockedCount,
            localBytes: review.readyBytes,
            // P1-2：硬链接时 X 是上限，不是“至少”。
            physicalReleaseUnknown: review.readyItems.contains { $0.hasOtherHardLinks },
            trashBytes: review.readyBytes,
            trashReclaimable: fileAnalysisReclaimable(review),
            appsToQuit: apps,
            recovery: recovery,
            permission: permission
        )
    }

    /// D104 G1：只在克隆或本地快照明显占住一部分时写出预计释放；另有硬链接时
    /// 大小本身已是上限（P1-2），沿用“最多释放”。
    static func fileAnalysisReclaimable(_ review: FileAnalysisTrashReview) -> TrashReclaimable? {
        guard !review.readyItems.contains(where: \.hasOtherHardLinks) else { return nil }
        let total = review.readyBytes
        let reclaimable = review.reclaimable
        let kept = total - reclaimable.freedBytes
        guard CleanupReclaimableEstimate.isNoticeable(kept, of: total) else { return nil }
        return TrashReclaimable(
            bytes: reclaimable.freedBytes,
            possibleCloneBytes: CleanupReclaimableEstimate.isNoticeable(reclaimable.possibleCloneBytes, of: kept)
                ? reclaimable.possibleCloneBytes : 0,
            countsFoldersWhole: review.readyItems.contains { $0.selection.isDirectory }
        )
    }

    /// 浏览器隐私历史删除：不涉及磁盘空间；删除前备份历史数据库。
    static func browserHistory(
        directRecordCount: Int,
        manualRecordCount: Int,
        browsers: [String],
        runningBrowsers: [String],
        fullDiskAccessBrowsers: [String]
    ) -> OperationConfirmationFacts {
        var actions: [OperationActionKind] = []
        var recovery: [OperationRecoveryMethod] = []
        if directRecordCount > 0 {
            actions.append(.deleteBrowserHistory)
            recovery.append(.browserBackup)
        }
        if manualRecordCount > 0 {
            actions.append(.inBrowserSteps)
            if recovery.isEmpty { recovery.append(.noChange) }
        }
        let permission: OperationPermissionCoverage = fullDiskAccessBrowsers.isEmpty
            ? .notRequired : .missingFullDiskAccess(limitedLocations: fullDiskAccessBrowsers)
        let items = browsers.map {
            OperationConfirmationItem(id: $0, title: $0, path: nil, bytes: nil)
        }
        var facts = OperationConfirmationFacts(
            surface: .browserHistory, actions: actions, items: items,
            localBytes: nil, appsToQuit: runningBrowsers, recovery: recovery, permission: permission
        )
        facts.recordCount = directRecordCount + manualRecordCount
        return facts
    }

    /// D101 L5：菜单“清空废纸篓”。数量和大小取自打开确认时冻结的清单；
    /// 当前用户自己的废纸篓不需要额外权限。
    static func emptyTrash(_ frozen: FrozenTrash) -> OperationConfirmationFacts {
        let bytes = frozen.summary.totalBytes
        let items = frozen.entries.map { entry in
            OperationConfirmationItem(
                id: entry.name,
                title: entry.name,
                path: frozen.trashURL.appendingPathComponent(entry.name).path,
                bytes: entry.allocatedBytes
            )
        }
        return OperationConfirmationFacts(
            surface: .emptyTrash, actions: [.permanentDeletion], items: items,
            localBytes: bytes, permanentDeletionBytes: bytes,
            recovery: [.notRecoverable], permission: .notRequired
        )
    }
}

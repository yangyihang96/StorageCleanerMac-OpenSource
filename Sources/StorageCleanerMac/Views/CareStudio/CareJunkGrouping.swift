import Foundation

/// D142: the result groups of a junk scan, in the order CleanMyMac's
/// Cleanup lists them (System Junk, AI Clutter, Mail Attachments, Trash
/// Bins), plus the developer and to-review groups our rules already have.
/// D203: the results keep these six groups; only the landing's four
/// switches (D192) take developer and to-review rules in with System Junk.
/// Grouping only regroups the session; risk, default selection and every
/// execution check stay with the candidates (D19, D22–D25, D47, D52, D93).
enum CareJunkGroup: String, CaseIterable, Identifiable, Sendable {
    case systemJunk
    case developerJunk
    case aiClutter
    case mailAttachments
    case trashBins
    case filesToReview

    var id: String { rawValue }

    var title: String {
        switch self {
        case .systemJunk: L10n.text("系统垃圾", "System Junk")
        case .developerJunk: L10n.text("开发者垃圾", "Developer Junk")
        case .aiClutter: L10n.text("AI 垃圾", "AI Clutter")
        case .mailAttachments: L10n.text("邮件附件", "Mail Attachments")
        case .trashBins: L10n.text("废纸篓", "Trash")
        case .filesToReview: L10n.text("待确认文件", "Files to Review")
        }
    }

    /// One sentence under the group title (our own wording).
    var summary: String {
        switch self {
        case .systemJunk:
            // D203: the developer and to-review rules have their own groups again.
            L10n.text("应用和系统反复生成的缓存与日志，清掉后会按需重建。",
                      "Caches and logs that apps and macOS keep producing; they are rebuilt when needed.")
        case .developerJunk:
            L10n.text("构建产物、包管理器下载和编译缓存，需要时可以重新生成。",
                      "Build products, package downloads and compiler caches that can be generated again.")
        case .aiClutter:
            L10n.text("AI 工具产生的缓存、日志和临时文件；会话、配置和模型保持不动。",
                      "Caches, logs and temporary files from AI tools. Sessions, settings and models stay put.")
        case .mailAttachments:
            // D183; previously only opened attachment copies were listed.
            L10n.text("邮件附件和打开附件时另存的副本，需审阅后移入废纸篓；仅存本机的附件需放回才能再查看。",
                      "Mail attachments and saved copies to review before moving to Trash; attachments stored only on this Mac must be put back to view them again.")
        case .trashBins:
            L10n.text("废纸篓里的项目仍然占用空间，清倒后不能恢复。",
                      "Items in the Trash still use space. Emptying it cannot be undone.")
        case .filesToReview:
            L10n.text("下载的安装包、大文件和重复的应用副本，是否还要由你判断。",
                      "Downloaded installers, large items and duplicate app copies; you decide whether to keep them.")
        }
    }

    /// D166: the group's object on its result tile.
    var tileArt: GeneratedArt {
        switch self {
        case .systemJunk: .tileSystemJunk
        case .developerJunk: .tileDevJunk
        case .aiClutter: .tileAIClutter
        case .mailAttachments: .tileMail
        case .trashBins: .tileTrash
        case .filesToReview: .tileReview
        }
    }

    var systemImage: String {
        switch self {
        case .systemJunk: "gearshape.2.fill"
        case .developerJunk: "hammer.fill"
        case .aiClutter: "sparkles"
        case .mailAttachments: "envelope.fill"
        case .trashBins: "trash.fill"
        case .filesToReview: "doc.text.magnifyingglass"
        }
    }

    /// Tiles headline: "<size> 的<group>".
    func tileTitle(bytes: Int64) -> String {
        let size = ByteFormat.storageString(bytes)
        return L10n.text("发现 \(size) \(title)", "\(size) of \(title) Found")
    }

    /// D203: the landing switch (D192) that scans the group's rules —
    /// developer junk and files to review come with System Junk.
    var scanScope: SafeCleanupScanScope {
        switch self {
        case .systemJunk, .developerJunk, .filesToReview: .systemJunk
        case .aiClutter: .aiClutter
        case .mailAttachments: .mailAttachments
        case .trashBins: .trashBins
        }
    }

    /// One partition of the rules for the live progress and the results;
    /// the landing switches read it through `scanScope`. A rule's group
    /// comes from the rule alone (D192), so a switch always covers whole
    /// groups.
    static func group(for rule: CleanupRule) -> CareJunkGroup {
        group(categoryID: rule.categoryID, ruleIDs: [rule.id])
    }

    static func group(categoryID: String, candidates: [ScanCandidate]) -> CareJunkGroup {
        group(categoryID: categoryID, ruleIDs: candidates.map(\.ruleID))
    }

    static func group(ruleID: String) -> CareJunkGroup {
        group(categoryID: String(ruleID.lowercased().split(separator: ".").first ?? ""), ruleIDs: [ruleID])
    }

    private static func group(categoryID: String, ruleIDs: [String]) -> CareJunkGroup {
        switch categoryID {
        case "trash": return .trashBins
        case "mail": return .mailAttachments
        case "downloads", "applications", "user-data": return .filesToReview
        case "developer":
            let onlyAITools = !ruleIDs.isEmpty && ruleIDs.allSatisfy { ruleID in
                DeveloperTool.allCases.contains { $0.isAITool && ruleID.lowercased().contains($0.ruleKeyword) }
            }
            return onlyAITools ? .aiClutter : .developerJunk
        default: return .systemJunk
        }
    }

}

/// D183: identify the mailbox from path metadata only; no Mail database reads.
enum MailAttachmentPresentation {
    static func mailboxName(for url: URL) -> String {
        let mailboxes = url.pathComponents.filter { $0.hasSuffix(".mbox") }.map { component in
            let name = String(component.dropLast(5)).removingPercentEncoding ?? String(component.dropLast(5))
            switch name.lowercased() {
            case "inbox": return L10n.text("收件箱", "Inbox")
            case "sent", "sent messages": return L10n.text("已发送", "Sent")
            case "drafts": return L10n.text("草稿", "Drafts")
            case "trash", "deleted messages": return L10n.text("已删除", "Deleted Messages")
            case "junk": return L10n.text("垃圾邮件", "Junk")
            case "archive": return L10n.text("归档", "Archive")
            default: return name
            }
        }.filter { !$0.isEmpty }
        if !mailboxes.isEmpty { return mailboxes.joined(separator: " / ") }
        return url.pathComponents.suffix(4).joined(separator: "/")
    }
}

extension DeveloperTool {
    /// AI coding and chat tools (CleanMyMac "AI Clutter"); build tools and
    /// editors stay in developer junk.
    var isAITool: Bool {
        switch self {
        case .codex, .claudeCode, .claudeDesktop, .lmStudio, .cursor, .githubCopilot,
             .openCode, .openClaw, .geminiCLI, .workBuddy, .windsurf, .continueDev, .cline, .rooCode:
            true
        case .npm, .visualStudioCode, .rodBrowser:
            false
        }
    }

    /// The word a rule identifier of this tool contains.
    var ruleKeyword: String {
        switch self {
        case .npm: "npm"
        case .codex: "codex"
        case .claudeCode: "claude-code"
        case .claudeDesktop: "claude"
        case .visualStudioCode: "vscode"
        case .lmStudio: "lmstudio"
        case .rodBrowser: "rod"
        case .cursor: "cursor"
        case .githubCopilot: "copilot"
        case .openCode: "opencode"
        case .openClaw: "openclaw"
        case .geminiCLI: "gemini"
        case .workBuddy: "workbuddy"
        case .windsurf: "windsurf"
        case .continueDev: "continue"
        case .cline: "cline"
        case .rooCode: "roo"
        }
    }
}

/// A rule's rows inside one group.
struct CareJunkSubgroup: Identifiable, Sendable {
    let id: String
    let title: String
    let reason: String
    let risk: CleanupRisk
    let candidates: [ScanCandidate]

    var bytes: Int64 { CleanupByteCount.sum(candidates.map(\.estimatedSizeBytes)) }
    var selectableIDs: [ScanCandidateID] { candidates.filter(\.isSelectable).map(\.id) }
}

/// One group of a session with its totals.
struct CareJunkGroupSummary: Identifiable, Sendable {
    let group: CareJunkGroup
    let subgroups: [CareJunkSubgroup]

    var id: String { group.rawValue }
    var candidates: [ScanCandidate] { subgroups.flatMap(\.candidates) }
    var totalBytes: Int64 { CleanupByteCount.sum(candidates.map(\.estimatedSizeBytes)) }
    /// What D47 would select by default (green rows whose app is not running).
    var recommendedBytes: Int64 {
        CleanupByteCount.sum(candidates.filter(\.isPreselectedByDefault).map(\.estimatedSizeBytes))
    }
    var recommendedIDs: [ScanCandidateID] { candidates.filter(\.isPreselectedByDefault).map(\.id) }
    var selectableIDs: [ScanCandidateID] { candidates.filter(\.isSelectable).map(\.id) }
    /// CleanMyMac gives such tiles only "Review": nothing in them is
    /// selected by default, so cleaning needs a decision first.
    var isReviewOnly: Bool { recommendedIDs.isEmpty }

    func selectedBytes(in selection: CleanupSelection) -> Int64 {
        CleanupByteCount.sum(candidates.filter { selection.selectedCandidateIDs.contains($0.id) }
            .map(\.estimatedSizeBytes))
    }

    func selectedCount(in selection: CleanupSelection) -> Int {
        candidates.filter { selection.selectedCandidateIDs.contains($0.id) }.count
    }
}

/// The running page's categories: the scanner reports each rule; they are
/// folded into the result groups so a scan shows six lines, not eighty
/// (D203; D192 had folded them into the four switches).
enum CareStudioScanCategories {
    static func make(_ progress: DiskScanProgress) -> [CareStudioLiveCategory] {
        var order: [CareJunkGroup] = []
        var states: [CareJunkGroup: [CleanupScanRuleState]] = [:]
        var bytes: [CareJunkGroup: Int64] = [:]
        for summary in progress.groups {
            let group = CareJunkGroup.group(ruleID: summary.id)
            if states[group] == nil { order.append(group) }
            states[group, default: []].append(summary.state)
            bytes[group, default: 0] += max(0, summary.bytes)
        }
        return CareJunkGroup.allCases.filter { order.contains($0) }.map { group in
            CareStudioLiveCategory(
                id: group.rawValue,
                title: group.title,
                systemImage: group.systemImage,
                state: state(of: states[group] ?? []),
                bytes: bytes[group] ?? 0)
        }
    }

    static func state(of rules: [CleanupScanRuleState]) -> CareStudioLiveCategory.State {
        guard !rules.isEmpty else { return .pending }
        if rules.contains(.scanning) { return .working }
        let finished = rules.filter { $0 != .pending }
        if finished.isEmpty { return .pending }
        if finished.count < rules.count { return .working }
        if rules.contains(.found) { return .found }
        if rules.allSatisfy({ $0 == .failed }) { return .failed }
        return .clean
    }
}

enum CareJunkGrouping {
    /// Groups in display order, empty groups left out.
    static func summaries(for session: ScanSession, filter: ReviewFilter = .overview) -> [CareJunkGroupSummary] {
        var buckets: [CareJunkGroup: [CareJunkSubgroup]] = [:]
        for category in session.categories {
            if filter == .devCaches, category.id != "developer" { continue }
            for subcategory in category.subcategories where !subcategory.candidates.isEmpty {
                let group = CareJunkGroup.group(categoryID: category.id, candidates: subcategory.candidates)
                buckets[group, default: []].append(CareJunkSubgroup(
                    id: subcategory.id,
                    title: subcategory.title,
                    reason: subcategory.reason,
                    risk: subcategory.risk,
                    candidates: subcategory.candidates
                ))
            }
        }
        return CareJunkGroup.allCases.compactMap { group in
            guard let subgroups = buckets[group], !subgroups.isEmpty else { return nil }
            return CareJunkGroupSummary(
                group: group,
                subgroups: subgroups.sorted { $0.bytes > $1.bytes }
            )
        }
    }

    /// What one Smart-Care-style "Run" would clean by default.
    static func recommendedBytes(_ summaries: [CareJunkGroupSummary]) -> Int64 {
        CleanupByteCount.sum(summaries.map(\.recommendedBytes))
    }
}

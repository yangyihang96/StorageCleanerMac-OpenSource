import Foundation

/// Health evidence is independent of the file scan's completeness and score.
/// Optional on history entries so older records do not invent a health check.
enum SmartScanHealthStatus: String, Codable, Equatable, Sendable {
    case notRequested, completed, unavailable, failed, cancelled

    var title: String {
        switch self {
        case .notRequested: L10n.text("未做健康检查", "Health check not performed")
        case .completed: L10n.text("健康检查完成", "Health check completed")
        case .unavailable: L10n.text("健康信息不可用", "Health information unavailable")
        case .failed: L10n.text("健康信息读取失败", "Health information could not be read")
        case .cancelled: L10n.text("健康检查未完成（扫描已取消）", "Health check incomplete (scan cancelled)")
        }
    }
}

/// D64: scan coverage is independent of candidate risk and cleanup selection.
/// A recently active developer cache remains a cleanup candidate, even when
/// its existing safety policy requires protected review.
enum SmartScanScope: String, CaseIterable, Identifiable, Codable, Hashable, Sendable {
    case cleanupCandidates, filesToReview, health
    static let defaultsKey = "smart-scan.selected-scopes"
    static var defaultSelection: Set<Self> { Set(allCases) }
    var id: String { rawValue }
    var title: String {
        switch self {
        case .cleanupCandidates: L10n.text("可清理垃圾", "Cleanup Candidates")
        case .filesToReview: L10n.text("需确认文件", "Files to Review")
        case .health: L10n.text("健康状态检查", "Health Status")
        }
    }
    var probeID: String {
        switch self {
        case .cleanupCandidates: "trash"
        case .filesToReview: "doc.text.magnifyingglass"
        case .health: "shield"
        }
    }
    func includes(_ rule: CleanupRule) -> Bool {
        let needsFileReview = ["downloads", "mail", "applications"].contains(rule.categoryID)
        switch self {
        case .cleanupCandidates: return !needsFileReview
        case .filesToReview: return needsFileReview
        case .health: return false
        }
    }
    static func selection(in defaults: UserDefaults) -> Set<Self> {
        guard let values = defaults.array(forKey: defaultsKey) as? [String] else { return defaultSelection }
        // An explicitly saved empty array stays empty: starting is disabled.
        guard !values.isEmpty else { return [] }
        let recognized = Set(values.compactMap(Self.init(rawValue:)))
        return recognized.isEmpty ? defaultSelection : recognized
    }
    static func save(_ selection: Set<Self>, in defaults: UserDefaults) {
        defaults.set(allCases.filter(selection.contains).map(\.rawValue), forKey: defaultsKey)
    }
}

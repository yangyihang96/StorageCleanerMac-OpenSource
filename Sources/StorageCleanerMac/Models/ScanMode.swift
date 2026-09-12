import Foundation
import SwiftUI

enum ScanMode: String, CaseIterable, Identifiable, Codable, Sendable {
    case standard

    var id: String {
        rawValue
    }

    var title: String {
        L10n.text("标准", "Standard")
    }

    var subtitle: String {
        L10n.text("推荐体检口径", "Recommended scan scope")
    }

    var reportDescription: String {
        L10n.text("推荐范围，覆盖可安全清理项目、应用、文件、Codex 中间产物、大型文件、重复文件和开发缓存。", "Recommended scope covering safe cleanup items, apps, files, Codex intermediates, large files, duplicates, and developer caches.")
    }

    var scoreImpactText: String {
        L10n.text("完整评分", "Full score")
    }

    var systemImage: String {
        "checkmark.seal.fill"
    }

    var tint: Color {
        AppDesignTokens.Palette.information
    }

    static var fallback: ScanMode {
        .standard
    }

    var maxScanSeconds: TimeInterval {
        28
    }

    var maxChildrenPerDirectory: Int {
        36
    }

    var knownPathLimitMultiplier: Double {
        1
    }

    var primaryGroupIDs: [String] {
        ["caches", "logs", "downloads", "applications"]
    }

    var supplementaryGroupIDs: [String] {
        [
            "browser_caches",
            "mail_attachments",
            "codex_intermediates",
            "codex_runtime_records",
            "codex_installers",
            "large_files",
            "duplicate_files",
            "dev_caches"
        ]
    }

    var largeFileMinimumBytes: Int64 {
        200 * 1024 * 1024
    }

    var largeFileResultLimit: Int {
        80
    }

    func includesPrimaryGroup(_ id: String) -> Bool {
        primaryGroupIDs.contains(id)
    }

    func includesSupplementaryGroup(_ id: String) -> Bool {
        supplementaryGroupIDs.contains(id)
    }
}

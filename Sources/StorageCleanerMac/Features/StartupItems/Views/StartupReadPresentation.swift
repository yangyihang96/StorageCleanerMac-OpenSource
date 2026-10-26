import Foundation

/// D195: a missing system inventory is unknown, even when the user-level
/// launchd list happens to be empty. Shared by Performance and Smart Scan.
struct StartupReadPresentation {
    let coverage: StartupCoverageReport
    var isAvailable: Bool { coverage.managedItemCoverageAvailable }
    var unreadLoginTitle: String { L10n.text("没读到登录项", "Login Items Not Read") }
    var unreadReason: String {
        coverage.sources.first { $0.source == .backgroundTaskDiagnostic && $0.errorDescription != nil }?.errorDescription
            ?? L10n.text("需要后台助手或完整扫描才能读到", "The background helper or a full scan is needed to read these items.")
    }

    func loginTitle(count: Int) -> String {
        isAvailable ? L10n.text("你有 \(ByteFormat.count(count)) 个登录项",
            count == 1 ? "You Have 1 Login Item" : "You Have \(ByteFormat.count(count)) Login Items") : unreadLoginTitle
    }
    var loginDetail: String {
        isAvailable ? L10n.text("登录 Mac 时会自动打开这些应用。用不到的可以停用，随时能撤销。",
            "These apps open automatically when you log in. Turn off what you don't need; undo any time.") : unreadReason
    }
    func backgroundTitle(count: Int) -> String {
        L10n.text("发现 \(ByteFormat.count(count)) 个后台项目",
            count == 1 ? "1 Background Item Found" : "\(ByteFormat.count(count)) Background Items Found")
    }
    var backgroundDetail: String {
        L10n.text("按用户与共享启动项目录中的文件逐个计数。其他后台组件可在完整清单中查看。",
            "Counts each file in the user and shared startup directories. Other background components are available in the full list.")
    }

    /// D206: the Full Scan button's help once the system database was read.
    /// It counted organization-managed items (`managedItemCount`, none on most
    /// Macs), so the 10-24 test build read "0 system background items read"
    /// after reading 153 background items.
    var databaseReadHelp: String? {
        guard isAvailable else { return nil }
        let count = coverage.sources
            .filter { $0.source == .backgroundTaskDiagnostic && $0.errorDescription == nil }
            .map(\.discoveredCount).reduce(0, +)
        return L10n.text(
            "已从系统登录项与后台任务数据库读取 \(ByteFormat.count(count)) 项；点击可重新完整扫描",
            "\(ByteFormat.count(count)) items read from the macOS login-item and background-task database; click to run the full scan again")
    }
}

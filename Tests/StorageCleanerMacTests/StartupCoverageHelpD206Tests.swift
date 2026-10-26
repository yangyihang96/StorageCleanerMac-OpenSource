import XCTest
@testable import StorageCleanerMac

/// D206: the Full Scan button's help counts what the macOS login-item and
/// background-task database gave the scan. It used `managedItemCount`, the
/// organization-managed items (none on this Mac), and so the 10-24 test build
/// said "0 system background items read" after reading 153.
final class StartupCoverageHelpD206Tests: XCTestCase {
    private func coverage(available: Bool, sources: [StartupSourceCoverage]) -> StartupCoverageReport {
        var report = StartupCoverageReport.empty
        report.managedItemCoverageAvailable = available
        report.managedItemCount = available ? 0 : nil
        report.sources = sources
        return report
    }

    func testTheHelpCountsTheDatabaseItemsNotTheManagedOnes() throws {
        let report = coverage(available: true, sources: [
            StartupSourceCoverage(source: .backgroundTaskDiagnostic, identifier: "sfltool dumpbtm",
                                  discoveredCount: 153, errorDescription: nil),
            StartupSourceCoverage(source: .launchdPlist, identifier: "~/Library/LaunchAgents",
                                  discoveredCount: 43, errorDescription: nil),
        ])
        let help = try XCTUnwrap(StartupReadPresentation(coverage: report).databaseReadHelp)
        XCTAssertEqual(help, L10n.text(
            "已从系统登录项与后台任务数据库读取 153 项；点击可重新完整扫描",
            "153 items read from the macOS login-item and background-task database; click to run the full scan again"))
        XCTAssertFalse(help.contains(" 0 "), "the managed-item count (0) is not the number read")
    }

    func testNoReadHelpWhenTheDatabaseWasNotRead() {
        let failed = coverage(available: false, sources: [
            StartupSourceCoverage(source: .backgroundTaskDiagnostic, identifier: "helper",
                                  discoveredCount: 0, errorDescription: "后台助手没有运行或不是当前版本"),
        ])
        XCTAssertNil(StartupReadPresentation(coverage: failed).databaseReadHelp)
        XCTAssertNil(StartupReadPresentation(coverage: .empty).databaseReadHelp)
    }

    func testThePerformancePageUsesTheSharedHelp() throws {
        let source = try String(contentsOf: SwiftSourceScanning.projectRoot
            .appendingPathComponent("Sources/StorageCleanerMac/Views/SystemUtilitiesView.swift"), encoding: .utf8)
        XCTAssertTrue(source.contains("StartupReadPresentation(coverage: store.startupCoverage).databaseReadHelp"))
        XCTAssertFalse(source.contains("个系统后台项；点击可重新完整扫描"), "the managed-item wording is gone")
    }
}

import AppKit
import SwiftUI
import XCTest
@testable import StorageCleanerMac

/// D93：七类处理页面都接入共享确认字段与完成统计；完成页不出现“已释放”误称；
/// 勾选时即提示需退出的应用；结果行显示规则来源说明；1280×763 下版式受限。
@MainActor
final class OperationConfirmationContractTests: XCTestCase {
    func testCleanupPlanSheetAndCompletionPagesUseSharedModel() throws {
        let source = try sourceText(at: "Sources/StorageCleanerMac/Views/CleanupExecutionViews.swift")
        // P2-12 follow-up: the subtitle must not promise a move when none will run.
        XCTAssertTrue(source.contains("guard facts.actions.contains(moveAction) else {"))
        XCTAssertTrue(source.contains("Text(dispositionSummary(facts))"))
        let sheet = try r2SourceDeclaration("struct CleanupPlanConfirmationSheet: View", in: source)
        XCTAssertTrue(sheet.contains("OperationConfirmationFactsView(facts: facts)"))
        XCTAssertTrue(sheet.contains("surface: .inferred(for: plan, session: store.cleanupScanSession)"))
        // P2-11: the six fields are built once per body refresh, then passed down.
        XCTAssertTrue(sheet.contains("let facts = confirmationFacts"))
        XCTAssertEqual(sheet.components(separatedBy: "confirmationFacts").count - 1, 2,
                       "confirmationFacts is defined once and read once per body")
        // P1-1/P2-1/P2-12: title, header and panel share one basis — all planned items,
        // then the ones that will run — and the same ready bytes.
        XCTAssertTrue(sheet.contains("facts.cleanupPlanTitle("))
        XCTAssertTrue(sheet.contains("compactMetric(L10n.items(facts.itemCount)"))
        // D178: decimal sizes (was `ByteFormat.string(…)`).
        XCTAssertTrue(sheet.contains("ByteFormat.storageString(facts.trashBytes + facts.quarantineBytes)"))
        XCTAssertTrue(sheet.contains("ByteFormat.storageString(facts.permanentDeletionBytes)"))
        XCTAssertFalse(sheet.contains("ByteFormat.storageString(plan.trashMoveBytes)"))
        XCTAssertTrue(sheet.contains("compactMetric(L10n.items(facts.readyCount)"))
        XCTAssertTrue(sheet.contains("facts.cleanupTrashReleaseNote(planHasTrashMoves:"))
        XCTAssertFalse(sheet.contains("plan.trashMoveItems.count"))
        // P2-11: skip IDs are filtered with a Set, not a linear scan per ID.
        let model = try sourceText(at: "Sources/StorageCleanerMac/Models/OperationConfirmationModels.swift")
        XCTAssertTrue(model.contains("let planIDs = Set(planItems.map(\\.id))"))
        XCTAssertTrue(model.contains("skipped.filter { id, _ in planIDs.contains(id) }"))
        XCTAssertFalse(model.contains("planItems.contains { $0.id == id }"))
        XCTAssertTrue(sheet.contains("OperationQuitNotice.appNames(store.pendingCleanupOwnerQuitOptions)"))
        XCTAssertTrue(sheet.contains("permission: .from(store.scanReadinessSummary)"))
        for declaration in ["struct SmartScanCleanupCompletedPage: View", "struct CleanupV2OperationOverlay: View"] {
            let page = try r2SourceDeclaration(declaration, in: source)
            XCTAssertTrue(page.contains("OperationCompletionTallyView(tally: OperationCompletionTally(report: report)"), declaration)
            XCTAssertFalse(page.contains("\"已释放"), declaration)
        }
        // P2-7: the completed page already warns about the receipt.
        let completed = try r2SourceDeclaration("struct SmartScanCleanupCompletedPage: View", in: source)
        XCTAssertTrue(completed.contains("showsReceiptNote: false"))
    }

    func testUninstallDuplicateFileAnalysisAndBrowserPagesUseSharedModel() throws {
        let uninstall = try sourceText(at: "Sources/StorageCleanerMac/Views/UninstallPreviewSheet.swift")
        let uninstallSheet = try r2SourceDeclaration("struct UninstallPreviewSheet: View", in: uninstall)
        XCTAssertTrue(uninstallSheet.contains("OperationConfirmationFactsView(facts: confirmationFacts"))
        XCTAssertTrue(uninstallSheet.contains(".uninstall("))
        XCTAssertTrue(uninstallSheet.contains("uninstall: report, app: app, appIsRunning: !Self.runningNames(app).isEmpty"))
        XCTAssertTrue(uninstallSheet.contains("showsEntryDetails: false, showsReceiptNote: false)"))
        XCTAssertFalse(uninstallSheet.contains("\"已释放"))

        let utilities = try sourceText(at: "Sources/StorageCleanerMac/Views/SystemUtilitiesView.swift")
        let duplicateSheet = try r2SourceDeclaration("private struct DuplicateCleanupConfirmationSheet: View", in: utilities)
        XCTAssertTrue(duplicateSheet.contains("OperationConfirmationFactsView(facts: facts"))
        XCTAssertTrue(utilities.contains("surface: .duplicateFiles"))
        let duplicateReport = try r2SourceDeclaration("private var duplicateCleanupReportPanel: some View", in: utilities)
        XCTAssertTrue(duplicateReport.contains("OperationCompletionTallyView(tally: OperationCompletionTally(report: report))"))
        XCTAssertFalse(duplicateReport.contains("\"已释放"))

        let fileAnalysis = try sourceText(at: "Sources/StorageCleanerMac/Views/FileAnalysisTrashViews.swift")
        let review = try r2SourceDeclaration("struct FileAnalysisTrashReviewSheet: View", in: fileAnalysis)
        XCTAssertTrue(review.contains("OperationConfirmationFactsView(facts: .fileAnalysis(review, permission: permission)"))
        XCTAssertTrue(review.contains("ScanReadinessService.fullDiskAccessState()"))
        let bar = try r2SourceDeclaration("struct FileAnalysisTrashBar: View", in: fileAnalysis)
        XCTAssertTrue(bar.contains("OperationCompletionTallyView(tally: OperationCompletionTally(fileAnalysis: outcome)"))
        XCTAssertTrue(bar.contains("showsReceiptNote: false)"), "the bar shows its own receipt note (P2-7)")
        XCTAssertFalse(bar.contains("\"已释放"))
        let lightfield = try sourceText(at: "Sources/StorageCleanerMac/Views/FilesLightfield/FileAnalysisLightfieldView.swift")
        XCTAssertTrue(lightfield.contains("OperationCompletionTallyView(tally: OperationCompletionTally(fileAnalysis: outcome),\n"))
        XCTAssertTrue(lightfield.contains("showsReceiptNote: false)"))

        let browser = try sourceText(at: "Sources/StorageCleanerMac/Views/BrowserPrivacyRecordResultsView.swift")
        let results = try r2SourceDeclaration("struct BrowserPrivacyRecordResultsView: View", in: browser)
        XCTAssertTrue(results.contains("BrowserPrivacyConfirmationText.facts("))
        XCTAssertTrue(results.contains(").plainText + \"\\n\\n\""))
        XCTAssertTrue(results.contains("processingConfirmationMessage = facts + "))
        XCTAssertTrue(results.contains("runningBrowserConfirmationMessage = facts + "),
                      "both confirmation messages lead with the six fields")
        XCTAssertTrue(results.contains("if !store.isProcessing, store.processingReport == nil, let notice = runningBrowserSelectionNotice"))
        // P2-5: the notice and the six fields use the same direct-records-only names.
        XCTAssertEqual(browser.components(separatedBy: "OperationQuitNotice.runningBrowserNames(").count - 1, 2)
        let report = try r2SourceDeclaration("struct BrowserPrivacyProcessingReportView: View", in: browser)
        XCTAssertTrue(report.contains("OperationCompletionTallyView(tally: OperationCompletionTally(browser: report)"))
        XCTAssertFalse(report.contains("\"已释放"))
    }

    func testScanResultRowsExplainRuleAndWarnAboutRunningOwnersOnSelection() throws {
        let source = try sourceText(at: "Sources/StorageCleanerMac/Views/CleanupScanViews.swift")
        XCTAssertTrue(source.contains("OperationQuitNotice.text(forSelected:"))
        XCTAssertEqual(source.components(separatedBy: "if let quitNotice = selectionQuitNotice").count - 1, 2,
                       "lightfield and legacy result lists both warn while items are checked")
        XCTAssertTrue(source.contains("CleanupRuleExplanationView(explanation: candidate.ruleExplanation)"))
        XCTAssertTrue(source.contains("L10n.text(\"属于 \", \"Belongs to \") + candidate.ruleExplanation.ownership"))
        XCTAssertTrue(source.contains(".help(candidate.ruleExplanation.summary)"))
        // P2-6: the lightfield row detail comes from the tested model helper.
        XCTAssertTrue(source.contains("CleanupRuleExplanation.lightfieldDetail("))
    }

    func testSharedViewsKeepDesignTokensAndNoFreedWording() throws {
        let views = try sourceText(at: "Sources/StorageCleanerMac/Views/DesignSystem/OperationConfirmationViews.swift")
        for forbidden in [".buttonStyle(.borderless)", "minimumScaleFactor", ".lineLimit(1)", ".font(.caption", "\"已释放"] {
            XCTAssertFalse(views.contains(forbidden), forbidden)
        }
        // 字段区超出上限时必须能滚动看全，不能被 maxHeight 裁掉（fittingSize 测不出裁切）。
        XCTAssertTrue(views.contains("ScrollView { fieldRows }"))
        XCTAssertTrue(views.contains(".frame(maxHeight: Self.fieldRowsMaxHeight)"))
        let model = try sourceText(at: "Sources/StorageCleanerMac/Models/OperationConfirmationModels.swift")
        XCTAssertFalse(model.contains("\"已释放"))
        XCTAssertFalse(model.contains("\"Freed "))
    }

    /// D77：确认表正文约 416pt 宽、完成页 430pt 宽；最坏情况的字段文本整段换行后
    /// 高度仍受限，避免在 1280×763 的表单里挤掉按钮。
    func testWorstCaseLayoutsStayBoundedAtSheetWidths() throws {
        for language in [AppLanguage.zhHans, .english] {
          for width in [CGFloat(416), 480] {
            try withLanguage(language) {
                var facts = OperationConfirmationFacts.cleanupPlanItems(
                    OperationConfirmationModelTests.planItems([
                        ("a", 1_000_000_000, .moveToTrash), ("b", 2_000, .moveToTrash), ("c", 500, .emptyTrash),
                    ]),
                    disposition: .trash, skipped: [:], surface: .safeCleanup,
                    appsToQuit: ["Visual Studio Code", "Google Chrome", "Slack", "Microsoft Teams"],
                    permission: .missingFullDiskAccess(limitedLocations: ["Documents", "Desktop", "Downloads", "Mail"]))
                // Worst case after fix round 1: split objects, two warnings, the "at most" capacity.
                facts.notRunCount = 1
                facts.physicalReleaseUnknown = true
                facts.objectWarnings = ["warning one with a long explanation that wraps", "warning two with a long explanation"]
                let factsHeight = fittingHeight(OperationConfirmationFactsView(facts: facts), width: width)
                XCTAssertGreaterThan(factsHeight, 60)
                XCTAssertLessThanOrEqual(factsHeight, Self.factsHeightLimit, "\(language) facts \(factsHeight)")

                var report = OperationConfirmationModelTests.report([
                    ("moved", 100, .moved(OperationConfirmationModelTests.receipt("moved"))),
                    ("skip", 1, .skipped(.relatedAppStillRunning)),
                    ("fail", 1, .failed(CleanFailure(code: .trashMoveFailed, detailCode: nil))),
                    ("deleted", 30, .deleted(CleanupDeletionReceipt(originalPath: "/Fixture/deleted",
                        deletedIdentity: OperationConfirmationModelTests.identity(4), deletedAt: Date()))),
                ])
                report.persistenceFailure = "fixture"
                let tally = OperationCompletionTally(report: report)
                let tallyHeight = fittingHeight(OperationCompletionTallyView(tally: tally), width: width + 14)
                XCTAssertLessThanOrEqual(tallyHeight, Self.tallyHeightLimit, "\(language) tally \(tallyHeight)")
            }
          }
        }
    }

    static let factsHeightLimit: CGFloat = OperationConfirmationFactsView.fieldRowsMaxHeight + 64
    static let tallyHeightLimit: CGFloat = 180

    private func fittingHeight<Content: View>(_ view: Content, width: CGFloat) -> CGFloat {
        let host = NSHostingView(rootView: view.frame(width: width))
        host.frame = CGRect(x: 0, y: 0, width: width, height: 10)
        host.layoutSubtreeIfNeeded()
        return host.fittingSize.height
    }

    private func withLanguage(_ language: AppLanguage, _ body: () throws -> Void) rethrows {
        let defaults = TestPreferenceDomain.make(for: self)
        defaults.set(language.rawValue, forKey: L10n.languageDefaultsKey)
        let preferences = TestVolatilePreferences()
        preferences.set(language.rawValue, forKey: L10n.languageDefaultsKey)
        defer { preferences.restore() }
        try body()
    }

    private var projectRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func sourceText(at relativePath: String) throws -> String {
        try r2ProductionSource(at: projectRoot.appendingPathComponent(relativePath))
    }
}
